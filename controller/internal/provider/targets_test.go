package provider

import (
	"context"
	"errors"
	"github.com/theonemule/docker-waf/controller/internal/model"
	"testing"
)

type fakeAppliance struct {
	revision int64
	offline  bool
	applied  []int64
}

func (f *fakeAppliance) Get(context.Context) (State, error) {
	if f.offline {
		return State{}, errors.New("offline")
	}
	return State{Revision: f.revision}, nil
}
func (f *fakeAppliance) Apply(_ context.Context, s model.Snapshot) (State, error) {
	f.applied = append(f.applied, s.Revision)
	if s.Revision != f.revision {
		return State{}, errors.New("conflict")
	}
	f.revision++
	return State{Revision: f.revision}, nil
}
func TestIndependentReplicationAndRecovery(t *testing.T) {
	a, b := &fakeAppliance{revision: 3}, &fakeAppliance{revision: 9, offline: true}
	targets := []Target{{"primary", a}, {"secondary", b}}
	s := model.Snapshot{Sites: []model.Site{}}
	results, err := Replicate(context.Background(), targets, s)
	if err == nil || results[0].Err != nil || results[1].Err == nil || a.revision != 4 || b.revision != 9 {
		t.Fatalf("unexpected partial result: %+v %v", results, err)
	}
	b.offline = false
	results, err = Replicate(context.Background(), targets, s)
	if err != nil || a.revision != 5 || b.revision != 10 || b.applied[0] != 9 {
		t.Fatalf("recovery failed: %+v %v", results, err)
	}
}
