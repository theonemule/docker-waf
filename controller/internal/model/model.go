package model

import (
	"fmt"
	"reflect"
	"sort"
)

type Backend struct {
	Target string `json:"target"`
	Weight int32  `json:"weight"`
}
type TLS struct {
	Certificate string `json:"certificate"`
	PrivateKey  string `json:"private_key"`
}
type HealthCheck struct {
	Enabled  bool   `json:"enabled"`
	Path     string `json:"path,omitempty"`
	Interval int    `json:"interval,omitempty"`
	Timeout  int    `json:"timeout,omitempty"`
	Expected string `json:"expected,omitempty"`
}
type HeaderOperation struct {
	Op    string `json:"op"`
	Name  string `json:"name"`
	Value string `json:"value,omitempty"`
}
type HeaderMatch struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}
type PathModifier struct {
	Type  string `json:"type"`
	Value string `json:"value"`
}
type Rewrite struct {
	Hostname string        `json:"hostname,omitempty"`
	Path     *PathModifier `json:"path,omitempty"`
}
type Redirect struct {
	Hostname   string        `json:"hostname,omitempty"`
	Scheme     string        `json:"scheme,omitempty"`
	Port       int32         `json:"port,omitempty"`
	StatusCode int           `json:"status_code,omitempty"`
	Path       *PathModifier `json:"path,omitempty"`
}

// Origin is controller-local provenance. It is never serialized to the appliance.
type Origin struct {
	Kind     string
	Key      string
	Gateway  string
	Listener string
}
type Mirror struct {
	Target      string `json:"target"`
	BasisPoints int    `json:"basis_points"`
}
type Deadlines struct {
	RequestMS *int `json:"request_ms,omitempty"`
	BackendMS *int `json:"backend_ms,omitempty"`
}
type Retry struct {
	Attempts  int   `json:"attempts"`
	Codes     []int `json:"codes,omitempty"`
	BudgetMS  int   `json:"budget_ms,omitempty"`
	BackoffMS int   `json:"backoff_ms,omitempty"`
}
type BackendTLS struct {
	Hostname      string `json:"hostname"`
	CACertificate string `json:"ca_certificate"`
}
type Route struct {
	GRPC            bool                   `json:"grpc,omitempty"`
	BackendTLSPeers map[string]*BackendTLS `json:"backend_tls_peers,omitempty"`
	Deadlines       *Deadlines             `json:"deadlines,omitempty"`
	BackendTLS      *BackendTLS            `json:"backend_tls,omitempty"`
	Retry           *Retry                 `json:"retry,omitempty"`
	Mirrors         []Mirror               `json:"mirrors,omitempty"`
	WAFProfileOwner string                 `json:"-"`
	WAFLevelOwner   string                 `json:"-"`
	Origins         []Origin               `json:"-"`
	Quarantined     bool                   `json:"quarantined,omitempty"`
	Rewrite         *Rewrite               `json:"rewrite,omitempty"`
	QueryMatches    []HeaderMatch          `json:"query_matches,omitempty"`
	Redirect        *Redirect              `json:"redirect,omitempty"`
	HeaderMatches   []HeaderMatch          `json:"header_matches,omitempty"`
	Method          string                 `json:"method,omitempty"`
	HostPriority    int                    `json:"host_priority,omitempty"`
	Precedence      int                    `json:"precedence,omitempty"`
	Match           string                 `json:"match"`
	Path            string                 `json:"path"`
	ResponseHeaders []HeaderOperation      `json:"response_headers,omitempty"`
	RequestHeaders  []HeaderOperation      `json:"request_headers,omitempty"`
	Backends        []Backend              `json:"backends,omitempty"`
	Schemes         []string               `json:"schemes,omitempty"`
	WAFProfile      string                 `json:"waf_profile,omitempty"`
	WAFPL           int                    `json:"waf_pl,omitempty"`
	RateCount       int                    `json:"rate_count,omitempty"`
	MaxBody         string                 `json:"max_body,omitempty"`
	AllowIPs        []string               `json:"allow_ips,omitempty"`
	Health          *HealthCheck           `json:"health,omitempty"`
}
type Site struct {
	Origins        []Origin        `json:"-"`
	Host           string          `json:"host"`
	WildcardSingle bool            `json:"wildcard_single,omitempty"`
	Listeners      []string        `json:"listeners,omitempty"`
	Routes         []Route         `json:"routes"`
	TLS            *TLS            `json:"tls,omitempty"`
	TLSReject      bool            `json:"tls_reject,omitempty"`
	TLSListeners   map[string]*TLS `json:"tls_listeners,omitempty"`
}
type StreamRoute struct {
	Protocol string    `json:"protocol"`
	Port     int       `json:"port"`
	Hostname string    `json:"hostname,omitempty"`
	Backends []Backend `json:"backends"`
	Origins  []Origin  `json:"-"`
}
type Snapshot struct {
	Streams  []StreamRoute `json:"streams,omitempty"`
	Revision int64         `json:"revision"`
	Sites    []Site        `json:"sites"`
}
type Plan struct {
	sites   map[string]*Site
	streams []StreamRoute
}

