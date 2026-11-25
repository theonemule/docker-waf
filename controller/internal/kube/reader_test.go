package kube

import (
	"context"
	"encoding/json"
	"errors"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	ktesting "k8s.io/client-go/testing"
	gw "sigs.k8s.io/gateway-api/apis/v1"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func obj(t *testing.T, raw string) *unstructured.Unstructured {
	t.Helper()
	m := map[string]any{}
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		t.Fatal(err)
	}
	return &unstructured.Unstructured{Object: m}
}
func fakeReader(t *testing.T, objects ...runtime.Object) Reader {
	lists := map[schema.GroupVersionResource]string{
		IngressGVR: "IngressList", ingressClassGVR: "IngressClassList", GatewayGVR: "GatewayList",
		grpcRouteGVR: "GRPCRouteList", tcpRouteGVR: "TCPRouteList", udpRouteGVR: "UDPRouteList", tlsRouteGVR: "TLSRouteList",
		GatewayClassGVR: "GatewayClassList", HTTPRouteGVR: "HTTPRouteList", grantGVR: "ReferenceGrantList",
		policyGVR: "LightEdgePolicyList", backendTLSGVR: "BackendTLSPolicyList", backendTLSAlpha3GVR: "BackendTLSPolicyList", configMapGVR: "ConfigMapList", serviceGVR: "ServiceList", endpointSliceGVR: "EndpointSliceList", secretGVR: "SecretList", namespaceGVR: "NamespaceList",
	}
	client := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), lists)
	for _, object := range objects {
		u := object.(*unstructured.Unstructured)
		found := false
		for gvr, listKind := range lists {
			if gvr.GroupVersion() == u.GroupVersionKind().GroupVersion() && listKind == u.GetKind()+"List" {
				_, err := client.Resource(gvr).Namespace(u.GetNamespace()).Create(context.Background(), u, meta.CreateOptions{})
				if err != nil {
					t.Fatal(err)
				}
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("fixture has no GVR: %s", u.GetKind())
		}
	}
	return Reader{Client: client, Config: Config{ControllerName: "blaize.net/lightedge-controller", IngressClass: "lightedge", GatewayClass: "lightedge", BackendMode: "clusterip", Ingress: true, Gateway: true}}
}

const ingressClassJSON = `{"apiVersion":"networking.k8s.io/v1","kind":"IngressClass","metadata":{"name":"lightedge"},"spec":{"controller":"blaize.net/lightedge-controller"}}`
const gatewayClassJSON = `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"GatewayClass","metadata":{"name":"lightedge"},"spec":{"controllerName":"blaize.net/lightedge-controller"}}`
const serviceJSON = `{"apiVersion":"v1","kind":"Service","metadata":{"name":"web","namespace":"apps"},"spec":{"clusterIP":"10.96.0.5","ports":[{"name":"http","port":8080,"protocol":"TCP"}]}}`
const serviceTwoJSON = `{"apiVersion":"v1","kind":"Service","metadata":{"name":"canary","namespace":"apps"},"spec":{"clusterIP":"10.96.0.6","ports":[{"name":"http","port":8080,"protocol":"TCP"}]}}`
const ingressJSON = `{"apiVersion":"networking.k8s.io/v1","kind":"Ingress","metadata":{"name":"web","namespace":"apps","annotations":{"lightedge.blaize.net/waf-paranoia-level":"2"}},"spec":{"ingressClassName":"lightedge","rules":[{"host":"ingress.apps.example.test","http":{"paths":[{"path":"/foo/","pathType":"Prefix","backend":{"service":{"name":"web","port":{"name":"http"}}}}]}}]}}`
const ignoredIngressJSON = `{"apiVersion":"networking.k8s.io/v1","kind":"Ingress","metadata":{"name":"ignored","namespace":"apps"},"spec":{"ingressClassName":"other","rules":[]}}`
const gatewayJSON = `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"Gateway","metadata":{"name":"edge","namespace":"apps"},"spec":{"gatewayClassName":"lightedge","listeners":[{"name":"http","port":80,"protocol":"HTTP","hostname":"gateway.apps.example.test"}]}}`
const routeJSON = `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"route","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"hostnames":["gateway.apps.example.test"],"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}],"backendRefs":[{"name":"web","port":8080,"weight":90},{"name":"canary","port":8080,"weight":10}]}]}}`

