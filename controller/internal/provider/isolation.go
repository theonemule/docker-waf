package provider

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/theonemule/docker-waf/controller/internal/model"
)

// Validate is optional for test doubles and legacy standalone callers.
// Production clients implement it; older appliances must be upgraded.
type validator interface {
	Validate(context.Context, model.Snapshot) (State, error)
}
type RejectedResource struct {
	Origins   []model.Origin
	PolicyKey string
	Host      string
	Status    int
	Field     string
	Reason    string
	Site      bool
}

// Quarantine replaces every effective rule of the affected resource with
// the fixed local HTTP 500 backend. Keep the original predicate and priority,
// not a weaker fallback; no forbidden destination or filter reaches NGINX.
// Site-level failure omits an unauthorized hostname, or reserves a valid
// hostname without forwarding (including rejection of HTTPS handshakes).
func quarantine(s model.Snapshot, e *HTTPError) (model.Snapshot, RejectedResource, error) {
	var rejected RejectedResource
	if e.Rejection != nil && e.Rejection.StreamIndex != nil {
		i := *e.Rejection.StreamIndex
		if i < 0 || i >= len(s.Streams) {
			return s, rejected, fmt.Errorf("invalid transport rejection coordinate")
		}
		v := s.Streams[i]
		rejected = RejectedResource{Origins: v.Origins, Status: e.Status, Field: e.Rejection.Field, Reason: e.Rejection.Reason}
		if len(v.Origins) == 0 {
			return s, rejected, fmt.Errorf("unattributed transport rejection")
		}
		// A denied SNI route must not fall through a broader wildcard on the
		// same port. Withdraw that entire port from this provider snapshot.
		out := s
		out.Streams = nil
		for _, route := range s.Streams {
			if route.Protocol == v.Protocol && route.Port == v.Port {
				rejected.Origins = model.MergeOrigins(rejected.Origins, route.Origins)
				continue
			}
			out.Streams = append(out.Streams, route)
		}
		return out, rejected, nil
	}
	if e.Rejection == nil || e.Rejection.SiteIndex == nil {
		return s, rejected, e
	}
	i := *e.Rejection.SiteIndex
	if i < 0 || i >= len(s.Sites) {
		return s, rejected, fmt.Errorf("invalid provider rejection coordinate")
	}
	site := s.Sites[i]
	rejected = RejectedResource{Host: site.Host, Status: e.Status, Field: e.Rejection.Field, Reason: e.Rejection.Reason, Site: e.Rejection.RouteIndex == nil}
	if j := e.Rejection.RouteIndex; j != nil {
		if *j < 0 || *j >= len(site.Routes) {
			return s, rejected, fmt.Errorf("invalid provider route rejection coordinate")
		}
		r := site.Routes[*j]
		if r.Quarantined {
			return s, rejected, fmt.Errorf("quarantine itself was rejected")
		}
		rejected.Origins = r.Origins
		switch e.Rejection.Field {
		case "waf_profile":
			rejected.PolicyKey = r.WAFProfileOwner
		case "waf_pl":
			rejected.PolicyKey = r.WAFLevelOwner
		}
	} else {
		rejected.Origins = site.Origins
	}
	if len(rejected.Origins) == 0 {
		return s, rejected, fmt.Errorf("unattributed provider rejection")
	}
	// A resource is atomic within a parent Gateway. Include every copy of its
	// rules inherited into narrower virtual hosts. Other parent Gateways remain
	// independent. Ingress is atomic across its declared hostnames.
	same := func(a, b model.Origin) bool {
		return a.Kind == b.Kind && a.Key == b.Key && a.Gateway == b.Gateway && (a.Kind != "Listener" || a.Listener == b.Listener)
	}
	affected := func(origins []model.Origin) bool {
		for _, a := range origins {
			for _, b := range rejected.Origins {
				if same(a, b) {
					return true
				}
			}
		}
		return false
	}
	out := model.Snapshot{Revision: s.Revision, Sites: []model.Site{}, Streams: s.Streams}
	for n, original := range s.Sites {
		v := original
		if n == i && rejected.Site {
			if e.Status == 403 || e.Status == 409 {
				// Authorization or ownership may not permit reserving the host at all.
				// Never take ownership from an unrelated provider/manual site.
				continue
			}
			if len(v.Routes) == 0 && v.TLS == nil && len(v.TLSListeners) == 0 {
				return s, rejected, fmt.Errorf("site reservation itself was rejected")
			}
			v.Routes = []model.Route{}
			v.TLS = nil
			v.TLSReject = false
			v.TLSListeners = nil
			for _, scheme := range v.Listeners {
				if scheme == "https" {
					v.TLSReject = true
				} else if strings.HasPrefix(scheme, "https:") {
					if v.TLSListeners == nil {
						v.TLSListeners = map[string]*model.TLS{}
					}
					v.TLSListeners[scheme] = nil
				}
			}
			out.Sites = append(out.Sites, v)
			continue
		}
		v.Routes = append([]model.Route{}, v.Routes...)
		for j, r := range v.Routes {
			if !affected(r.Origins) {
				continue
			}
			// Only matching fields are carried forward. Provider-approved WAF floor
			// and default profile are resolved again during validation.
			v.Routes[j] = model.Route{Origins: r.Origins, Quarantined: true, Match: r.Match, Path: r.Path, HeaderMatches: r.HeaderMatches, QueryMatches: r.QueryMatches, Method: r.Method, HostPriority: r.HostPriority, Precedence: r.Precedence, Schemes: r.Schemes, Backends: []model.Backend{{Target: "invalid", Weight: 1}}}
		}
		out.Sites = append(out.Sites, v)
	}
	return out, rejected, nil
}

