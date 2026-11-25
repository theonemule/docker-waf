package kube

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"github.com/theonemule/docker-waf/controller/internal/provider"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	ktesting "k8s.io/client-go/testing"
	"math/big"
	gw "sigs.k8s.io/gateway-api/apis/v1"
	"testing"
	"time"
)

func backendTestCA(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Test CA"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}
func tlsPolicy(t *testing.T, name, service, section, ca, host string) *unstructured.Unstructured {
	t.Helper()
	p := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"BackendTLSPolicy","metadata":{"namespace":"apps"},"spec":{"targetRefs":[{"group":"","kind":"Service","name":"web"}],"validation":{"hostname":"backend.example.test","caCertificateRefs":[{"group":"","kind":"ConfigMap","name":"ca"}]}}}`)
	p.SetName(name)
	targets, _, _ := unstructured.NestedSlice(p.Object, "spec", "targetRefs")
	targets[0].(map[string]any)["name"] = service
	if section != "" {
		targets[0].(map[string]any)["sectionName"] = section
	}
	unstructured.SetNestedSlice(p.Object, targets, "spec", "targetRefs")
	unstructured.SetNestedField(p.Object, host, "spec", "validation", "hostname")
	refs, _, _ := unstructured.NestedSlice(p.Object, "spec", "validation", "caCertificateRefs")
	refs[0].(map[string]any)["name"] = ca
	unstructured.SetNestedSlice(p.Object, refs, "spec", "validation", "caCertificateRefs")
	return p
}
func testCAConfigMap(t *testing.T) *unstructured.Unstructured {
	cm := obj(t, `{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"ca","namespace":"apps"}}`)
	unstructured.SetNestedField(cm.Object, backendTestCA(t), "data", "ca.crt")
	return cm
}

const tlsRouteJSON = `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"route","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"rules":[{"backendRefs":[{"name":"web","port":8080}]}]}}`

func TestBackendTLSPolicyTranslationAndStatus(t *testing.T) {
	ctx := context.Background()
	winner := tlsPolicy(t, "winner", "web", "http", "ca", "backend.example.test")
	winner.SetCreationTimestamp(meta.NewTime(time.Now().Add(-time.Hour)))
	loser := tlsPolicy(t, "loser", "web", "http", "ca", "wrong.example.test")
	loser.SetCreationTimestamp(meta.NewTime(time.Now()))
	fallback := tlsPolicy(t, "fallback", "web", "", "ca", "default.example.test")
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, gatewayJSON), obj(t, serviceJSON), obj(t, tlsRouteJSON), testCAConfigMap(t), winner, loser, fallback)
	inv, err := r.Build(ctx)
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(0).Sites
	if len(sites) != 1 || len(sites[0].Routes) != 1 {
		t.Fatal(sites)
	}
	route := sites[0].Routes[0]
	if route.BackendTLS == nil || route.BackendTLS.Hostname != "backend.example.test" || route.Backends[0].Target != "https://10.96.0.5:8080" {
		t.Fatalf("wrong TLS translation %+v", route)
	}
	if err = r.Report(ctx, inv, true, true); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"winner", "loser", "fallback"} {
		actual, err := get[gw.BackendTLSPolicy](ctx, r.Client, backendTLSGVR, "apps", name)
		if err != nil {
			t.Fatal(err)
		}
		if len(actual.Status.Ancestors) != 1 {
			t.Fatalf("missing policy ancestor %+v", actual.Status)
		}
		a := actual.Status.Ancestors[0]
		if a.AncestorRef.Name != "edge" || a.ControllerName != "blaize.net/lightedge-controller" {
			t.Fatal(a)
		}
		found := false
		for _, c := range a.Conditions {
			if c.Type == "Accepted" {
				found = true
				if name == "loser" && (c.Status != meta.ConditionFalse || c.Reason != "Conflicted") || name != "loser" && c.Status != meta.ConditionTrue {
					t.Fatalf("wrong policy condition %s %+v", name, c)
				}
			}
		}
		if !found {
			t.Fatal(a)
		}
	}
	// Appliance refusal is reflected in policy status, not success.
	inv.ProviderRejected([]provider.RejectedResource{{Field: "backend_tls", Origins: route.Origins}})
	if err = r.Report(ctx, inv, true, true); err != nil {
		t.Fatal(err)
	}
	actual, err := get[gw.BackendTLSPolicy](ctx, r.Client, backendTLSGVR, "apps", "winner")
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range actual.Status.Ancestors[0].Conditions {
		if c.Type == "Accepted" && c.Status != meta.ConditionFalse {
			t.Fatal(c)
		}
	}
}
func TestBackendTLSInvalidPolicyNeverDowngrades(t *testing.T) {
	for _, tc := range []struct {
		name, ca, host string
		mixed          bool
	}{
		{"missingCA", "missing", "backend.example.test", false},
		{"invalidHost", "ca", "*.example.test", false},
		{"mixedInvalid", "missing", "backend.example.test", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			route := obj(t, tlsRouteJSON)
			if tc.mixed {
				route = obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"route","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"rules":[{"backendRefs":[{"name":"web","port":8080},{"name":"canary","port":8080}]}]}}`)
			}
			p := tlsPolicy(t, "tls", "web", "", tc.ca, tc.host)
			r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, gatewayJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), route, testCAConfigMap(t), p)
			inv, err := r.Build(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			s := inv.Plan.Snapshot(0).Sites
			if len(s) != 1 || len(s[0].Routes) != 1 || len(s[0].Routes[0].Backends) != 1 || s[0].Routes[0].Backends[0].Target != "invalid" || s[0].Routes[0].BackendTLS != nil {
				t.Fatalf("TLS failure must be local 500: %+v", s)
			}
			if inv.Parents[0].RefReason == "" {
				t.Fatal("missing unresolved status")
			}
			if err = r.Report(context.Background(), inv, true, true); err != nil {
				t.Fatal(err)
			}
			actual, err := get[gw.BackendTLSPolicy](context.Background(), r.Client, backendTLSGVR, "apps", "tls")
			if err != nil {
				t.Fatal(err)
			}
			if len(actual.Status.Ancestors) != 1 {
				t.Fatal(actual.Status)
			}
			for _, c := range actual.Status.Ancestors[0].Conditions {
				if c.Type == "Accepted" && c.Status != meta.ConditionFalse {
					t.Fatal(c)
				}
			}
		})
	}
}