func TestDualStandards(t *testing.T) {
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), obj(t, ingressJSON), obj(t, ignoredIngressJSON), obj(t, gatewayJSON), obj(t, routeJSON))
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	snap := inv.Plan.Snapshot(3)
	if len(snap.Sites) != 2 || len(inv.Ingresses) != 1 || len(inv.Parents) != 1 || len(inv.Attachments) != 1 {
		t.Fatalf("bad inventory: %+v", snap)
	}
	g, i := snap.Sites[0], snap.Sites[1]
	if g.Host != "gateway.apps.example.test" || len(g.Routes[0].Backends) != 2 || g.Routes[0].Backends[0].Weight != 90 || g.Routes[0].Backends[1].Weight != 10 {
		t.Fatalf("bad gateway translation: %+v", g.Routes)
	}
	if i.Routes[0].Path != "/foo" || i.Routes[0].WAFPL != 2 || i.Routes[0].Backends[0].Target != "http://10.96.0.5:8080" {
		t.Fatalf("bad ingress translation: %+v", i.Routes)
	}
}
func TestMissingIngressServiceIsolated(t *testing.T) {
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, ingressJSON), obj(t, gatewayJSON), obj(t, routeJSON), obj(t, serviceTwoJSON))
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(0).Sites
	if len(sites) != 2 || sites[1].Routes[0].Backends[0].Target != "invalid" {
		t.Fatalf("missing Ingress backend must return 500, not block other routes: %+v", sites)
	}
}
func TestUnapprovedCrossNamespaceReturnsInvalidBackend(t *testing.T) {
	route := obj(t, routeJSON)
	rules, _, _ := unstructured.NestedSlice(route.Object, "spec", "rules")
	refs := rules[0].(map[string]any)["backendRefs"].([]any)
	refs[0].(map[string]any)["namespace"] = "other"
	unstructured.SetNestedSlice(route.Object, rules, "spec", "rules")
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), obj(t, gatewayJSON), route)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if inv.Parents[0].RefReason != "RefNotPermitted" {
		t.Fatalf("wrong status: %+v", inv.Parents)
	}
	routes := inv.Plan.Snapshot(0).Sites[0].Routes
	if routes[0].Backends[1].Target != "invalid" || routes[0].Backends[1].Weight != 90 {
		t.Fatalf("wrong invalid backend share: %+v", routes)
	}
	if err := r.Report(context.Background(), inv, true, true); err != nil {
		t.Fatal(err)
	}
	actual, err := get[gw.HTTPRoute](context.Background(), r.Client, HTTPRouteGVR, "apps", "route")
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range actual.Status.Parents[0].Conditions {
		if c.Type == "ResolvedRefs" && c.Status == meta.ConditionFalse && c.Reason == "RefNotPermitted" {
			return
		}
	}
	t.Fatal("missing ResolvedRefs=False status")
}
func TestPolicyAndStatus(t *testing.T) {
	policy := obj(t, `{"apiVersion":"lightedge.blaize.net/v1alpha1","kind":"LightEdgePolicy","metadata":{"name":"security","namespace":"apps"},"spec":{"targetRef":{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"route"},"waf":{"enabled":true,"paranoiaLevel":3},"rateLimit":{"requestsPerSecond":50},"maxBodySize":"10m"}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), obj(t, gatewayJSON), obj(t, routeJSON), policy)
	r.Config.Policies = true
	r.Config.Addresses = []string{"192.0.2.1"}
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	route := inv.Plan.Snapshot(1).Sites[0].Routes[0]
	if route.WAFPL != 3 || route.RateCount != 50 || route.MaxBody != "10m" {
		t.Fatalf("bad policy translation: %+v", route)
	}
	if err := r.Report(context.Background(), inv, true, true); err != nil {
		t.Fatal(err)
	}
}

func TestGatewayConditionalAndRedirect(t *testing.T) {
	route := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"filters","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"rules":[{"matches":[{"path":{"type":"Exact","value":"/"},"headers":[{"name":"X-Mode","value":"Canary"}],"method":"GET"}],"backendRefs":[{"name":"canary","port":8080}]},{"matches":[{"path":{"type":"Exact","value":"/redirect"}}],"filters":[{"type":"RequestRedirect","requestRedirect":{"hostname":"new.apps.example.test","scheme":"https","statusCode":301}}]}]}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceTwoJSON), obj(t, gatewayJSON), route)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	routes := inv.Plan.Snapshot(0).Sites[0].Routes
	if len(routes) != 2 || routes[0].Method != "GET" || len(routes[0].HeaderMatches) != 1 || routes[0].HeaderMatches[0].Name != "x-mode" || routes[1].Redirect == nil || routes[1].Redirect.StatusCode != 301 || len(routes[1].Backends) != 0 {
		t.Fatalf("bad translation: %+v", routes)
	}
}

func TestRejectedParentDoesNotBlockHealthyRoute(t *testing.T) {
	rejected := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"bad-parent","namespace":"other"},"spec":{"parentRefs":[{"name":"edge","namespace":"apps"}],"rules":[{"backendRefs":[{"name":"nonexistent","port":8080}]}]}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), obj(t, gatewayJSON), obj(t, routeJSON), rejected)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(inv.Plan.Snapshot(0).Sites) != 1 || len(inv.Parents) != 2 {
		t.Fatalf("unexpected inventory: %+v", inv)
	}
	if err := r.Report(context.Background(), inv, true, true); err != nil {
		t.Fatal(err)
	}
	actual, err := get[gw.HTTPRoute](context.Background(), r.Client, HTTPRouteGVR, "other", "bad-parent")
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range actual.Status.Parents[0].Conditions {
		if c.Type == "Accepted" && c.Status == meta.ConditionFalse && c.Reason == "NotAllowedByListeners" {
			return
		}
	}
	t.Fatal("missing rejected parent status")
}

func TestHostIntersectionAndReservedListener(t *testing.T) {
	for _, item := range []struct {
		a, b, want string
		ok         bool
	}{
		{"*.example.test", "*.sub.example.test", "*.sub.example.test", true},
		{"*.example.test", "a.b.example.test", "a.b.example.test", true},
		{"*.example.test", "example.test", "", false},
		{"*", "a.example.test", "a.example.test", true},
	} {
		if h, ok := intersectHost(item.a, item.b); ok != item.ok || h != item.want {
			t.Fatalf("intersection %q %q: %q %v", item.a, item.b, h, ok)
		}
	}
	gateway := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"Gateway","metadata":{"name":"edge","namespace":"apps"},"spec":{"gatewayClassName":"lightedge","listeners":[{"name":"wild","port":80,"protocol":"HTTP","hostname":"*.apps.example.test"},{"name":"exact","port":80,"protocol":"HTTP","hostname":"reserved.apps.example.test"}]}}`)
	route := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"wild","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge","sectionName":"wild"}],"rules":[{"backendRefs":[{"name":"web","port":8080}]}]}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), gateway, route)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(0).Sites
	if len(sites) != 2 || sites[0].Host != "*.apps.example.test" || sites[1].Host != "reserved.apps.example.test" || len(sites[1].Routes) != 0 || len(sites[1].Listeners) != 1 {
		t.Fatalf("listener not reserved: %+v", sites)
	}
}

