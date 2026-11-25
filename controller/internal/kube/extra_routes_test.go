package kube

import (
	"context"
	"github.com/theonemule/docker-waf/controller/internal/model"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"reflect"
	gw "sigs.k8s.io/gateway-api/apis/v1"
	"testing"
)

const protocolGateway = `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"Gateway","metadata":{"name":"edge","namespace":"apps"},"spec":{"gatewayClassName":"lightedge","listeners":[{"name":"grpc","protocol":"HTTP","port":80,"hostname":"grpc.apps.example.test","allowedRoutes":{"kinds":[{"kind":"GRPCRoute"}]}},{"name":"tcp","protocol":"TCP","port":9000},{"name":"udp","protocol":"UDP","port":9001},{"name":"tls","protocol":"TLS","port":9444,"hostname":"*.apps.example.test","tls":{"mode":"Passthrough"}}]}}`
const protocolService = `{"apiVersion":"v1","kind":"Service","metadata":{"name":"wire","namespace":"backends"},"spec":{"clusterIP":"10.96.0.9","ports":[{"name":"tcp","port":12001,"protocol":"TCP"},{"name":"udp","port":12002,"protocol":"UDP"},{"name":"tls","port":12003,"protocol":"TCP"}]}}`
const protocolGRPC = `{"apiVersion":"gateway.networking.k8s.io/v1","kind":"GRPCRoute","metadata":{"name":"grpc","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge","sectionName":"grpc"}],"hostnames":["grpc.apps.example.test"],"rules":[{"matches":[{"method":{"service":"example.Echo","method":"Call"},"headers":[{"name":"version","value":"one"}]}],"backendRefs":[{"name":"web","port":8080}]}]}}`
const protocolTCP = `{"apiVersion":"gateway.networking.k8s.io/v1alpha2","kind":"TCPRoute","metadata":{"name":"tcp","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge","sectionName":"tcp"}],"rules":[{"backendRefs":[{"name":"wire","namespace":"backends","port":12001}]}]}}`
const protocolUDP = `{"apiVersion":"gateway.networking.k8s.io/v1alpha2","kind":"UDPRoute","metadata":{"name":"udp","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge","sectionName":"udp"}],"rules":[{"backendRefs":[{"name":"wire","namespace":"backends","port":12002}]}]}}`
const protocolTLS = `{"apiVersion":"gateway.networking.k8s.io/v1alpha2","kind":"TLSRoute","metadata":{"name":"tls","namespace":"apps"},"spec":{"parentRefs":[{"name":"edge","sectionName":"tls"}],"hostnames":["tls.apps.example.test"],"rules":[{"backendRefs":[{"name":"wire","namespace":"backends","port":12003}]}]}}`
const protocolGrant = `{"apiVersion":"gateway.networking.k8s.io/v1beta1","kind":"ReferenceGrant","metadata":{"name":"wire","namespace":"backends"},"spec":{"from":[{"group":"gateway.networking.k8s.io","kind":"TCPRoute","namespace":"apps"},{"group":"gateway.networking.k8s.io","kind":"TLSRoute","namespace":"apps"}],"to":[{"group":"","kind":"Service","name":"wire"}]}}`

func TestAdditionalProtocols(t *testing.T) {
	ctx := context.Background()
	r := fakeReader(t, obj(t, gatewayClassJSON), obj(t, protocolGateway), obj(t, serviceJSON), obj(t, protocolService), obj(t, protocolGRPC), obj(t, protocolTCP), obj(t, protocolUDP), obj(t, protocolTLS), obj(t, protocolGrant))
	r.Config.Ingress = false
	r.Config.GRPC = true
	r.Config.StreamPorts = map[string][]int{"tcp": {9000}, "udp": {9001}, "tls": {9444}}
	inv, err := r.Build(ctx)
	if err != nil {
		t.Fatal(err)
	}
	x := inv.Plan.Snapshot(0)
	if len(x.Sites) != 1 || len(x.Sites[0].Routes) != 1 {
		t.Fatal(x)
	}
	a := x.Sites[0].Routes[0]
	if !a.GRPC || a.Path != "/example.Echo/Call" || a.Match != "exact" || a.Method != "POST" || !reflect.DeepEqual(a.HeaderMatches, []model.HeaderMatch{{Name: "version", Value: "one"}}) {
		t.Fatal(a)
	}
	got := map[string]string{}
	for _, v := range x.Streams {
		got[v.Protocol+"/"+v.Hostname] = v.Backends[0].Target
	}
	if !reflect.DeepEqual(got, map[string]string{"tcp/": "tcp://10.96.0.9:12001", "udp/": "invalid", "tls/tls.apps.example.test": "tcp://10.96.0.9:12003", "tls/*.apps.example.test": "invalid"}) {
		t.Fatal(got)
	}
	if len(inv.ExtraParents) != 4 {
		t.Fatal(inv.ExtraParents)
	}
	for _, p := range inv.ExtraParents {
		if p.RejectedReason != "" || p.Route.Kind == "UDPRoute" && p.RefReason != "RefNotPermitted" || p.Route.Kind != "UDPRoute" && p.RefReason != "" {
			t.Fatal(p)
		}
	}
	if err = r.Report(ctx, inv, true, true); err != nil {
		t.Fatal(err)
	}
	for _, p := range inv.ExtraParents {
		actual, err := get[ExtraRoute](ctx, r.Client, p.Route.GVR, "apps", p.Route.Name)
		if err != nil {
			t.Fatal(err)
		}
		if len(actual.Status.Parents) != 1 {
			t.Fatal(actual.Status)
		}
		for _, c := range actual.Status.Parents[0].Conditions {
			if c.Type == "Accepted" && c.Status != meta.ConditionTrue {
				t.Fatal(c)
			}
			if c.Type == "ResolvedRefs" && p.Route.Kind == "UDPRoute" && c.Reason != "RefNotPermitted" {
				t.Fatal(c)
			}
		}
	}
	g, err := get[gw.Gateway](ctx, r.Client, GatewayGVR, "apps", "edge")
	if err != nil {
		t.Fatal(err)
	}
	if len(g.Status.Listeners) != 4 {
		t.Fatal(g.Status)
	}
	for _, l := range g.Status.Listeners {
		if l.AttachedRoutes != 1 || len(l.SupportedKinds) != 1 {
			t.Fatal(l)
		}
	}
}
func TestGRPCPolicyNeverDowngrades(t *testing.T) {
	r := fakeReader(t, obj(t, gatewayClassJSON), obj(t, protocolGateway), obj(t, serviceJSON), obj(t, protocolGRPC), tlsPolicy(t, "tls", "web", "", "ca", "backend.example.test"), testCAConfigMap(t))
	r.Config.Ingress = false
	r.Config.GRPC = true
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	x := inv.Plan.Snapshot(0)
	if len(x.Sites) != 1 || x.Sites[0].Routes[0].Backends[0].Target != "invalid" || inv.ExtraParents[0].RefReason != "UnsupportedValue" {
		t.Fatal(x, inv.ExtraParents)
	}
}