func TestBackendTLSLegacyDiscovery(t *testing.T) {
	ctx := context.Background()
	p := tlsPolicy(t, "legacy", "web", "", "ca", "backend.example.test")
	p.SetAPIVersion("gateway.networking.k8s.io/v1alpha3")
	for _, denied := range []bool{false, true} {
		r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, gatewayJSON), obj(t, serviceJSON), obj(t, tlsRouteJSON), testCAConfigMap(t), p)
		r.Client.(*dynamicfake.FakeDynamicClient).PrependReactor("list", "backendtlspolicies", func(a ktesting.Action) (bool, runtime.Object, error) {
			if a.GetResource() != backendTLSGVR {
				return false, nil, nil
			}
			if denied {
				return true, nil, apierrors.NewForbidden(backendTLSGVR.GroupResource(), "", errors.New("denied"))
			}
			return true, nil, apierrors.NewNotFound(backendTLSGVR.GroupResource(), "")
		})
		inv, err := r.Build(ctx)
		if denied {
			if err == nil {
				t.Fatal("RBAC denial must not downgrade to HTTP")
			}
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		route := inv.Plan.Snapshot(0).Sites[0].Routes[0]
		if route.BackendTLS == nil || route.Backends[0].Target != "https://10.96.0.5:8080" {
			t.Fatal(route)
		}
		if err = r.Report(ctx, inv, true, true); err != nil {
			t.Fatal(err)
		}
		policy, err := get[gw.BackendTLSPolicy](ctx, r.Client, backendTLSAlpha3GVR, "apps", "legacy")
		if err != nil || len(policy.Status.Ancestors) != 1 {
			t.Fatalf("legacy status: %+v %v", policy, err)
		}
	}
}