func TestMissingGatewayBackendAndTransientDiscovery(t *testing.T) {
	route := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"missing","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"rules":[{"backendRefs":[{"name":"missing","port":8080}]}]}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, gatewayJSON), route)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if inv.Parents[0].RefReason != "BackendNotFound" || inv.Plan.Snapshot(0).Sites[0].Routes[0].Backends[0].Target != "invalid" {
		t.Fatalf("unexpected missing reference result: %+v", inv.Parents)
	}
	r.Client.(*dynamicfake.FakeDynamicClient).PrependReactor("get", "services", func(ktesting.Action) (bool, runtime.Object, error) {
		return true, nil, errors.New("temporary API outage")
	})
	if _, err := r.Build(context.Background()); err == nil {
		t.Fatal("transient discovery error must not replace the last applied snapshot")
	}
}

func TestUnsupportedRouteAndListenerIsolated(t *testing.T) {
	bad := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"bad","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge","sectionName":"http"}],"rules":[{"matches":[{"path":{"type":"Exact","value":"/partial"}}],"backendRefs":[{"name":"web","port":8080}]},{"filters":[{"type":"ExtensionRef","extensionRef":{"group":"example.test","kind":"Unknown","name":"bad"}}]}]}}`)
	g := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"Gateway","metadata":{"name":"edge","namespace":"apps"},"spec":{"gatewayClassName":"lightedge","listeners":[{"name":"http","port":80,"protocol":"HTTP","hostname":"gateway.apps.example.test"},{"name":"broken","port":443,"protocol":"HTTPS","hostname":"gateway.apps.example.test","tls":{"certificateRefs":[{"name":"missing-tls"}]}}]}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), g, obj(t, routeJSON), bad)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(0).Sites
	if len(sites) != 1 || len(sites[0].Routes) != 1 || sites[0].Routes[0].Path != "/" {
		t.Fatalf("partial invalid route leaked: %+v", sites)
	}
	if inv.Parents[0].RejectedReason != "UnsupportedValue" || inv.Parents[1].RejectedReason != "" {
		t.Fatalf("unexpected parent status %+v", inv.Parents)
	}
	if inv.ListenerErrors["apps/edge/broken"].RefReason != "InvalidCertificateRef" {
		t.Fatalf("wrong listener error: %+v", inv.ListenerErrors)
	}
	if err = r.Report(context.Background(), inv, true, true); err != nil {
		t.Fatal(err)
	}
	actual, err := get[gw.Gateway](context.Background(), r.Client, GatewayGVR, "apps", "edge")
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range actual.Status.Listeners {
		if l.Name == "broken" {
			for _, c := range l.Conditions {
				if c.Type == "ResolvedRefs" && c.Status == meta.ConditionFalse && c.Reason == "InvalidCertificateRef" {
					return
				}
			}
		}
	}
	t.Fatal("missing invalid certificate status")
}

func TestSameListenerHostnameFallback(t *testing.T) {
	gateway := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"Gateway","metadata":{"name":"edge","namespace":"apps"},"spec":{"gatewayClassName":"lightedge","listeners":[{"name":"http","protocol":"HTTP","port":80,"hostname":"*.apps.example.test"}]}}`)
	broad := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"a-broad","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"hostnames":["*.apps.example.test"],"rules":[{"backendRefs":[{"name":"web","port":8080}]},{"matches":[{"path":{"type":"Exact","value":"/fallback"}}],"backendRefs":[{"name":"web","port":8080}]}]}}`)
	exact := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"z-exact","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"hostnames":["exact.apps.example.test"],"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/exact"}}],"backendRefs":[{"name":"canary","port":8080}]}]}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), gateway, broad, exact)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(0).Sites
	if len(sites) != 2 || len(sites[0].Routes) != 2 || len(sites[1].Routes) != 3 {
		t.Fatalf("missing same-listener fallback %+v", sites)
	}
	for _, route := range sites[1].Routes {
		if route.Path == "/exact" && route.HostPriority <= 1000 {
			t.Fatalf("specific hostname priority lost: %+v", route)
		}
	}
}

