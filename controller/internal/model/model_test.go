package model

import "testing"

func TestMergeSchemesAndConflict(t *testing.T) {
	p := NewPlan()
	r := Route{Match: "prefix", Path: "/", Backends: []Backend{{Target: "http://10.0.0.1:80", Weight: 1}}, Schemes: []string{"http"}}
	if err := p.Add("web.example.test", r); err != nil {
		t.Fatal(err)
	}
	r.Schemes = []string{"https"}
	if err := p.Add("web.example.test", r); err != nil {
		t.Fatal(err)
	}
	s := p.Snapshot(2)
	if len(s.Sites) != 1 || len(s.Sites[0].Routes) != 1 || len(s.Sites[0].Routes[0].Schemes) != 2 {
		t.Fatalf("bad merge: %+v", s)
	}
	r.Backends = []Backend{{Target: "http://10.0.0.2:80", Weight: 1}}
	if p.Add("web.example.test", r) == nil {
		t.Fatal("conflict accepted")
	}
}
func TestEmptySnapshot(t *testing.T) {
	if NewPlan().Snapshot(0).Sites == nil {
		t.Fatal("nil snapshot")
	}
}