func TestBackendTLSAncestorQuotaAcrossPartitions(t *testing.T) {
	ctx := context.Background()
	p := tlsPolicy(t, "quota", "web", "", "ca", "backend.example.test")
	// Reserve one slot for another controller, then 15 of our own can fit.
	foreign := map[string]any{"ancestorRef": map[string]any{"name": "foreign", "namespace": "apps"}, "controllerName": "other.example/controller", "conditions": []any{map[string]any{"type": "Accepted", "status": "True", "reason": "Accepted", "message": "other controller", "lastTransitionTime": "2026-01-01T00:00:00Z"}}}
	if err := unstructured.SetNestedSlice(p.Object, []any{foreign}, "status", "ancestors"); err != nil {
		t.Fatal(err)
	}
	objects := []runtime.Object{obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), testCAConfigMap(t), p}
	assigned := map[string]bool{}
	for i := 0; i < 17; i++ {
		name := fmt.Sprintf("edge-%02d", i)
		g := obj(t, gatewayJSON)
		g.SetName(name)
		listeners, _, _ := unstructured.NestedSlice(g.Object, "spec", "listeners")
		listeners[0].(map[string]any)["hostname"] = name + ".example.test"
		unstructured.SetNestedSlice(g.Object, listeners, "spec", "listeners")
		route := obj(t, tlsRouteJSON)
		route.SetName(name)
		unstructured.SetNestedSlice(route.Object, []any{map[string]any{"name": name}}, "spec", "parentRefs")
		objects = append(objects, g, route)
		if i >= 8 {
			assigned["apps/"+name] = true
		}
	}
	r := fakeReader(t, objects...)
	a, b := r, r
	a.Config.Scope = &GatewayScope{Default: true, Elsewhere: assigned}
	b.Config.Scope = &GatewayScope{Assigned: assigned}
	invA, err := a.Build(ctx)
	if err != nil {
		t.Fatal(err)
	}
	invB, err := b.Build(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for i, inv := range []Inventory{invA, invB} {
		good, bad := 0, 0
		for _, site := range inv.Plan.Snapshot(0).Sites {
			for _, route := range site.Routes {
				if route.BackendTLS != nil {
					good++
				} else if route.Backends[0].Target == "invalid" {
					bad++
				} else {
					t.Fatalf("quota must not use plaintext: %+v", route)
				}
			}
		}
		if i == 0 && (good != 8 || bad != 0) || i == 1 && (good != 7 || bad != 2) {
			t.Fatalf("partition %d: good=%d bad=%d", i, good, bad)
		}
	}
	if err = b.Report(ctx, invB, true, true); err != nil {
		t.Fatal(err)
	}
	if err = a.Report(ctx, invA, true, true); err != nil {
		t.Fatal(err)
	}
	actual, err := get[gw.BackendTLSPolicy](ctx, r.Client, backendTLSGVR, "apps", "quota")
	if err != nil {
		t.Fatal(err)
	}
	if len(actual.Status.Ancestors) != 16 {
		t.Fatalf("wrong quota: %+v", actual.Status)
	}
	for _, ancestor := range actual.Status.Ancestors {
		if ancestor.AncestorRef.Name == "edge-15" || ancestor.AncestorRef.Name == "edge-16" {
			t.Fatalf("over-quota status %+v", ancestor)
		}
	}
}

func TestBackendTLSPeerIdentities(t *testing.T) {
	for _, mixed := range []bool{true, false} {
		route := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"route","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"rules":[{"backendRefs":[{"name":"web","port":8080,"weight":80},{"name":"canary","port":8080,"weight":20}]}]}}`)
		p := tlsPolicy(t, "tls", "web", "", "ca", "backend.example.test")
		objects := []runtime.Object{obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, gatewayJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), route, testCAConfigMap(t), p}
		if !mixed {
			objects = append(objects, tlsPolicy(t, "canary-tls", "canary", "", "ca", "canary.example.test"))
		}
		r := fakeReader(t, objects...)
		inv, err := r.Build(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		x := inv.Plan.Snapshot(0).Sites[0].Routes[0]
		if x.BackendTLS != nil || len(x.BackendTLSPeers) == 0 || x.BackendTLSPeers["https://10.96.0.5:8080"].Hostname != "backend.example.test" || inv.Parents[0].RefReason != "" {
			t.Fatal(x, inv.Parents)
		}
		weights := map[string]int32{}
		for _, b := range x.Backends {
			weights[b.Target] = b.Weight
		}
		if weights["https://10.96.0.5:8080"] != 80 {
			t.Fatal(weights)
		}
		if mixed {
			if len(x.BackendTLSPeers) != 1 || weights["http://10.96.0.6:8080"] != 20 {
				t.Fatal(x)
			}
		} else if len(x.BackendTLSPeers) != 2 || weights["https://10.96.0.6:8080"] != 20 || x.BackendTLSPeers["https://10.96.0.6:8080"].Hostname != "canary.example.test" {
			t.Fatal(x)
		}
	}
}