func TestConflictingPolicyIsolatesTarget(t *testing.T) {
	p1 := obj(t, `{"apiVersion":"lightedge.blaize.net/v1alpha1","kind":"LightEdgePolicy","metadata":{"name":"one","namespace":"apps"},"spec":{"targetRef":{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"route"},"waf":{"paranoiaLevel":2}}}`)
	p2 := obj(t, `{"apiVersion":"lightedge.blaize.net/v1alpha1","kind":"LightEdgePolicy","metadata":{"name":"two","namespace":"apps"},"spec":{"targetRef":{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"route"},"waf":{"paranoiaLevel":3}}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), obj(t, gatewayJSON), obj(t, routeJSON), obj(t, ingressJSON), p1, p2)
	r.Config.Policies = true
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(0).Sites
	if len(sites) != 1 || sites[0].Host != "ingress.apps.example.test" {
		t.Fatalf("invalid policy must not affect healthy Ingress: %+v", sites)
	}
	if inv.Parents[0].RejectedReason != "UnsupportedValue" || len(inv.PolicyErrors) != 2 {
		t.Fatalf("missing policy failure status: %+v", inv.PolicyErrors)
	}
	if err := r.Report(context.Background(), inv, true, true); err != nil {
		t.Fatal(err)
	}
	policy, err := get[NativePolicy](context.Background(), r.Client, policyGVR, "apps", "one")
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range policy.Status.Conditions {
		if c.Type == "Accepted" && c.Status == meta.ConditionFalse && c.Reason == "Conflicted" {
			return
		}
	}
	t.Fatal("conflicting policy accepted")
}

func TestGatewayQueryAndPathModifiers(t *testing.T) {
	route := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"advanced","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/api"},"queryParams":[{"name":"Version","value":"two"}]}],"filters":[{"type":"URLRewrite","urlRewrite":{"hostname":"backend.apps.example.test","path":{"type":"ReplacePrefixMatch","replacePrefixMatch":"/v2"}}}],"backendRefs":[{"name":"web","port":8080}]},{"matches":[{"path":{"type":"Exact","value":"/old"}}],"filters":[{"type":"RequestRedirect","requestRedirect":{"statusCode":302,"path":{"type":"ReplaceFullPath","replaceFullPath":"/new"}}}]}]}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, gatewayJSON), route)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(0).Sites
	if len(sites) != 1 || len(sites[0].Routes) != 2 {
		t.Fatalf("advanced translation missing: %+v", sites)
	}
	a, b := sites[0].Routes[0], sites[0].Routes[1]
	if a.Rewrite == nil || a.Rewrite.Path == nil || a.Rewrite.Path.Type != "prefix" || a.Rewrite.Path.Value != "/v2" || a.Rewrite.Hostname != "backend.apps.example.test" || len(a.QueryMatches) != 1 || a.QueryMatches[0].Name != "Version" {
		t.Fatalf("wrong rewrite or query: %+v", a)
	}
	if b.Redirect == nil || b.Redirect.Path == nil || b.Redirect.Path.Type != "full" || b.Redirect.Path.Value != "/new" {
		t.Fatalf("wrong redirect: %+v", b)
	}
}

func TestIngressWildcardDefaultAndOptIn(t *testing.T) {
	ing := obj(t, `{"apiVersion":"networking.k8s.io/v1","kind":"Ingress","metadata":{"name":"wild","namespace":"apps"},"spec":{"ingressClassName":"lightedge","defaultBackend":{"service":{"name":"web","port":{"number":8080}}},"rules":[{"host":"*.ing.apps.example.test","http":{"paths":[{"path":"/canary","pathType":"Prefix","backend":{"service":{"name":"canary","port":{"number":8080}}}}]}}]}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), obj(t, gatewayJSON), obj(t, routeJSON), ing)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if inv.IngressErrors["apps/wild"] != "UnsupportedValue" || len(inv.Plan.Snapshot(0).Sites) != 1 {
		t.Fatalf("missing catch-all opt-in protection: %+v", inv.IngressErrors)
	}
	r.Config.IngressCatchAll = true
	r.Config.IngressWildcard = true
	inv, err = r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(0).Sites
	if len(sites) != 3 || sites[0].Host != "*" || len(sites[0].Routes) != 1 || !sites[1].WildcardSingle || len(sites[1].Routes) != 2 || sites[2].Host != "gateway.apps.example.test" {
		t.Fatalf("unexpected wildcard/default plan: %+v", sites)
	}
	if sites[1].Routes[0].Path != "/" || sites[1].Routes[0].Backends[0].Target != "http://10.96.0.5:8080" {
		t.Fatalf("wrong default fallback: %+v", sites[1].Routes)
	}
}

