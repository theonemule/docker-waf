package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"sync"

	"github.com/theonemule/docker-waf/controller/internal/model"
)

type TargetConfig struct {
	Name       string `json:"name"`
	URL        string `json:"url"`
	ProviderID string `json:"provider_id"`
	TokenFile  string `json:"token_file"`
	CAFile     string `json:"ca_file"`
}
type Appliance interface {
	Get(context.Context) (State, error)
	Apply(context.Context, model.Snapshot) (State, error)
}
type Target struct {
	Name   string
	Client Appliance
}
type TargetResult struct {
	Name  string
	State State
	Err   error
}

// LoadTargets is an administrator-owned configuration file. Secrets are read
// from distinct mounted files, not stored in the JSON or Kubernetes routes.
func LoadTargets(path string) ([]Target, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	d := json.NewDecoder(io.LimitReader(f, 1<<20))
	d.DisallowUnknownFields()
	var configs []TargetConfig
	if err := d.Decode(&configs); err != nil {
		return nil, fmt.Errorf("invalid target configuration: %w", err)
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return nil, fmt.Errorf("unexpected trailing target configuration")
	}
	return loadTargetConfigs(configs)
}

func loadTargetConfigs(configs []TargetConfig) ([]Target, error) {
	if len(configs) < 1 || len(configs) > 16 {
		return nil, fmt.Errorf("expected 1–16 appliance targets")
	}
	seen := map[string]bool{}
	origins := map[string]bool{}
	out := []Target{}
	for _, c := range configs {
		if !regexp.MustCompile("^[a-z0-9][a-z0-9-]{0,62}$").MatchString(c.Name) || seen[c.Name] || c.TokenFile == "" || c.CAFile == "" {
			return nil, fmt.Errorf("invalid or duplicate target name or missing credential paths")
		}
		client, err := New(c.URL, c.ProviderID, c.TokenFile, c.CAFile)
		if err != nil {
			return nil, fmt.Errorf("target %s: %w", c.Name, err)
		}
		if origins[client.endpoint] {
			return nil, fmt.Errorf("duplicate appliance/provider target")
		}
		origins[client.endpoint] = true
		seen[c.Name] = true
		out = append(out, Target{Name: c.Name, Client: client})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// Replicate applies a complete authoritative snapshot independently to every
// target. A failed appliance cannot prevent a healthy one from converging.
// This is deliberately not a distributed transaction or traffic failover.
func Replicate(ctx context.Context, targets []Target, snapshot model.Snapshot) ([]TargetResult, error) {
	results := make([]TargetResult, len(targets))
	var wg sync.WaitGroup
	for i, target := range targets {
		wg.Add(1)
		go func(i int, t Target) {
			defer wg.Done()
			result := TargetResult{Name: t.Name}
			state, err := t.Client.Get(ctx)
			if err == nil {
				desired := snapshot
				desired.Revision = state.Revision
				result.State, err = t.Client.Apply(ctx, desired)
			}
			if err != nil {
				result.Err = fmt.Errorf("target %s: %w", t.Name, err)
			}
			results[i] = result
		}(i, target)
	}
	wg.Wait()
	var errs []error
	for _, r := range results {
		if r.Err != nil {
			errs = append(errs, r.Err)
		}
	}
	return results, errors.Join(errs...)
}
