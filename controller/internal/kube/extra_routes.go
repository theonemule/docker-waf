package kube

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"regexp"
	"sort"
	"strings"

	"github.com/theonemule/docker-waf/controller/internal/model"
	core "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	gw "sigs.k8s.io/gateway-api/apis/v1"
	beta "sigs.k8s.io/gateway-api/apis/v1beta1"
)

var grpcRouteGVR = schema.GroupVersionResource{Group: gatewayGroup, Version: "v1", Resource: "grpcroutes"}
var tcpRouteGVR = schema.GroupVersionResource{Group: gatewayGroup, Version: "v1alpha2", Resource: "tcproutes"}
var udpRouteGVR = schema.GroupVersionResource{Group: gatewayGroup, Version: "v1alpha2", Resource: "udproutes"}
var tlsRouteGVR = schema.GroupVersionResource{Group: gatewayGroup, Version: "v1alpha2", Resource: "tlsroutes"}

type ExtraBackend struct {
	gw.BackendRef `json:",inline"`
	Filters       []gw.GRPCRouteFilter `json:"filters,omitempty"`
}
type ExtraRule struct {
	Matches            []gw.GRPCRouteMatch    `json:"matches,omitempty"`
	Filters            []gw.GRPCRouteFilter   `json:"filters,omitempty"`
	BackendRefs        []ExtraBackend         `json:"backendRefs,omitempty"`
	SessionPersistence *gw.SessionPersistence `json:"sessionPersistence,omitempty"`
}
type ExtraRoute struct {
	meta.TypeMeta   `json:",inline"`
	meta.ObjectMeta `json:"metadata,omitempty"`
	Spec            struct {
		gw.CommonRouteSpec `json:",inline"`
		Hostnames          []gw.Hostname `json:"hostnames,omitempty"`
		Rules              []ExtraRule   `json:"rules,omitempty"`
	} `json:"spec"`
	Status gw.RouteStatus              `json:"status,omitempty"`
	GVR    schema.GroupVersionResource `json:"-"`
}
type ExtraParent struct {
	Route                     ExtraRoute
	Parent                    gw.ParentReference
	RejectedReason, RefReason string
}