func TestGatewayResponseHeaderOperations(t *testing.T) {
	route := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"response","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"rules":[{"filters":[{"type":"ResponseHeaderModifier","responseHeaderModifier":{"set":[{"name":"X-Result","value":"new"}],"add":[{"name":"X-Add","value":"extra"}],"remove":["X-Remove"]}}],"backendRefs":[{"name":"web","port":8080}]}]}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, gatewayJSON), route)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(0).Sites
	if len(sites) != 1 || len(sites[0].Routes) != 1 || len(sites[0].Routes[0].ResponseHeaders) != 3 {
		t.Fatalf("missing response operations: %+v", sites)
	}
}

func TestIndependentGatewayScopesAndStatus(t *testing.T) {
	blue := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"Gateway","metadata":{"name":"blue","namespace":"apps"},"spec":{"gatewayClassName":"lightedge","listeners":[{"name":"http","port":80,"protocol":"HTTP","hostname":"same.apps.example.test"}]}}`)
	green := blue.DeepCopy()
	green.SetName("green")
	dual := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"dual","namespace":"apps"},"spec":{"parentRefs":[{"name":"blue"},{"name":"green"}],"rules":[{"backendRefs":[{"name":"web","port":8080}]}]}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), blue, green, dual)
	r.Config.Ingress = false
	a, b := r, r
	a.Config.Scope = &GatewayScope{Default: true, Elsewhere: map[string]bool{"apps/green": true}}
	b.Config.Scope = &GatewayScope{Assigned: map[string]bool{"apps/green": true}}
	a.Config.Addresses = []string{"192.0.2.10"}
	b.Config.Addresses = []string{"192.0.2.11"}
	ctx := context.Background()
	for _, v := range []Reader{a, b} {
		inv, err := v.Build(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if len(inv.Gateways) != 1 || len(inv.Parents) != 1 || len(inv.Plan.Snapshot(0).Sites) != 1 {
			t.Fatalf("partition leaked: %+v", inv)
		}
		if err = v.Report(ctx, inv, true, true); err != nil {
			t.Fatal(err)
		}
	}
	route, err := get[gw.HTTPRoute](ctx, r.Client, HTTPRouteGVR, "apps", "dual")
	if err != nil {
		t.Fatal(err)
	}
	if len(route.Status.Parents) != 2 {
		t.Fatalf("one partition erased the other: %+v", route.Status)
	}
	inv, err := a.Build(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err = a.Report(ctx, inv, true, false); err != nil {
		t.Fatal(err)
	}
	route, err = get[gw.HTTPRoute](ctx, r.Client, HTTPRouteGVR, "apps", "dual")
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range route.Status.Parents {
		for _, c := range p.Conditions {
			if c.Type == "Programmed" && ((p.ParentRef.Name == "blue" && c.Status != meta.ConditionFalse) || (p.ParentRef.Name == "green" && c.Status != meta.ConditionTrue)) {
				t.Fatalf("wrong per-parent programming: %+v", p)
			}
		}
	}
}

func TestGatewayPolicyInheritanceAndOverride(t *testing.T) {
	gwpolicy := obj(t, `{"apiVersion":"lightedge.blaize.net/v1alpha1","kind":"LightEdgePolicy","metadata":{"name":"gateway-default","namespace":"apps"},"spec":{"targetRef":{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"edge"},"waf":{"paranoiaLevel":3,"profile":"strict"},"rateLimit":{"requestsPerSecond":50},"maxBodySize":"2m","allowIPs":["192.0.2.0/24"]}}`)
	routepolicy := obj(t, `{"apiVersion":"lightedge.blaize.net/v1alpha1","kind":"LightEdgePolicy","metadata":{"name":"route-override","namespace":"apps"},"spec":{"targetRef":{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"route"},"waf":{"paranoiaLevel":4},"rateLimit":{"requestsPerSecond":0}}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), obj(t, gatewayJSON), obj(t, routeJSON), gwpolicy, routepolicy)
	r.Config.Policies = true
	ctx := context.Background()
	inv, err := r.Build(ctx)
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(0).Sites
	if len(sites) != 1 || len(sites[0].Routes) != 1 {
		t.Fatalf("missing inherited route: %+v", sites)
	}
	v := sites[0].Routes[0]
	if v.WAFPL != 4 || v.WAFProfile != "strict" || v.RateCount != 0 || v.MaxBody != "2m" || len(v.AllowIPs) != 1 || v.WAFProfileOwner != "apps/gateway-default" || v.WAFLevelOwner != "apps/route-override" {
		t.Fatalf("wrong inheritance: %+v", v)
	}
	if err = r.Report(ctx, inv, true, true); err != nil {
		t.Fatal(err)
	}
	p, err := get[NativePolicy](ctx, r.Client, policyGVR, "apps", "gateway-default")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Status.Conditions) != 1 || p.Status.Conditions[0].Status != meta.ConditionTrue {
		t.Fatalf("Gateway policy not accepted: %+v", p.Status)
	}
	base := Policy{WAFPL: 3, WAFProfile: "strict", RateCount: 50, RateSpecified: true, AllowIPs: []string{"192.0.2.0/24"}}
	for _, override := range []Policy{{WAFPL: 1}, {WAFProfile: "weak"}, {RateCount: 0, RateSpecified: true}, {AllowIPs: []string{}}} {
		if _, err := inheritPolicy(base, override, false); err == nil {
			t.Fatalf("cross-namespace weakening accepted: %+v", override)
		}
	}
	if got, err := inheritPolicy(base, Policy{WAFPL: 4, RateCount: 25, RateSpecified: true}, false); err != nil || got.WAFPL != 4 || got.RateCount != 25 {
		t.Fatalf("stricter policy rejected: %+v %v", got, err)
	}
}

