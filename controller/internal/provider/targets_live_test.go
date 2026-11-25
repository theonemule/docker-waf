package provider

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/theonemule/docker-waf/controller/internal/model"
)

// This is opt-in: the shell harness creates both disposable appliances and
// supplies their TLS credentials. Ordinary unit tests never contact a server.
func TestLiveApplianceReplication(t *testing.T) {
	file := os.Getenv("LIGHTEDGE_TEST_TARGETS")
	if file == "" {
		t.Skip("run tests/test-multi-appliance-ha.sh")
	}
	targets, err := LoadTargets(file)
	if err != nil {
		t.Fatal(err)
	}
	phase := os.Getenv("LIGHTEDGE_TEST_PHASE")
	marker := "one"
	if phase != "initial" {
		marker = "two"
	}
	snapshot := model.Snapshot{Sites: []model.Site{{Host: "ha.apps.example.test", Listeners: []string{"http"}, Routes: []model.Route{{Match: "prefix", Path: "/", Schemes: []string{"http"}, Backends: []model.Backend{{Target: os.Getenv("LIGHTEDGE_TEST_BACKEND"), Weight: 1}}, RequestHeaders: []model.HeaderOperation{{Op: "set", Name: "X-Revision", Value: marker}}}}}}}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	results, err := Replicate(ctx, targets, snapshot)
	if len(results) != 2 {
		t.Fatalf("expected two targets, got %d", len(results))
	}
	switch phase {
	case "initial":
		if err != nil || results[0].State.Revision != 1 || results[1].State.Revision != 1 {
			t.Fatalf("initial replication: %+v %v", results, err)
		}
	case "outage":
		if err == nil || results[0].Err != nil || results[1].Err == nil || results[0].State.Revision != 2 {
			t.Fatalf("partial replication: %+v %v", results, err)
		}
	case "recovery":
		if err != nil || results[0].State.Revision != 2 || results[0].State.Changed || results[1].State.Revision != 2 || !results[1].State.Changed {
			t.Fatalf("recovery replication: %+v %v", results, err)
		}
	default:
		t.Fatal("invalid test phase")
	}
}