// Reconcile validates a common snapshot across all reachable targets before
// applying it. Rejections from any target quarantine the same resource on all
// reachable targets; a transport failure is NOT an authorization failure.
// Preserve each target's exact observed CAS revision until commit.
func Reconcile(ctx context.Context, targets []Target, s model.Snapshot) ([]TargetResult, []RejectedResource, error) {
	results := make([]TargetResult, len(targets))
	revisions := make([]int64, len(targets))
	var wg sync.WaitGroup
	for i, t := range targets {
		wg.Add(1)
		go func(i int, t Target) {
			defer wg.Done()
			results[i].Name = t.Name
			state, err := t.Client.Get(ctx)
			revisions[i] = state.Revision
			results[i].Err = err
		}(i, t)
	}
	wg.Wait()
	rejections := []RejectedResource{}
	// Bound work per reconciliation; never commit an unvalidated partial plan.
	for attempt := 0; attempt <= 100; attempt++ {
		errs := make([]error, len(targets))
		for i, t := range targets {
			if results[i].Err != nil {
				continue
			}
			if v, ok := t.Client.(validator); ok {
				wg.Add(1)
				go func(i int, v validator) {
					defer wg.Done()
					desired := s
					desired.Revision = revisions[i]
					_, errs[i] = v.Validate(ctx, desired)
				}(i, v)
			}
		}
		wg.Wait()
		changed := false
		for i, err := range errs {
			if err == nil {
				continue
			}
			var rejection *HTTPError
			if errors.As(err, &rejection) && rejection.Rejection != nil && (rejection.Status == 400 || rejection.Status == 403 || rejection.Status == 409) {
				if attempt == 100 {
					return results, rejections, fmt.Errorf("resource isolation limit reached")
				}
				next, resource, qerr := quarantine(s, rejection)
				if qerr != nil {
					return results, rejections, qerr
				}
				s = next
				rejections = append(rejections, resource)
				changed = true
				// Remaining coordinates refer to the old snapshot: validate again.
				break
			}
			results[i].Err = err
		}
		if changed {
			continue
		}
		for i, t := range targets {
			if results[i].Err != nil {
				continue
			}
			wg.Add(1)
			go func(i int, t Target) {
				defer wg.Done()
				desired := s
				desired.Revision = revisions[i]
				results[i].State, results[i].Err = t.Client.Apply(ctx, desired)
			}(i, t)
		}
		wg.Wait()
		var failures []error
		for i := range results {
			if results[i].Err != nil {
				results[i].Err = fmt.Errorf("target %s: %w", results[i].Name, results[i].Err)
				failures = append(failures, results[i].Err)
			}
		}
		return results, rejections, errors.Join(failures...)
	}
	return results, rejections, fmt.Errorf("resource isolation limit reached")
}
