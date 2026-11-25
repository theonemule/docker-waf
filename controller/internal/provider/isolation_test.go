package provider

import (
	"context"
	"errors"
	"github.com/theonemule/docker-waf/controller/internal/model"
	"testing"
)

type validatingAppliance struct {
	revision  int64
	denied    string
	globalErr error
	applied   []model.Snapshot
}

func (a *validatingAppliance) Get(context.Context) (State, error) {
	return State{Revision: a.revision}, nil
}
func (a *validatingAppliance) Validate(_ context.Context, s model.Snapshot) (State, error) {
	if a.globalErr != nil {
		return State{}, a.globalErr
	}
	if s.Revision != a.revision {
		return State{}, errors.New("bad preflight CAS")
	}
	for i, site := range s.Sites {
		for j, r := range site.Routes {
			if r.WAFProfile == a.denied && a.denied != "" {
				i, j := i, j
				return State{}, &HTTPError{Status: 403, Method: "POST", Rejection: &Rejection{SiteIndex: &i, RouteIndex: &j}}
			}
		}
	}
	return State{Revision: s.Revision}, nil
}
func (a *validatingAppliance) Apply(ctx context.Context, s model.Snapshot) (State, error) {
	if _, err := a.Validate(ctx, s); err != nil {
		return State{}, err
	}
	a.applied = append(a.applied, s)
	a.revision++
	return State{Revision: a.revision}, nil
}
func TestQuarantineAcrossReplicasAndInheritedRules(t *testing.T) {
	origin := model.Origin{Kind: "HTTPRoute", Key: "app/bad", Gateway: "app/edge", Listener: "http"}
	good := model.Origin{Kind: "HTTPRoute", Key: "app/good", Gateway: "app/edge", Listener: "http"}
	bad := model.Route{Origins: []model.Origin{origin}, Match: "exact", Path: "/secure", Schemes: []string{"http"}, HeaderMatches: []model.HeaderMatch{{Name: "x-mode", Value: "secret"}}, HostPriority: 42, Precedence: 3, WAFProfile: "not-approved", Backends: []model.Backend{{Target: "http://10.96.0.8:80", Weight: 1}}}
	healthy := model.Route{Origins: []model.Origin{good}, Match: "prefix", Path: "/", Schemes: []string{"http"}, Backends: []model.Backend{{Target: "http://10.96.0.9:80", Weight: 1}}}
	s := model.Snapshot{Sites: []model.Site{{Host: "a.example.test", Routes: []model.Route{bad, healthy}}, {Host: "b.example.test", Routes: []model.Route{bad}}}}
	a, b := &validatingAppliance{revision: 2}, &validatingAppliance{revision: 7, denied: "not-approved"}
	results, rejected, err := Reconcile(context.Background(), []Target{{"a", a}, {"b", b}}, s)
	if err != nil || len(rejected) != 1 || len(results) != 2 || len(a.applied) != 1 || len(b.applied) != 1 {
		t.Fatalf("unexpected result: %+v %+v %v", results, rejected, err)
	}
	for _, target := range []*validatingAppliance{a, b} {
		for _, site := range target.applied[0].Sites {
			r := site.Routes[0]
			if !r.Quarantined || r.Backends[0].Target != "invalid" || r.WAFProfile != "" || r.Match != "exact" || r.Path != "/secure" || len(r.HeaderMatches) != 1 || r.HostPriority != 42 {
				t.Fatalf("unsafe quarantine: %+v", r)
			}
		}
		if target.applied[0].Sites[0].Routes[1].Backends[0].Target != healthy.Backends[0].Target {
			t.Fatal("healthy route lost")
		}
	}
	if s.Sites[0].Routes[0].WAFProfile != "not-approved" {
		t.Fatal("input mutated")
	}
}
func TestGlobalValidationErrorDoesNotQuarantine(t *testing.T) {
	a := &validatingAppliance{globalErr: &HTTPError{Status: 409, Method: "POST"}}
	b := &validatingAppliance{}
	results, rejected, err := Reconcile(context.Background(), []Target{{"a", a}, {"b", b}}, model.Snapshot{Sites: []model.Site{}})
	if err == nil || len(rejected) != 0 || len(a.applied) != 0 || len(b.applied) != 1 || results[0].Err == nil {
		t.Fatalf("bad global failure handling: %+v %+v %v", results, rejected, err)
	}
}
func TestUntrustedCoordinatesRejected(t *testing.T) {
	i, j := 0, 100
	_, _, err := quarantine(model.Snapshot{Sites: []model.Site{{Host: "test"}}}, &HTTPError{Status: 403, Rejection: &Rejection{SiteIndex: &i, RouteIndex: &j}})
	if err == nil {
		t.Fatal("out-of-bounds coordinate accepted")
	}
}

func TestTransportPortQuarantine(t *testing.T) {
	origin := model.Origin{Kind: "TLSRoute", Key: "app/bad", Gateway: "app/edge", Listener: "tls"}
	other := model.Origin{Kind: "TLSRoute", Key: "app/wildcard", Gateway: "app/edge", Listener: "tls"}
	s := model.Snapshot{Sites: []model.Site{{Host: "healthy.example.test"}}, Streams: []model.StreamRoute{
		{Protocol: "tls", Port: 9444, Hostname: "bad.example.test", Origins: []model.Origin{origin}},
		{Protocol: "tls", Port: 9444, Hostname: "*.example.test", Origins: []model.Origin{other}},
		{Protocol: "tcp", Port: 9000},
	}}
	i := 0
	out, rejected, err := quarantine(s, &HTTPError{Status: 403, Rejection: &Rejection{StreamIndex: &i}})
	if err != nil || len(out.Streams) != 1 || out.Streams[0].Port != 9000 || len(out.Sites) != 1 || len(rejected.Origins) != 2 || len(s.Streams) != 3 {
		t.Fatalf("transport isolation failed: %+v %+v %v", out, rejected, err)
	}
}
