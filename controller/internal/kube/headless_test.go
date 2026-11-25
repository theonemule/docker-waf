package kube

import (
	"context"
	"errors"
	"testing"

	"k8s.io/apimachinery/pkg/runtime"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	ktesting "k8s.io/client-go/testing"
)

const headlessJSON = `{"apiVersion":"v1","kind":"Service","metadata":{"name":"web","namespace":"apps","uid":"current-service"},"spec":{"clusterIP":"None","ports":[{"name":"http","port":8080,"targetPort":9000,"protocol":"TCP"}]}}`
const sliceJSON = `{"apiVersion":"discovery.k8s.io/v1","kind":"EndpointSlice","metadata":{"name":"web-a","namespace":"apps","labels":{"kubernetes.io/service-name":"web"}},"addressType":"IPv4","ports":[{"name":"http","protocol":"TCP","port":9000},{"name":"other","port":8000}],"endpoints":[{"addresses":["10.244.0.5"],"conditions":{"ready":true}},{"addresses":["10.244.0.6"]},{"addresses":["10.244.0.7"],"conditions":{"ready":false}},{"addresses":["10.244.0.8"],"conditions":{"ready":true,"terminating":true}},{"addresses":["127.0.0.1"]}]}`
const duplicateSliceJSON = `{"apiVersion":"discovery.k8s.io/v1","kind":"EndpointSlice","metadata":{"name":"web-b","namespace":"apps","labels":{"kubernetes.io/service-name":"web"}},"addressType":"IPv4","ports":[{"name":"http","port":9000}],"endpoints":[{"addresses":["10.244.0.5"]}]}`
const staleSliceJSON = `{"apiVersion":"discovery.k8s.io/v1","kind":"EndpointSlice","metadata":{"name":"stale","namespace":"apps","labels":{"kubernetes.io/service-name":"web"},"ownerReferences":[{"kind":"Service","name":"web","uid":"old-service","apiVersion":"v1"}]},"addressType":"IPv4","ports":[{"name":"http","port":9000}],"endpoints":[{"addresses":["10.244.0.99"]}]}`
const otherSliceJSON = `{"apiVersion":"discovery.k8s.io/v1","kind":"EndpointSlice","metadata":{"name":"other","namespace":"other","labels":{"kubernetes.io/service-name":"web"}},"addressType":"IPv4","ports":[{"name":"http","port":9000}],"endpoints":[{"addresses":["10.244.0.98"]}]}`

func TestHeadlessServiceWeightAndIngress(t *testing.T) {
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, gatewayJSON), obj(t, routeJSON), obj(t, ingressJSON), obj(t, headlessJSON), obj(t, serviceTwoJSON), obj(t, sliceJSON), obj(t, duplicateSliceJSON), obj(t, staleSliceJSON), obj(t, otherSliceJSON))
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sites := inv.Plan.Snapshot(1).Sites
	if len(sites) != 2 {
		t.Fatalf("sites: %+v", sites)
	}
	g, i := sites[0].Routes[0].Backends, sites[1].Routes[0].Backends
	if len(g) != 3 || g[0].Target != "http://10.244.0.5:9000" || g[1].Target != "http://10.244.0.6:9000" || g[2].Target != "http://10.96.0.6:8080" || g[0].Weight != 90 || g[1].Weight != 90 || g[2].Weight != 20 {
		t.Fatalf("service weight or endpoint selection incorrect: %+v", g)
	}
	if len(i) != 2 || i[0].Weight != 1 || i[1].Weight != 1 || i[0].Target != g[0].Target || i[1].Target != g[1].Target {
		t.Fatalf("ingress targets: %+v", i)
	}
}

func TestHeadlessServiceEmptyAndDiscoveryFailure(t *testing.T) {
	r := fakeReader(t, obj(t, ingressClassJSON), obj(t, gatewayClassJSON), obj(t, gatewayJSON), obj(t, routeJSON), obj(t, headlessJSON), obj(t, serviceTwoJSON))
	inv, err := r.Build(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	backends := inv.Plan.Snapshot(1).Sites[0].Routes[0].Backends
	if len(backends) != 2 || backends[1].Target != "unavailable" || backends[1].Weight != 90 || inv.Parents[0].RefReason != "" {
		t.Fatalf("empty Service: %+v %+v", backends, inv.Parents)
	}
	r.Client.(*dynamicfake.FakeDynamicClient).PrependReactor("list", "endpointslices", func(ktesting.Action) (bool, runtime.Object, error) {
		return true, nil, errors.New("temporary discovery failure")
	})
	if _, err = r.Build(context.Background()); err == nil {
		t.Fatal("discovery failure must preserve previous snapshot")
	}
}