func TestRequestMirrorReferences(t *testing.T) {
	for _, tc := range []struct {
		name, ref, sampling string
		points              int
		want                string
		reason              string
	}{
		{"approved", `{"name":"canary","port":8080}`, "", 10000, "http://10.96.0.6:8080", ""},
		{"percentage", `{"name":"canary","port":8080}`, `,"percent":30`, 3000, "http://10.96.0.6:8080", ""},
		{"fraction", `{"name":"canary","port":8080}`, `,"fraction":{"numerator":1,"denominator":3}`, 3333, "http://10.96.0.6:8080", ""},
		{"zero", `{"name":"canary","port":8080}`, `,"percent":0`, 0, "", ""},
		{"zeroMissing", `{"name":"missing","port":8080}`, `,"percent":0`, 0, "", "BackendNotFound"},
		{"missing", `{"name":"missing","port":8080}`, "", 0, "", "BackendNotFound"},
		{"denied", `{"name":"canary","namespace":"other","port":8080}`, "", 0, "", "RefNotPermitted"},
		{"kind", `{"name":"canary","kind":"Secret","port":8080}`, "", 0, "", "InvalidKind"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			route := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"mirror","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"rules":[{"backendRefs":[{"name":"web","port":8080}],"filters":[{"type":"RequestMirror","requestMirror":{"backendRef":`+tc.ref+tc.sampling+`}}]}]}}`)
			r := fakeReader(t, obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), obj(t, gatewayJSON), route)
			r.Config.Ingress = false
			inv, err := r.Build(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			sites := inv.Plan.Snapshot(0).Sites
			if len(sites) != 1 || len(sites[0].Routes) != 1 || len(sites[0].Routes[0].Backends) != 1 || sites[0].Routes[0].Backends[0].Target != "http://10.96.0.5:8080" {
				t.Fatalf("primary backend lost: %+v", sites)
			}
			mirrors := sites[0].Routes[0].Mirrors
			if tc.want == "" && len(mirrors) != 0 || tc.want != "" && (len(mirrors) != 1 || (mirrors[0].Target != tc.want || mirrors[0].BasisPoints != tc.points)) {
				t.Fatalf("wrong mirrors: %+v", mirrors)
			}
			if len(inv.Parents) != 1 || inv.Parents[0].RefReason != tc.reason || inv.Parents[0].RejectedReason != "" {
				t.Fatalf("wrong route status: %+v", inv.Parents)
			}
		})
	}
}