func NewPlan() *Plan { return &Plan{sites: map[string]*Site{}} }

// Clone makes an independent candidate for resource-level reconciliation.
// Routes are immutable after Add; copy their slice headers and backing arrays
// that Add/Reserve may replace or reorder.
func (p *Plan) Clone() *Plan {
	out := NewPlan()
	out.streams = append([]StreamRoute(nil), p.streams...)
	for h, s := range p.sites {
		copySite := *s
		copySite.Origins = append([]Origin(nil), s.Origins...)
		copySite.Listeners = append([]string(nil), s.Listeners...)
		copySite.Routes = append([]Route{}, s.Routes...)
		if s.TLSListeners != nil {
			copySite.TLSListeners = map[string]*TLS{}
			for k, v := range s.TLSListeners {
				copySite.TLSListeners[k] = v
			}
		}
		out.sites[h] = &copySite
	}
	return out
}

func (p *Plan) site(host string) *Site {
	if p.sites[host] == nil {
		p.sites[host] = &Site{Host: host, Routes: []Route{}}
	}
	return p.sites[host]
}
func MergeOrigins(a, b []Origin) []Origin {
	out := append([]Origin(nil), a...)
	for _, o := range b {
		found := false
		for _, v := range out {
			if o == v {
				found = true
				break
			}
		}
		if !found {
			out = append(out, o)
		}
	}
	return out
}
func (p *Plan) AddOrigins(host string, origins ...Origin) {
	s := p.site(host)
	s.Origins = MergeOrigins(s.Origins, origins)
}
func (p *Plan) SingleWildcard(host string) { p.site(host).WildcardSingle = true }
func (p *Plan) Reserve(host, scheme string) {
	s := p.site(host)
	for _, existing := range s.Listeners {
		if existing == scheme {
			return
		}
	}
	s.Listeners = append(s.Listeners, scheme)
	sort.Strings(s.Listeners)
}
func (p *Plan) RejectTLS(host string) error { return p.RejectListenerTLS(host, "https") }
func (p *Plan) RejectListenerTLS(host, listener string) error {
	s := p.site(host)
	if listener == "https" && s.TLS != nil || listener != "https" && s.TLSListeners[listener] != nil {
		return fmt.Errorf("conflicting TLS reservation for %s/%s", host, listener)
	}
	for _, r := range s.Routes {
		for _, scheme := range r.Schemes {
			if scheme == listener {
				return fmt.Errorf("conflicting HTTPS route for %s/%s", host, listener)
			}
		}
	}
	if listener == "https" {
		s.TLSReject = true
	} else {
		if s.TLSListeners == nil {
			s.TLSListeners = map[string]*TLS{}
		}
		s.TLSListeners[listener] = nil
	}
	p.Reserve(host, listener)
	return nil
}
func (p *Plan) SetTLS(host string, tls *TLS) error { return p.SetListenerTLS(host, "https", tls) }
func (p *Plan) SetListenerTLS(host, listener string, tls *TLS) error {
	s := p.site(host)
	if listener == "https" {
		if s.TLSReject || s.TLS != nil && !reflect.DeepEqual(s.TLS, tls) {
			return fmt.Errorf("conflicting TLS for %s/%s", host, listener)
		}
		s.TLS = tls
	} else {
		if old, ok := s.TLSListeners[listener]; ok && (old == nil || !reflect.DeepEqual(old, tls)) {
			return fmt.Errorf("conflicting TLS for %s/%s", host, listener)
		}
		if s.TLSListeners == nil {
			s.TLSListeners = map[string]*TLS{}
		}
		s.TLSListeners[listener] = tls
	}
	return nil
}
func (p *Plan) Add(host string, r Route) error          { return p.add(host, r, true) }
func (p *Plan) AddInherited(host string, r Route) error { return p.add(host, r, false) }
func (p *Plan) add(host string, r Route, register bool) error {
	s := p.site(host)
	if register {
		p.AddOrigins(host, r.Origins...)
	}
	sort.Slice(r.Backends, func(i, j int) bool { return r.Backends[i].Target < r.Backends[j].Target })
	if len(r.Schemes) == 0 {
		r.Schemes = []string{"http", "https"}
	}
	sort.Strings(r.Schemes)
	for _, scheme := range r.Schemes {
		value, has := s.TLSListeners[scheme]
		if scheme == "https" && s.TLSReject || has && value == nil {
			return fmt.Errorf("HTTPS rejected for %s", host)
		}
		p.Reserve(host, scheme)
	}
	sort.Strings(r.AllowIPs)
	sort.Slice(r.QueryMatches, func(i, j int) bool { return r.QueryMatches[i].Name < r.QueryMatches[j].Name })
	sort.Slice(r.HeaderMatches, func(i, j int) bool { return r.HeaderMatches[i].Name < r.HeaderMatches[j].Name })
	sort.Slice(r.ResponseHeaders, func(i, j int) bool { return r.ResponseHeaders[i].Name < r.ResponseHeaders[j].Name })
	sort.Slice(r.RequestHeaders, func(i, j int) bool { return r.RequestHeaders[i].Name < r.RequestHeaders[j].Name })
	// Reconcile overlap per scheme; do not discard a non-overlapping listener
	// when another listener has an older route with the same predicate.
	remaining := append([]string(nil), r.Schemes...)
	out := make([]Route, 0, len(s.Routes)+1)
	for _, old := range s.Routes {
		if old.Match != r.Match || old.Path != r.Path || old.Method != r.Method || !reflect.DeepEqual(old.HeaderMatches, r.HeaderMatches) || !reflect.DeepEqual(old.QueryMatches, r.QueryMatches) {
			out = append(out, old)
			continue
		}
		a, b := old, r
		a.Schemes = nil
		b.Schemes = nil
		a.Origins = nil
		b.Origins = nil
		if reflect.DeepEqual(a, b) {
			r.Origins = MergeOrigins(r.Origins, old.Origins)
			set := map[string]bool{}
			for _, scheme := range old.Schemes {
				set[scheme] = true
			}
			for _, scheme := range remaining {
				set[scheme] = true
			}
			remaining = nil
			for scheme := range set {
				remaining = append(remaining, scheme)
			}
			sort.Strings(remaining)
			continue
		}
		oldRemaining := append([]string(nil), old.Schemes...)
		for _, x := range old.Schemes {
			for j, y := range remaining {
				if x != y {
					continue
				}
				if old.Precedence <= 0 || r.Precedence <= 0 {
					return fmt.Errorf("conflicting route for %s %s %s on %s", host, r.Match, r.Path, x)
				}
				if old.HostPriority > r.HostPriority || old.HostPriority == r.HostPriority && old.Precedence <= r.Precedence {
					remaining = append(remaining[:j], remaining[j+1:]...)
				} else {
					for k, z := range oldRemaining {
						if z == x {
							oldRemaining = append(oldRemaining[:k], oldRemaining[k+1:]...)
							break
						}
					}
				}
				break
			}
		}
		if len(oldRemaining) > 0 {
			old.Schemes = oldRemaining
			out = append(out, old)
		}
	}
	if len(remaining) > 0 {
		r.Schemes = remaining
		out = append(out, r)
	}
	s.Routes = out
	return nil
}