func (r Reader) listExtraRoutes(ctx context.Context) ([]ExtraRoute, error) {
	out := []ExtraRoute{}
	for _, x := range []struct {
		gvr     schema.GroupVersionResource
		kind    string
		enabled bool
	}{
		{grpcRouteGVR, "GRPCRoute", r.Config.GRPC},
		{tcpRouteGVR, "TCPRoute", len(r.Config.StreamPorts["tcp"]) > 0},
		{udpRouteGVR, "UDPRoute", len(r.Config.StreamPorts["udp"]) > 0},
		{tlsRouteGVR, "TLSRoute", len(r.Config.StreamPorts["tls"]) > 0},
	} {
		if !x.enabled {
			continue
		}
		rows, err := list[ExtraRoute](ctx, r.Client, x.gvr)
		if apierrors.IsNotFound(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			row.Kind = x.kind
			row.GVR = x.gvr
			out = append(out, row)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if !a.CreationTimestamp.Equal(&b.CreationTimestamp) {
			return a.CreationTimestamp.Before(&b.CreationTimestamp)
		}
		return a.Namespace+"/"+a.Name+"/"+a.Kind < b.Namespace+"/"+b.Name+"/"+b.Kind
	})
	return out, nil
}
func extraKey(r ExtraRoute) string { return r.Kind + "/" + r.Namespace + "/" + r.Name }
func extraHosts(l gw.Listener, route ExtraRoute) []string {
	h := string(ptr(l.Hostname, gw.Hostname("*")))
	if len(route.Spec.Hostnames) == 0 {
		return []string{h}
	}
	seen := map[string]bool{}
	out := []string{}
	for _, v := range route.Spec.Hostnames {
		if x, ok := intersectHost(h, string(v)); ok && !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	return out
}
func (r Reader) extraBackend(ctx context.Context, route ExtraRoute, b ExtraBackend, grants []beta.ReferenceGrant) ([]string, string, error) {
	ref := b.BackendObjectReference
	ns := string(ptr(ref.Namespace, gw.Namespace(route.Namespace)))
	if ptr(ref.Group, gw.Group("")) != "" || ptr(ref.Kind, gw.Kind("Service")) != "Service" {
		return []string{"invalid"}, "InvalidKind", nil
	}
	if !permitted(grants, route.Namespace, route.Kind, ns, "Service", string(ref.Name)) {
		return []string{"invalid"}, "RefNotPermitted", nil
	}
	if ref.Port == nil {
		return []string{"invalid"}, "BackendNotFound", nil
	}
	protocol, scheme := core.ProtocolTCP, "tcp"
	if route.Kind == "UDPRoute" {
		protocol, scheme = core.ProtocolUDP, "udp"
	}
	if route.Kind == "GRPCRoute" {
		scheme = "http"
		// Until GRPCRoute policy ancestor reporting is implemented, conservatively
		// reject any Service with a BackendTLSPolicy, rather than downgrade it.
		if r.backendTLS != nil {
			for _, p := range r.backendTLS.policies {
				if p.Namespace != ns {
					continue
				}
				for _, t := range p.Spec.TargetRefs {
					if t.Group == "" && t.Kind == "Service" && t.Name == ref.Name {
						return []string{"invalid"}, "UnsupportedValue", nil
					}
				}
			}
		}
	}
	targets, err := r.serviceProtocolTargets(ctx, ns, string(ref.Name), int32(*ref.Port), "", protocol, scheme)
	if err != nil {
		var bad invalidBackend
		if errors.As(err, &bad) {
			return []string{"invalid"}, bad.reason, nil
		}
		return nil, "", err
	}
	return targets, "", nil
}
func (r Reader) extraBackends(ctx context.Context, route ExtraRoute, rule ExtraRule, grants []beta.ReferenceGrant) ([]model.Backend, string, error) {
	type group struct {
		targets []string
		weight  int64
	}
	groups := []group{}
	reason := ""
	common := int64(1)
	for _, b := range rule.BackendRefs {
		if len(b.Filters) > 0 {
			return nil, "", invalid("UnsupportedValue", "backend filters unsupported")
		}
		weight := ptr(b.Weight, int32(1))
		if weight < 0 || weight > 1000000 {
			return nil, "", invalid("UnsupportedValue", "backend weight outside limit")
		}
		targets, why, err := r.extraBackend(ctx, route, b, grants)
		if err != nil {
			return nil, "", err
		}
		if reason == "" {
			reason = why
		}
		if weight == 0 {
			continue
		}
		n := int64(len(targets))
		if n < 1 || n > 16 {
			return nil, "", fmt.Errorf("invalid endpoint group")
		}
		common = common / gcd(common, n) * n
		groups = append(groups, group{targets, int64(weight)})
	}
	weights := map[string]int64{}
	for _, g := range groups {
		for _, t := range g.targets {
			weights[t] += g.weight * common / int64(len(g.targets))
		}
	}
	if len(weights) == 0 {
		weights["invalid"] = 1
	}
	if len(weights) > 16 {
		return []model.Backend{{Target: "unavailable", Weight: 1}}, "UnsupportedValue", nil
	}
	divisor, max := int64(0), int64(0)
	for _, w := range weights {
		divisor = gcd(divisor, w)
		if w > max {
			max = w
		}
	}
	if max > 1000000 {
		for k, w := range weights {
			weights[k] = w / divisor
		}
		max /= divisor
	}
	if max > 1000000 {
		return nil, "", invalid("UnsupportedValue", "expanded backend weights exceed appliance limit")
	}
	out := []model.Backend{}
	for k, w := range weights {
		out = append(out, model.Backend{Target: k, Weight: int32(w)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Target < out[j].Target })
	return out, reason, nil
}
func grpcHeaderOps(f *gw.HTTPHeaderFilter, response bool) ([]model.HeaderOperation, error) {
	if f == nil {
		return nil, invalid("UnsupportedValue", "missing gRPC header modifier")
	}
	out := []model.HeaderOperation{}
	for _, h := range f.Set {
		out = append(out, model.HeaderOperation{Op: "set", Name: strings.ToLower(string(h.Name)), Value: h.Value})
	}
	for _, h := range f.Add {
		out = append(out, model.HeaderOperation{Op: "add", Name: strings.ToLower(string(h.Name)), Value: h.Value})
	}
	for _, h := range f.Remove {
		out = append(out, model.HeaderOperation{Op: "remove", Name: strings.ToLower(h)})
	}
	seen := map[string]bool{}
	for _, h := range out {
		if !safeHeaderOp(h) || seen[h.Name] {
			return nil, invalid("UnsupportedValue", "unsupported gRPC header operation")
		}
		if response {
			switch h.Name {
			case "x-content-type-options", "x-frame-options", "x-powered-by", "x-xss-protection", "x-webkit-csp", "x-content-security-policy":
				return nil, invalid("UnsupportedValue", "protected response header")
			}
		}
		seen[h.Name] = true
	}
	if len(out) > 20 {
		return nil, invalid("UnsupportedValue", "too many header operations")
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}

var grpcService = regexp.MustCompile(`^\.?[A-Za-z_][A-Za-z_0-9]*(\.[A-Za-z_][A-Za-z_0-9]*)*$`)
var grpcMethod = regexp.MustCompile(`^[A-Za-z_][A-Za-z_0-9]*$`)

func (r Reader) grpcRules(ctx context.Context, p *model.Plan, route ExtraRoute, hosts []string, scheme string, grants []beta.ReferenceGrant, policy Policy, priority int, origin model.Origin) (string, error) {
	reason := ""
	for index, rule := range route.Spec.Rules {
		if rule.SessionPersistence != nil {
			return "", invalid("UnsupportedValue", "gRPC persistence unsupported")
		}
		var req, res []model.HeaderOperation
		seen := map[gw.GRPCRouteFilterType]bool{}
		for _, f := range rule.Filters {
			if seen[f.Type] {
				return "", invalid("UnsupportedValue", "duplicate gRPC filter")
			}
			seen[f.Type] = true
			var err error
			switch f.Type {
			case gw.GRPCRouteFilterRequestHeaderModifier:
				req, err = grpcHeaderOps(f.RequestHeaderModifier, false)
			case gw.GRPCRouteFilterResponseHeaderModifier:
				res, err = grpcHeaderOps(f.ResponseHeaderModifier, true)
			default:
				return "", invalid("UnsupportedValue", "unsupported gRPC filter")
			}
			if err != nil {
				return "", err
			}
		}
		backends, why, err := r.extraBackends(ctx, route, rule, grants)
		if err != nil {
			return "", err
		}
		if reason == "" {
			reason = why
		}
		matches := rule.Matches
		if len(matches) == 0 {
			matches = []gw.GRPCRouteMatch{{}}
		}
		for _, m := range matches {
			match, path := "prefix", "/"
			if m.Method != nil {
				service, method := ptr(m.Method.Service, ""), ptr(m.Method.Method, "")
				if ptr(m.Method.Type, gw.GRPCMethodMatchExact) != gw.GRPCMethodMatchExact || !grpcService.MatchString(service) || method != "" && !grpcMethod.MatchString(method) {
					return "", invalid("UnsupportedValue", "gRPC requires exact service, optional exact method")
				}
				path = "/" + service
				if method != "" {
					match = "exact"
					path += "/" + method
				}
			}
			if !safePath(path) {
				return "", invalid("UnsupportedValue", "invalid gRPC path")
			}
			headers := []model.HeaderMatch{}
			names := map[string]bool{}
			for _, h := range m.Headers {
				n := strings.ToLower(string(h.Name))
				if names[n] {
					continue
				}
				if ptr(h.Type, gw.GRPCHeaderMatchExact) != gw.GRPCHeaderMatchExact || !safeHeaderName.MatchString(n) || !safeHeaderValue.MatchString(h.Value) {
					return "", invalid("UnsupportedValue", "unsupported gRPC header match")
				}
				headers = append(headers, model.HeaderMatch{Name: n, Value: h.Value})
				names[n] = true
			}
			sort.Slice(headers, func(i, j int) bool { return headers[i].Name < headers[j].Name })
			if len(headers) == 0 {
				headers = nil
			}
			for _, h := range hosts {
				hp := 0
				for _, v := range route.Spec.Hostnames {
					if x, ok := intersectHost(string(v), h); ok && x == h && hostSpecificity(string(v)) > hp {
						hp = hostSpecificity(string(v))
					}
				}
				x := policy.apply(model.Route{GRPC: true, Method: "POST", Origins: []model.Origin{origin}, Match: match, Path: path, HeaderMatches: headers, RequestHeaders: req, ResponseHeaders: res, Backends: backends, Schemes: []string{scheme}, HostPriority: hp, Precedence: priority + index})
				if err := p.Add(h, x); err != nil {
					return "", invalid("Conflicted", "gRPC route conflict")
				}
			}
		}
	}
	return reason, nil
}
func (r Reader) extraRoutes(ctx context.Context, inv *Inventory, byName map[string]gw.Gateway, listeners map[string]*listenerPlan, grants []beta.ReferenceGrant, claims map[string]string, ingress []model.Site, policies map[string]Policy) error {
	routes, err := r.listExtraRoutes(ctx)
	if err != nil {
		return err
	}
	inv.ExtraRoutes = routes
	httpClaims := map[string]string{}
	for k, v := range claims {
		httpClaims[k] = v
	}
	streamOwner := map[string]string{}
	// A rejected TLS listener must not expose its names through a broader
	// valid listener on the same Gateway/socket. Withdraw that socket.
	blockedTLS := map[string]bool{}
	for _, g := range inv.Gateways {
		for _, l := range g.Spec.Listeners {
			if l.Protocol == gw.TLSProtocolType && inv.ListenerErrors[listenerKey(g, l)].Reason != "" {
				blockedTLS[fmt.Sprintf("%s/%s:%d", g.Namespace, g.Name, l.Port)] = true
			}
		}
	}
	// Reserve exclusive transport port ownership by Gateway, independently
	// of route creation order. A different Gateway may not share the port.
	keys := []string{}
	for k := range listeners {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		lp := listeners[k]
		l := lp.listener
		if !r.streamListener(l) {
			continue
		}
		owner := lp.gateway.Namespace + "/" + lp.gateway.Name
		port := fmt.Sprintf("%s:%d", l.Protocol, l.Port)
		if l.Protocol == gw.TLSProtocolType && blockedTLS[fmt.Sprintf("%s:%d", owner, l.Port)] {
			inv.ListenerErrors[k] = ListenerFailure{Reason: "Conflicted"}
			delete(listeners, k)
			continue
		}
		if prior := streamOwner[port]; prior != "" && prior != owner {
			inv.ListenerErrors[k] = ListenerFailure{Reason: "Conflicted"}
			delete(listeners, k)
		} else {
			streamOwner[port] = owner
		}
	}
	for index, route := range routes {
		for _, parent := range route.Spec.ParentRefs {
			if ptr(parent.Group, gw.Group(gatewayGroup)) != gw.Group(gatewayGroup) || ptr(parent.Kind, gw.Kind("Gateway")) != "Gateway" {
				continue
			}
			key := string(ptr(parent.Namespace, gw.Namespace(route.Namespace))) + "/" + string(parent.Name)
			g, ok := byName[key]
			if !ok {
				continue
			}
			status := ExtraParent{Route: route, Parent: parent, RejectedReason: "NoMatchingParent"}
			accepted, denied, matched := false, false, false
			for _, l := range g.Spec.Listeners {
				if parent.SectionName != nil && *parent.SectionName != l.Name || parent.Port != nil && *parent.Port != l.Port || !r.kindAllowed(l, route.Kind) {
					continue
				}
				matched = true
				allowed, err := r.namespaceAllowedKind(ctx, l, g.Namespace, route.Namespace, route.Kind)
				if err != nil {
					return err
				}
				if !allowed {
					denied = true
					continue
				}
				inv.Attachments = append(inv.Attachments, Attachment{Gateway: key, Listener: l.Name, Route: extraKey(route)})
				lp := listeners[listenerKey(g, l)]
				if lp == nil || inv.GatewayPolicyErrors[key] != "" {
					continue
				}
				hosts := []string{""}
				if route.Kind == "GRPCRoute" || route.Kind == "TLSRoute" {
					hosts = nil
					for _, h := range extraHosts(l, route) {
						if selectedListener(g, l, h) {
							hosts = append(hosts, h)
						}
					}
					if len(hosts) == 0 {
						status.RejectedReason = "NoMatchingListenerHostname"
						continue
					}
				}
				origin := model.Origin{Kind: route.Kind, Key: route.Namespace + "/" + route.Name, Gateway: key, Listener: string(l.Name)}
				if route.Kind == "GRPCRoute" {
					collision := false
					for _, h := range hosts {
						if lp.tls != nil && covers(lp.tls, h) != nil {
							if r.Config.GatewayClientValidatedFrontend {
								inv.FrontendCertificateWarnings[listenerKey(g, l)] = true
							} else {
								collision = true
							}
						}
						for c, owner := range claims {
							parts := strings.SplitN(c, "/", 2)
							if parts[0] == lp.scheme {
								if _, ok := intersectHost(parts[1], h); ok && (httpClaims[c] != "" || owner != key) {
									collision = true
								}
							}
						}
						for _, site := range ingress {
							for _, scheme := range site.Listeners {
								if scheme == lp.scheme {
									if _, ok := intersectHost(site.Host, h); ok {
										collision = true
									}
								}
							}
						}
					}
					if collision {
						status.RejectedReason = "Conflicted"
						continue
					}
					policy := policies["Gateway:"+key]
					candidate := lp.plan.Clone()
					why, err := r.grpcRules(ctx, candidate, route, hosts, lp.scheme, grants, policy, 1+index*100, origin)
					if err != nil {
						if reason, ok := rejection(err); ok {
							status.RejectedReason = reason
							continue
						}
						return err
					}
					if status.RefReason == "" {
						status.RefReason = why
					}
					lp.plan = candidate
					for _, h := range hosts {
						claims[lp.scheme+"/"+h] = key
					}
				} else {
					// Native HTTP/WAF policies cannot be enforced on opaque layer-4
					// sessions. Reject such attachments instead of silently weakening them.
					policy := policies["Gateway:"+key]
					if policy.WAFPL != 0 || policy.WAFProfile != "" || policy.RateSpecified || policy.MaxBody != "" || len(policy.AllowIPs) > 0 || policy.Health != nil {
						status.RejectedReason = "UnsupportedValue"
						continue
					}
					if len(route.Spec.Rules) != 1 || len(route.Spec.Rules[0].Matches) > 0 || len(route.Spec.Rules[0].Filters) > 0 || route.Spec.Rules[0].SessionPersistence != nil {
						status.RejectedReason = "UnsupportedValue"
						continue
					}
					backends, why, err := r.extraBackends(ctx, route, route.Spec.Rules[0], grants)
					if err != nil {
						if reason, ok := rejection(err); ok {
							status.RejectedReason = reason
							continue
						}
						return err
					}
					if status.RefReason == "" {
						status.RefReason = why
					}
					candidate := inv.Plan.Clone()
					conflict := false
					for _, h := range hosts {
						x := model.StreamRoute{Protocol: strings.ToLower(string(l.Protocol)), Port: int(l.Port), Hostname: h, Backends: backends, Origins: []model.Origin{origin, {Kind: "Listener", Key: key, Listener: string(l.Name)}}}
						if err := candidate.AddStream(x); err != nil {
							conflict = true
							break
						}
					}
					if conflict {
						status.RejectedReason = "Conflicted"
						continue
					}
					inv.Plan = candidate
				}
				accepted = true
			}
			if accepted {
				status.RejectedReason = ""
			} else if denied && status.RejectedReason == "NoMatchingParent" {
				status.RejectedReason = "NotAllowedByListeners"
			} else if matched && status.RejectedReason == "NoMatchingParent" {
				status.RejectedReason = "NoMatchingParent"
			}
			inv.ExtraParents = append(inv.ExtraParents, status)
		}
	}
	// Reserve every otherwise empty transport listener, including specific
	// TLS hostnames which must not fall through a broader SNI wildcard.
	for _, k := range keys {
		lp := listeners[k]
		if lp == nil || !r.streamListener(lp.listener) {
			continue
		}
		l := lp.listener
		protocol := strings.ToLower(string(l.Protocol))
		host := ""
		if l.Protocol == gw.TLSProtocolType {
			host = string(ptr(l.Hostname, gw.Hostname("*")))
		}
		found := false
		for _, x := range inv.Plan.Snapshot(0).Streams {
			if x.Port == int(l.Port) && x.Protocol == protocol && x.Hostname == host {
				found = true
				break
			}
		}
		// For TLS, reserve explicit named listeners only; no catch-all permission
		// is inferred merely from declaring a hostname-less Gateway listener.
		if !found && !(protocol == "tls" && host == "*") {
			_ = inv.Plan.AddStream(model.StreamRoute{Protocol: protocol, Port: int(l.Port), Hostname: host, Backends: []model.Backend{{Target: "invalid", Weight: 1}}, Origins: []model.Origin{{Kind: "Listener", Key: lp.gateway.Namespace + "/" + lp.gateway.Name, Listener: string(l.Name)}}})
		}
	}

	// If all listeners are conflicted/invalid the Gateway itself isn't usable.
	for _, g := range inv.Gateways {
		good := false
		for _, l := range g.Spec.Listeners {
			if listeners[listenerKey(g, l)] != nil {
				good = true
				break
			}
		}
		if !good {
			inv.GatewayErrors[g.Namespace+"/"+g.Name] = "ListenersNotValid"
		}
	}
	return nil
}

func (r Reader) reportExtraRoutes(ctx context.Context, inv Inventory, valid, applied bool) error {
	selected := map[string][]ExtraParent{}
	routes := map[string]ExtraRoute{}
	for _, p := range inv.ExtraParents {
		k := extraKey(p.Route)
		selected[k] = append(selected[k], p)
		routes[k] = p.Route
	}
	if valid && applied {
		for _, route := range inv.ExtraRoutes {
			for _, p := range route.Status.Parents {
				if string(p.ControllerName) == r.Config.ControllerName && r.Config.OwnsGateway(string(ptr(p.ParentRef.Namespace, gw.Namespace(route.Namespace)))+"/"+string(p.ParentRef.Name)) {
					routes[extraKey(route)] = route
				}
			}
		}
	}
	var first error
	for key, route := range routes {
		err := updateStatus[ExtraRoute](ctx, r.Client, route.GVR, &route, func(o *ExtraRoute) any {
			out := []gw.RouteParentStatus{}
			for _, p := range o.Status.Parents {
				if string(p.ControllerName) != r.Config.ControllerName || !r.Config.OwnsGateway(string(ptr(p.ParentRef.Namespace, gw.Namespace(o.Namespace)))+"/"+string(p.ParentRef.Name)) {
					out = append(out, p)
				} else if !valid {
					found := false
					for _, item := range selected[key] {
						if reflect.DeepEqual(item.Parent, p.ParentRef) {
							found = true
							break
						}
					}
					if !found {
						out = append(out, p)
					}
				}
			}
			for _, item := range selected[key] {
				p := gw.RouteParentStatus{ParentRef: item.Parent, ControllerName: gw.GatewayController(r.Config.ControllerName)}
				for _, old := range o.Status.Parents {
					if old.ControllerName == p.ControllerName && reflect.DeepEqual(old.ParentRef, p.ParentRef) {
						p = old
						break
					}
				}
				accept, resolved, program := meta.ConditionTrue, meta.ConditionTrue, meta.ConditionFalse
				ar, rr, pr := "Accepted", "ResolvedRefs", "Pending"
				if !valid {
					accept, resolved = meta.ConditionFalse, meta.ConditionUnknown
					ar, rr = "Pending", "Pending"
				} else {
					if item.RejectedReason != "" {
						accept = meta.ConditionFalse
						ar = item.RejectedReason
					}
					if item.RefReason != "" {
						resolved = meta.ConditionFalse
						rr = item.RefReason
					}
				}
				if applied && accept == meta.ConditionTrue {
					program = meta.ConditionTrue
					pr = "Programmed"
				}
				condition(&p.Conditions, "Accepted", accept, ar, "Route attachment evaluation", o.Generation)
				condition(&p.Conditions, "ResolvedRefs", resolved, rr, "Backend reference evaluation", o.Generation)
				condition(&p.Conditions, "Programmed", program, pr, "LightEdge applied state", o.Generation)
				out = append(out, p)
			}
			sort.SliceStable(out, func(i, j int) bool {
				return fmt.Sprint(out[i].ControllerName, out[i].ParentRef) < fmt.Sprint(out[j].ControllerName, out[j].ParentRef)
			})
			o.Status.Parents = out
			return &o.Status
		})
		if err != nil && first == nil {
			first = err
		}
	}
	return first
}