func TestListenerSupportedKindsStatus(t *testing.T) {
	for _, tc := range []struct {
		kinds string
		count int
	}{
		{`[{"kind":"InvalidRoute"}]`, 0},
		{`[{"kind":"InvalidRoute"},{"kind":"HTTPRoute"}]`, 1},
	} {
		g := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"Gateway","metadata":{"name":"edge","namespace":"apps"},"spec":{"gatewayClassName":"lightedge","listeners":[{"name":"http","port":80,"protocol":"HTTP","allowedRoutes":{"kinds":`+tc.kinds+`}}]}}`)
		r := fakeReader(t, obj(t, gatewayClassJSON), g)
		r.Config.Ingress = false
		ctx := context.Background()
		inv, err := r.Build(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err = r.Report(ctx, inv, true, true); err != nil {
			t.Fatal(err)
		}
		gateway, err := r.Client.Resource(GatewayGVR).Namespace("apps").Get(ctx, "edge", meta.GetOptions{})
		if err != nil {
			t.Fatal(err)
		}
		listeners, found, err := unstructured.NestedSlice(gateway.Object, "status", "listeners")
		if err != nil || !found || len(listeners) != 1 {
			t.Fatalf("listener status absent: %+v", gateway.Object["status"])
		}
		listener := listeners[0].(map[string]any)
		kinds, found, err := unstructured.NestedSlice(listener, "supportedKinds")
		if err != nil || !found || len(kinds) != tc.count {
			t.Fatalf("required supportedKinds array: %+v", listener)
		}
		conditions := listener["conditions"].([]any)
		resolved := false
		for _, c := range conditions {
			v := c.(map[string]any)
			if v["type"] == "ResolvedRefs" && v["status"] == "False" && v["reason"] == "InvalidRouteKinds" {
				resolved = true
			}
		}
		if !resolved {
			t.Fatalf("missing InvalidRouteKinds: %+v", listener)
		}
	}
}

func TestExtraHTTPListenerPortIsolation(t *testing.T) {
	g := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"Gateway","metadata":{"name":"edge","namespace":"apps"},"spec":{"gatewayClassName":"lightedge","listeners":[{"name":"main","port":80,"protocol":"HTTP","hostname":"web.apps.example.test"},{"name":"extra","port":8080,"protocol":"HTTP","hostname":"web.apps.example.test"},{"name":"denied","port":8090,"protocol":"HTTP","hostname":"web.apps.example.test"}]}}`)
	route1 := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"main","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge","port":80}],"rules":[{"backendRefs":[{"name":"web","port":8080}]}]}}`)
	route2 := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"extra","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge","port":8080}],"rules":[{"backendRefs":[{"name":"canary","port":8080}]}]}}`)
	route3 := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"denied","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge","port":8090}],"rules":[{"backendRefs":[{"name":"canary","port":8080}]}]}}`)
	r := fakeReader(t, obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), g, route1, route2, route3)
	r.Config.Ingress = false
	r.Config.ExtraHTTPPorts = []int{8080}
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(0).Sites
	if len(sites) != 1 || len(sites[0].Routes) != 2 || len(sites[0].Listeners) != 2 {
		t.Fatalf("unexpected port isolation: %+v", sites)
	}
	want := map[string]string{"http": "http://10.96.0.5:8080", "http:8080": "http://10.96.0.6:8080"}
	for _, route := range sites[0].Routes {
		if len(route.Schemes) != 1 || len(route.Backends) != 1 || want[route.Schemes[0]] != route.Backends[0].Target {
			t.Fatalf("wrong backend for port: %+v", route)
		}
		delete(want, route.Schemes[0])
	}
	if len(want) != 0 {
		t.Fatal(want)
	}
	if inv.ListenerErrors["apps/edge/denied"].Reason == "" {
		t.Fatalf("unprovisioned port accepted: %+v", inv.ListenerErrors)
	}
}

func TestBoundedBackendRetry(t *testing.T) {
	for _, tc := range []struct {
		name, config, backends string
		valid                  bool
		attempts               int
	}{
		{"pool", `{"attempts":2,"codes":[503,502]}`, `[{"name":"web","port":8080},{"name":"canary","port":8080}]`, true, 2},
		{"disabled", `{"attempts":0}`, `[{"name":"web","port":8080}]`, true, 0},
		{"single", `{"attempts":1}`, `[{"name":"web","port":8080}]`, false, 0},
		{"backoff", `{"attempts":1,"backoff":"100ms"}`, `[{"name":"web","port":8080},{"name":"canary","port":8080}]`, true, 1},
		{"invalid", `{"attempts":1,"codes":[500]}`, `[{"name":"web","port":8080},{"name":"missing","port":8080}]`, false, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			route := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"retry","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"rules":[{"backendRefs":`+tc.backends+`,"retry":`+tc.config+`}]}}`)
			r := fakeReader(t, obj(t, gatewayClassJSON), obj(t, serviceJSON), obj(t, serviceTwoJSON), obj(t, gatewayJSON), route)
			r.Config.Ingress = false
			inv, err := r.Build(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			sites := inv.Plan.Snapshot(0).Sites
			if tc.valid {
				if len(sites) != 1 || len(sites[0].Routes) != 1 || sites[0].Routes[0].Retry == nil || sites[0].Routes[0].Retry.Attempts != tc.attempts {
					t.Fatalf("wrong retry %+v", sites)
				}
			} else if len(inv.Parents) != 1 || inv.Parents[0].RejectedReason != "UnsupportedValue" {
				t.Fatalf("unsupported retry not rejected: %+v", inv.Parents)
			}
		})
	}
}

