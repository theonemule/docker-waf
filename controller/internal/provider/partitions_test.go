package provider

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestPartitionAssignmentsAndValidation(t *testing.T) {
	// System roots are accepted by the client; the fixture uses an existing
	// PEM from the test container's root bundle to exercise strict config loading.
	ca := "/etc/ssl/certs/ca-certificates.crt"
	if _, err := os.Stat(ca); err != nil {
		t.Skip("system CA bundle unavailable")
	}
	target := func(name, url string) []TargetConfig {
		return []TargetConfig{{Name: name, URL: url, ProviderID: name, TokenFile: "/credentials/token", CAFile: ca}}
	}
	base := func() []PartitionConfig {
		return []PartitionConfig{
			{Name: "blue", Default: true, Addresses: []string{"192.0.2.10"}, Targets: target("blue", "https://blue.example.test")},
			{Name: "green", Gateways: []string{"apps/green"}, Addresses: []string{"192.0.2.11"}, Targets: target("green", "https://green.example.test")},
		}
	}
	path := filepath.Join(t.TempDir(), "partitions.json")
	load := func(config []PartitionConfig) ([]Partition, error) {
		raw, _ := json.Marshal(config)
		if err := os.WriteFile(path, raw, 0600); err != nil {
			t.Fatal(err)
		}
		return LoadPartitions(path)
	}
	if p, err := load(base()); err != nil || len(p) != 2 || !p[0].Default || p[1].Gateways[0] != "apps/green" {
		t.Fatalf("valid partitions rejected: %+v %v", p, err)
	}
	cases := []func([]PartitionConfig){
		func(c []PartitionConfig) { c[0].Default = false },
		func(c []PartitionConfig) { c[1].Default = true },
		func(c []PartitionConfig) { c[0].Gateways = []string{"apps/blue"} },
		func(c []PartitionConfig) { c[1].Addresses = c[0].Addresses },
		func(c []PartitionConfig) { c[1].Targets[0].URL = c[0].Targets[0].URL },
		func(c []PartitionConfig) { c[1].Gateways = []string{"invalid"} },
		func(c []PartitionConfig) { c[1].ExtraHTTPPorts = []int{9443} },
		func(c []PartitionConfig) { c[1].ExtraHTTPPorts = []int{8080, 8080} },
		func(c []PartitionConfig) { c[1].ExtraHTTPPorts = []int{443} },
	}
	for i, change := range cases {
		c := base()
		change(c)
		if _, err := load(c); err == nil {
			t.Errorf("bad partition configuration %d accepted", i)
		}
	}
}
