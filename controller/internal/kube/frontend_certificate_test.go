package kube

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"math/big"
	gw "sigs.k8s.io/gateway-api/apis/v1"
	"testing"
	"time"
)

func frontendSecret(t *testing.T, name string, notBefore, notAfter time.Time) *unstructured.Unstructured {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: name}, DNSNames: []string{name}, NotBefore: notBefore, NotAfter: notAfter, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	secret := obj(t, `{"apiVersion":"v1","kind":"Secret","metadata":{"namespace":"apps","name":"frontend"},"type":"kubernetes.io/tls"}`)
	unstructured.SetNestedStringMap(secret.Object, map[string]string{"tls.crt": base64.StdEncoding.EncodeToString(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})), "tls.key": base64.StdEncoding.EncodeToString(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}))}, "data")
	return secret
}
func TestGatewayClientValidatedFrontend(t *testing.T) {
	ctx := context.Background()
	gateway := obj(t, `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"Gateway","metadata":{"namespace":"apps","name":"edge"},"spec":{"gatewayClassName":"lightedge","listeners":[{"name":"https","port":443,"protocol":"HTTPS","hostname":"gateway.apps.example.test","tls":{"certificateRefs":[{"name":"frontend"}]}}]}}`)
	for _, tc := range []struct {
		name     string
		allow    bool
		certHost string
		expired  bool
		accepted bool
		warning  bool
	}{
		{"strict-mismatch", false, "other.apps.example.test", false, false, false},
		{"client-validated", true, "other.apps.example.test", false, true, true},
		{"strict-valid", false, "gateway.apps.example.test", false, true, false},
		{"compatibility-expired", true, "other.apps.example.test", true, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			end := time.Now().Add(time.Hour)
			if tc.expired {
				end = time.Now().Add(-time.Minute)
			}
			r := fakeReader(t, obj(t, gatewayClassJSON), gateway.DeepCopy(), obj(t, tlsRouteJSON), obj(t, serviceJSON), frontendSecret(t, tc.certHost, time.Now().Add(-time.Hour), end))
			r.Config.Ingress = false
			r.Config.GatewayClientValidatedFrontend = tc.allow
			inv, err := r.Build(ctx)
			if err != nil {
				t.Fatal(err)
			}
			const lk = "apps/edge/https"
			accepted := inv.ListenerErrors[lk].Reason == ""
			if accepted != tc.accepted || inv.FrontendCertificateWarnings[lk] != tc.warning {
				t.Fatalf("listener=%+v warnings=%+v", inv.ListenerErrors, inv.FrontendCertificateWarnings)
			}
			if err = r.Report(ctx, inv, true, true); err != nil {
				t.Fatal(err)
			}
			g, err := get[gw.Gateway](ctx, r.Client, GatewayGVR, "apps", "edge")
			if err != nil {
				t.Fatal(err)
			}
			found := false
			for _, c := range g.Status.Listeners[0].Conditions {
				if c.Type == "lightedge.blaize.net/FrontendCertificateHostnameMismatch" && c.Status == meta.ConditionTrue {
					found = true
				}
			}
			if found != tc.warning {
				t.Fatal(g.Status)
			}
		})
	}
}