func TestUnresolvedListenerAttachmentCount(t *testing.T) {
	g := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"Gateway","metadata":{"name":"edge","namespace":"apps"},"spec":{"gatewayClassName":"lightedge","listeners":[{"name":"broken","port":443,"protocol":"HTTPS","hostname":"gateway.apps.example.test","tls":{"certificateRefs":[{"name":"missing-tls"}]}}]}}`)
	route := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"broken","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge","sectionName":"broken"}],"rules":[{"backendRefs":[{"name":"missing","port":8080}]}]}}`)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), g, route)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(inv.Attachments) != 1 || len(inv.Plan.Snapshot(0).Sites) != 0 || inv.ListenerErrors["apps/edge/broken"].RefReason != "InvalidCertificateRef" || len(inv.Parents) != 1 || inv.Parents[0].RefReason != "BackendNotFound" {
		t.Fatalf("attachment accounting must not program invalid TLS: %+v", inv)
	}
	inv.ProviderRejected(nil)
	if err := r.Report(context.Background(), inv, true, true); err != nil {
		t.Fatal(err)
	}
	actual, err := get[gw.Gateway](context.Background(), r.Client, GatewayGVR, "apps", "edge")
	if err != nil {
		t.Fatal(err)
	}
	if len(actual.Status.Listeners) != 1 || actual.Status.Listeners[0].AttachedRoutes != 1 {
		t.Fatalf("incorrect attachedRoutes: %+v", actual.Status.Listeners)
	}
}

func TestOwnedUnconfiguredClassReportedWithoutAdoption(t *testing.T) {
	other := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"GatewayClass","metadata":{"name":"other","generation":2},"spec":{"controllerName":"blaize.net/lightedge-controller"}}`)
	foreign := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"GatewayClass","metadata":{"name":"foreign","generation":3},"spec":{"controllerName":"example.test/another"}}`)
	other.SetGeneration(2)
	foreign.SetGeneration(3)
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), other, foreign)
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(inv.Classes) != 2 {
		t.Fatalf("unexpected classes: %+v", inv.Classes)
	}
	if err := r.Report(context.Background(), inv, true, true); err != nil {
		t.Fatal(err)
	}
	c, err := get[gw.GatewayClass](context.Background(), r.Client, GatewayClassGVR, "", "other")
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Status.Conditions) != 1 || c.Status.Conditions[0].Status != meta.ConditionFalse || c.Status.Conditions[0].ObservedGeneration != 2 {
		t.Fatalf("unconfigured class incorrectly reported: %+v", c.Status)
	}
	c, err = get[gw.GatewayClass](context.Background(), r.Client, GatewayClassGVR, "", "foreign")
	if err != nil || len(c.Status.Conditions) != 0 {
		t.Fatalf("foreign class modified: %+v %v", c.Status, err)
	}
}

func TestStaleStatusObservationDoesNotBackOff(t *testing.T) {
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, gatewayJSON))
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	g, err := r.Client.Resource(GatewayGVR).Namespace("apps").Get(context.Background(), "edge", meta.GetOptions{})
	if err != nil {
		t.Fatal(err)
	}
	g.SetGeneration(2)
	if _, err = r.Client.Resource(GatewayGVR).Namespace("apps").Update(context.Background(), g, meta.UpdateOptions{}); err != nil {
		t.Fatal(err)
	}
	if err = r.Report(context.Background(), inv, true, true); err != nil {
		t.Fatal(err)
	}
	current, err := get[gw.Gateway](context.Background(), r.Client, GatewayGVR, "apps", "edge")
	if err != nil || len(current.Status.Conditions) != 0 {
		t.Fatalf("stale status published: %+v %v", current.Status, err)
	}
	if err = r.Client.Resource(GatewayGVR).Namespace("apps").Delete(context.Background(), "edge", meta.DeleteOptions{}); err != nil {
		t.Fatal(err)
	}
	if err = r.Report(context.Background(), inv, true, true); err != nil {
		t.Fatal(err)
	}
}

func TestRouteDeadlines(t *testing.T) {
	for _, tc := range []struct {
		name, timeout, retry      string
		valid                     bool
		request, backend, backoff int
	}{
		{"positive", `{"request":"2s","backendRequest":"250ms"}`, `{"attempts":1,"backoff":"100ms"}`, true, 2000, 250, 100},
		{"zero", `{"request":"0s","backendRequest":"0s"}`, `{"attempts":0}`, true, 0, 0, 0},
		{"invalid", `{"request":"100ms","backendRequest":"200ms"}`, `{"attempts":0}`, false, 0, 0, 0},
		{"oversized", `{"request":"2h"}`, `{"attempts":0}`, false, 0, 0, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			route := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"deadline","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge"}],"rules":[{"backendRefs":[{"name":"web","port":8080}],"timeouts":`+tc.timeout+`,"retry":`+tc.retry+`}]}}`)
			r := fakeReader(t, obj(t, gatewayClassJSON), obj(t, gatewayJSON), obj(t, serviceJSON), route)
			r.Config.Ingress = false
			inv, err := r.Build(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if !tc.valid {
				if inv.Parents[0].RejectedReason != "UnsupportedValue" {
					t.Fatal(inv.Parents)
				}
				return
			}
			x := inv.Plan.Snapshot(0).Sites[0].Routes[0]
			if x.Deadlines == nil || ptr(x.Deadlines.RequestMS, -1) != tc.request || ptr(x.Deadlines.BackendMS, -1) != tc.backend || x.Retry.BackoffMS != tc.backoff {
				t.Fatal(x)
			}
		})
	}
}
