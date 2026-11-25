package provider

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"regexp"
	"strings"
)

type PartitionConfig struct {
	StreamPorts     map[string][]int `json:"stream_ports,omitempty"`
	Name            string           `json:"name"`
	Default         bool             `json:"default,omitempty"`
	Gateways        []string         `json:"gateways,omitempty"`
	Addresses       []string         `json:"addresses"`
	ExtraHTTPPorts  []int            `json:"extra_http_ports,omitempty"`
	ExtraHTTPSPorts []int            `json:"extra_https_ports,omitempty"`
	Targets         []TargetConfig   `json:"targets"`
}
type Partition struct {
	StreamPorts     map[string][]int
	Name            string
	Default         bool
	Gateways        []string
	Addresses       []string
	ExtraHTTPPorts  []int
	ExtraHTTPSPorts []int
	Targets         []Target
}

var partitionName = regexp.MustCompile("^[a-z0-9][a-z0-9-]{0,62}$")
var gatewayName = regexp.MustCompile("^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$")

// Partitions are operator-defined, separate data planes. Unlike targets in
// a replica set, partitions never receive each other's routes.
func ValidateExtraHTTPPorts(ports []int) error {
	if len(ports) > 16 {
		return fmt.Errorf("at most 16 extra HTTP ports")
	}
	seen := map[int]bool{}
	for _, p := range ports {
		if p < 1 || p > 65535 || p == 80 || p == 443 || p == 9443 || seen[p] {
			return fmt.Errorf("invalid or duplicate extra HTTP port")
		}
		seen[p] = true
	}
	return nil
}
func ValidateTransportPorts(ports map[string][]int, http, https []int) error {
	seen := map[int]bool{}
	for _, p := range append(append([]int{}, http...), https...) {
		seen[p] = true
	}
	count := 0
	for protocol, items := range ports {
		if protocol != "tcp" && protocol != "udp" && protocol != "tls" {
			return fmt.Errorf("invalid transport protocol")
		}
		for _, p := range items {
			if p < 1 || p > 65535 || p == 80 || p == 443 || p == 9443 || seen[p] {
				return fmt.Errorf("invalid or conflicting transport port")
			}
			seen[p] = true
			count++
		}
	}
	if count > 16 {
		return fmt.Errorf("too many transport ports")
	}
	return nil
}
func LoadPartitions(path string) ([]Partition, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	d := json.NewDecoder(io.LimitReader(f, 1<<20))
	d.DisallowUnknownFields()
	var configs []PartitionConfig
	if err = d.Decode(&configs); err != nil {
		return nil, fmt.Errorf("invalid partitions: %w", err)
	}
	if d.Decode(new(any)) != io.EOF {
		return nil, fmt.Errorf("unexpected trailing partition configuration")
	}
	if len(configs) < 1 || len(configs) > 16 {
		return nil, fmt.Errorf("expected 1–16 partitions")
	}
	names, gateways, addresses, origins := map[string]bool{}, map[string]bool{}, map[string]bool{}, map[string]string{}
	defaults := 0
	out := []Partition{}
	for _, c := range configs {
		if !partitionName.MatchString(c.Name) || names[c.Name] {
			return nil, fmt.Errorf("invalid or duplicate partition name")
		}
		names[c.Name] = true
		if c.Default {
			defaults++
			if len(c.Gateways) > 0 {
				return nil, fmt.Errorf("default partition must not list explicit Gateways")
			}
		} else if len(c.Gateways) == 0 {
			return nil, fmt.Errorf("partition %s needs Gateway assignments", c.Name)
		}
		for _, g := range c.Gateways {
			parts := strings.Split(g, "/")
			if len(parts) != 2 || !partitionName.MatchString(parts[0]) || !gatewayName.MatchString(parts[1]) || gateways[g] {
				return nil, fmt.Errorf("invalid or duplicate Gateway assignment")
			}
			gateways[g] = true
		}
		if len(c.Addresses) == 0 || len(c.Addresses) > 16 {
			return nil, fmt.Errorf("partition %s needs 1–16 public addresses", c.Name)
		}
		for _, a := range c.Addresses {
			key := strings.ToLower(a)
			if ip := net.ParseIP(a); ip != nil {
				if ip.IsUnspecified() || ip.IsMulticast() {
					return nil, fmt.Errorf("invalid public address")
				}
				key = ip.String()
			} else if !gatewayName.MatchString(a) {
				return nil, fmt.Errorf("invalid public address")
			}
			if addresses[key] {
				return nil, fmt.Errorf("duplicate public address across partitions")
			}
			addresses[key] = true
		}
		if err := ValidateExtraHTTPPorts(append(append([]int{}, c.ExtraHTTPPorts...), c.ExtraHTTPSPorts...)); err != nil {
			return nil, fmt.Errorf("partition %s: %w", c.Name, err)
		}
		if err := ValidateTransportPorts(c.StreamPorts, c.ExtraHTTPPorts, c.ExtraHTTPSPorts); err != nil {
			return nil, err
		}
		targets, err := loadTargetConfigs(c.Targets)
		if err != nil {
			return nil, fmt.Errorf("partition %s: %w", c.Name, err)
		}
		for _, t := range targets {
			endpoint := t.Client.(*Client).endpoint
			origin := strings.SplitN(endpoint, "/api/v1/providers/", 2)[0]
			if prior := origins[origin]; prior != "" && prior != c.Name {
				return nil, fmt.Errorf("appliance management origin shared across partitions")
			}
			origins[origin] = c.Name
		}
		out = append(out, Partition{Name: c.Name, Default: c.Default, Gateways: c.Gateways, Addresses: c.Addresses, ExtraHTTPPorts: c.ExtraHTTPPorts, ExtraHTTPSPorts: c.ExtraHTTPSPorts, StreamPorts: c.StreamPorts, Targets: targets})
	}
	if defaults != 1 {
		return nil, fmt.Errorf("exactly one default partition required")
	}
	return out, nil
}