func (p *Plan) AddStream(r StreamRoute) error {
	for _, old := range p.streams {
		if old.Port == r.Port && old.Protocol == r.Protocol && old.Hostname == r.Hostname {
			return fmt.Errorf("conflicting transport route")
		}
	}
	p.streams = append(p.streams, r)
	return nil
}
func (p *Plan) Snapshot(revision int64) Snapshot {
	out := Snapshot{Revision: revision, Sites: []Site{}, Streams: append([]StreamRoute(nil), p.streams...)}
	sort.Slice(out.Streams, func(i, j int) bool {
		a, b := out.Streams[i], out.Streams[j]
		if a.Port != b.Port {
			return a.Port < b.Port
		}
		if a.Protocol != b.Protocol {
			return a.Protocol < b.Protocol
		}
		return a.Hostname < b.Hostname
	})
	for _, s := range p.sites {
		if len(s.Routes) == 0 && len(s.Listeners) == 0 {
			continue
		}
		sort.Slice(s.Routes, func(i, j int) bool {
			a, b := s.Routes[i], s.Routes[j]
			if a.Path != b.Path {
				return a.Path < b.Path
			}
			if a.Match != b.Match {
				return a.Match < b.Match
			}
			if a.HostPriority != b.HostPriority {
				return a.HostPriority > b.HostPriority
			}
			if a.Precedence != b.Precedence {
				return a.Precedence < b.Precedence
			}
			return a.Schemes[0] < b.Schemes[0]
		})
		out.Sites = append(out.Sites, *s)
	}
	sort.Slice(out.Sites, func(i, j int) bool { return out.Sites[i].Host < out.Sites[j].Host })
	return out
}
