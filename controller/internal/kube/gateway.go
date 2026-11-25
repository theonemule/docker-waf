package kube

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/theonemule/docker-waf/controller/internal/model"
	core "k8s.io/api/core/v1"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	gw "sigs.k8s.io/gateway-api/apis/v1"
	beta "sigs.k8s.io/gateway-api/apis/v1beta1"
)

const gatewayGroup = "gateway.networking.k8s.io"

func permitted(grants []beta.ReferenceGrant, fromNS, fromKind, toNS, toKind, name string) bool {
	if fromNS == toNS {
		return true
	}
	for _, g := range grants {
		if g.Namespace != toNS {
			continue
		}
		for _, from := range g.Spec.From {
			if string(from.Group) != gatewayGroup || string(from.Kind) != fromKind || string(from.Namespace) != fromNS {
				continue
			}
			for _, to := range g.Spec.To {
				if string(to.Group) == "" && string(to.Kind) == toKind && (to.Name == nil || string(*to.Name) == name) {
					return true
				}
			}
		}
	}
	return false
}

func (r Reader) namespaceAllowed(ctx context.Context, l gw.Listener, gatewayNS, routeNS string) (bool, error) {
	return r.namespaceAllowedKind(ctx, l, gatewayNS, routeNS, "HTTPRoute")
}
func (r Reader) namespaceAllowedKind(ctx context.Context, l gw.Listener, gatewayNS, routeNS, routeKind string) (bool, error) {
	if l.AllowedRoutes == nil {
		return gatewayNS == routeNS, nil
	}
	if len(l.AllowedRoutes.Kinds) > 0 {
		found := false
		for _, kind := range l.AllowedRoutes.Kinds {
			if ptr(kind.Group, gw.Group(gatewayGroup)) == gw.Group(gatewayGroup) && string(kind.Kind) == routeKind {
				found = true
			}
		}
		if !found {
			return false, nil
		}
	}
	ns := l.AllowedRoutes.Namespaces
	if ns == nil {
		return gatewayNS == routeNS, nil
	}
	switch ptr(ns.From, gw.NamespacesFromSame) {
	case gw.NamespacesFromSame:
		return gatewayNS == routeNS, nil
	case gw.NamespacesFromAll:
		return true, nil
	case gw.NamespacesFromSelector:
		if ns.Selector == nil {
			return false, fmt.Errorf("namespace selector required")
		}
		selector, err := meta.LabelSelectorAsSelector(ns.Selector)
		if err != nil {
			return false, err
		}
		namespace, err := get[core.Namespace](ctx, r.Client, namespaceGVR, "", routeNS)
		if err != nil {
			return false, err
		}
		return selector.Matches(labels.Set(namespace.Labels)), nil
	default:
		return false, nil
	}
}

// Intersection is the narrower of two compatible DNS patterns. "*" is
// the explicit appliance-authorized HTTP catch-all, not an implicit default.
func intersectHost(a, b string) (string, bool) {
	if a == "" || a == "*" {
		return b, true
	}
	if b == "" || b == "*" {
		return a, true
	}
	if a == b {
		return a, true
	}
	aw, bw := strings.HasPrefix(a, "*."), strings.HasPrefix(b, "*.")
	if aw && bw {
		if strings.HasSuffix(a[2:], b[1:]) {
			return a, true
		}
		if strings.HasSuffix(b[2:], a[1:]) {
			return b, true
		}
	} else if aw && strings.HasSuffix(b, a[1:]) {
		return b, true
	} else if bw && strings.HasSuffix(a, b[1:]) {
		return a, true
	}
	return "", false
}
func listenerHosts(l gw.Listener, route gw.HTTPRoute) ([]string, error) {
	listener := string(ptr(l.Hostname, gw.Hostname("*")))
	if len(route.Spec.Hostnames) == 0 {
		return []string{listener}, nil
	}
	hosts := []string{}
	seen := map[string]bool{}
	for _, v := range route.Spec.Hostnames {
		if h, ok := intersectHost(listener, string(v)); ok && !seen[h] {
			hosts = append(hosts, h)
			seen[h] = true
		}
	}
	return hosts, nil
}
func hostSpecificity(h string) int {
	if h == "" || h == "*" {
		return 0
	}
	if strings.HasPrefix(h, "*.") {
		return len(h)
	}
	return 1000 + len(h)
}

// Concrete route hosts may not be installed from a less-specific listener
// when the same hostname would be selected by a more-specific listener.
func selectedListener(g gw.Gateway, l gw.Listener, host string) bool {
	h := string(ptr(l.Hostname, gw.Hostname("*")))
	for _, other := range g.Spec.Listeners {
		if other.Name == l.Name || other.Port != l.Port || other.Protocol != l.Protocol {
			continue
		}
		o := string(ptr(other.Hostname, gw.Hostname("*")))
		if x, ok := intersectHost(o, host); ok && x == host && hostSpecificity(o) > hostSpecificity(h) {
			return false
		}
	}
	return true
}

func validateGateway(g gw.Gateway, addresses []string) error {
	if g.Spec.Infrastructure != nil {
		return invalid("UnsupportedValue", "Gateway infrastructure provisioning unsupported")
	}
	for _, a := range g.Spec.Addresses {
		ok := false
		for _, v := range addresses {
			if a.Value == v {
				ok = true
			}
		}
		if !ok {
			return invalid("AddressNotUsable", "requested Gateway address is not assigned to appliance")
		}
	}
	return nil
}

// Listener keys preserve the standard ports and distinguish pre-provisioned extra sockets.
func listenerScheme(l gw.Listener) string {
	if l.Protocol == gw.HTTPSProtocolType {
		if l.Port == 443 {
			return "https"
		}
		return fmt.Sprintf("https:%d", l.Port)
	}
	if l.Port == 80 {
		return "http"
	}
	return fmt.Sprintf("http:%d", l.Port)
}
func (r Reader) httpPortAllowed(port gw.PortNumber) bool {
	if port == 80 {
		return true
	}
	for _, p := range r.Config.ExtraHTTPPorts {
		if p == int(port) {
			return true
		}
	}
	return false
}
func (r Reader) httpsPortAllowed(port gw.PortNumber) bool {
	if port == 443 {
		return true
	}
	for _, p := range r.Config.ExtraHTTPSPorts {
		if p == int(port) {
			return true
		}
	}
	return false
}
func (r Reader) supportedKinds(l gw.Listener) []string {
	switch l.Protocol {
	case gw.HTTPProtocolType, gw.HTTPSProtocolType:
		if r.Config.GRPC {
			return []string{"HTTPRoute", "GRPCRoute"}
		}
		return []string{"HTTPRoute"}
	case gw.TCPProtocolType:
		return []string{"TCPRoute"}
	case gw.UDPProtocolType:
		return []string{"UDPRoute"}
	case gw.TLSProtocolType:
		return []string{"TLSRoute"}
	}
	return nil
}
func (r Reader) kindAllowed(l gw.Listener, kind string) bool {
	for _, k := range r.supportedKinds(l) {
		if k == kind {
			return true
		}
	}
	return false
}
func (r Reader) streamListener(l gw.Listener) bool {
	return l.Protocol == gw.TCPProtocolType || l.Protocol == gw.UDPProtocolType || l.Protocol == gw.TLSProtocolType
}
func (r Reader) validateListener(l gw.Listener) error {
	switch l.Protocol {
	case gw.HTTPProtocolType:
		if !r.httpPortAllowed(l.Port) || l.TLS != nil {
			return invalid("UnsupportedValue", "HTTP listener requires an operator-provisioned port without TLS")
		}
	case gw.HTTPSProtocolType:
		if !r.httpsPortAllowed(l.Port) || l.TLS == nil || ptr(l.TLS.Mode, gw.TLSModeTerminate) != gw.TLSModeTerminate || len(l.TLS.CertificateRefs) != 1 || len(l.TLS.Options) > 0 {
			return invalid("UnsupportedValue", "HTTPS listener requires an operator-provisioned port and one terminating TLS Secret")
		}

	case gw.TCPProtocolType, gw.UDPProtocolType, gw.TLSProtocolType:
		provisioned := false
		for _, p := range r.Config.StreamPorts[strings.ToLower(string(l.Protocol))] {
			if p == int(l.Port) {
				provisioned = true
			}
		}
		if !provisioned {
			return invalid("UnsupportedValue", "transport listener requires operator-provisioned port")
		}
		if l.Protocol == gw.TLSProtocolType {
			if l.TLS == nil || ptr(l.TLS.Mode, gw.TLSModeTerminate) != gw.TLSModePassthrough || len(l.TLS.CertificateRefs) > 0 || len(l.TLS.Options) > 0 {
				return invalid("UnsupportedValue", "TLS listener requires passthrough without certificates")
			}
		} else if l.TLS != nil || l.Hostname != nil {
			return invalid("UnsupportedValue", "TCP/UDP listener cannot have TLS or hostname")
		}
	default:
		return invalid("UnsupportedProtocol", "unsupported listener protocol %s", l.Protocol)
	}
	if l.AllowedRoutes != nil {
		for _, k := range l.AllowedRoutes.Kinds {
			if ptr(k.Group, gw.Group(gatewayGroup)) != gw.Group(gatewayGroup) || !r.kindAllowed(l, string(k.Kind)) {
				return invalid("InvalidRouteKinds", "unsupported listener route kind")
			}
		}
	}
	return nil
}

var safePathPattern = regexp.MustCompile(`^/[A-Za-z0-9._~/+-]*$`)
var safeHeaderName = regexp.MustCompile(`^[a-z][a-z0-9-]{0,63}$`)
var safeHeaderValue = regexp.MustCompile(`^[A-Za-z0-9_.,:/@+=% -]{1,256}$`)

func safePath(path string) bool {
	if len(path) > 512 || !safePathPattern.MatchString(path) || strings.Contains(path, "//") || (strings.HasPrefix(path, "/.well-known/acme-challenge") || strings.HasPrefix(path, "/.liteedge-internal/mirror/")) {
		return false
	}
	for _, part := range strings.Split(path, "/") {
		if part == "." || part == ".." {
			return false
		}
	}
	return true
}
func safeHeaderOp(h model.HeaderOperation) bool {
	if !strings.HasPrefix(h.Name, "x-") || len(h.Name) < 3 || !safeHeaderName.MatchString(h.Name) {
		return false
	}
	if h.Name == "x-real-ip" {
		return false
	}
	for _, prefix := range []string{"x-liteedge-", "x-forwarded-", "x-original-", "x-auth-", "x-remote-"} {
		if strings.HasPrefix(h.Name, prefix) {
			return false
		}
	}
	return h.Op == "remove" && h.Value == "" || h.Op != "remove" && safeHeaderValue.MatchString(h.Value)
}
func routeHostPriority(route gw.HTTPRoute, host string) int {
	priority := 0
	for _, v := range route.Spec.Hostnames {
		if h, ok := intersectHost(string(v), host); ok && h == host {
			if n := hostSpecificity(string(v)); n > priority {
				priority = n
			}
		}
	}
	return priority
}

func (r Reader) listenerTLS(ctx context.Context, g gw.Gateway, l gw.Listener, grants []beta.ReferenceGrant) (*model.TLS, error) {
	if l.Protocol != gw.HTTPSProtocolType {
		return nil, nil
	}
	ref := l.TLS.CertificateRefs[0]
	ns := string(ptr(ref.Namespace, gw.Namespace(g.Namespace)))
	if ptr(ref.Group, gw.Group("")) != "" || ptr(ref.Kind, gw.Kind("Secret")) != "Secret" {
		return nil, invalid("InvalidCertificateRef", "only Secret certificateRefs supported")
	}
	if !permitted(grants, g.Namespace, "Gateway", ns, "Secret", string(ref.Name)) {
		return nil, invalid("RefNotPermitted", "certificate reference not permitted")
	}
	return r.tls(ctx, ns, string(ref.Name))
}

// Reference resolution is independent of route programming and shared by
// primary and mirror backends. Never access ungranted cross-namespace objects.
func (r Reader) resolveBackend(ctx context.Context, namespace string, b gw.BackendObjectReference, grants []beta.ReferenceGrant) ([]string, string, error) {
	ns := string(ptr(b.Namespace, gw.Namespace(namespace)))
	if ptr(b.Group, gw.Group("")) != "" || ptr(b.Kind, gw.Kind("Service")) != "Service" {
		return []string{"invalid"}, "InvalidKind", nil
	}
	if !permitted(grants, namespace, "HTTPRoute", ns, "Service", string(b.Name)) {
		return []string{"invalid"}, "RefNotPermitted", nil
	}
	if b.Port == nil {
		return []string{"invalid"}, "BackendNotFound", nil
	}
	value, err := r.serviceTargets(ctx, ns, string(b.Name), int32(*b.Port), "")
	if err != nil {
		var bad invalidBackend
		if errors.As(err, &bad) {
			return []string{"invalid"}, bad.reason, nil
		}
		return nil, "", err
	}
	return value, "", nil
}
func (r Reader) routeRefReason(ctx context.Context, route gw.HTTPRoute, grants []beta.ReferenceGrant) (string, error) {
	reason := ""
	check := func(b gw.BackendObjectReference) error {
		_, why, err := r.resolveBackend(ctx, route.Namespace, b, grants)
		if reason == "" {
			reason = why
		}
		return err
	}
	for _, rule := range route.Spec.Rules {
		for _, b := range rule.BackendRefs {
			if err := check(b.BackendObjectReference); err != nil {
				return "", err
			}
		}
		for _, f := range rule.Filters {
			if f.Type == gw.HTTPRouteFilterRequestMirror && f.RequestMirror != nil {
				if err := check(f.RequestMirror.BackendRef); err != nil {
					return "", err
				}
			}
		}
	}
	return reason, nil
}

// Invalid references retain their requested traffic share as HTTP 500.
// Discovery/transport errors still abort the snapshot rather than pruning.
func gcd(a, b int64) int64 {
	for b != 0 {
		a, b = b, a%b
	}
	return a
}
func (r Reader) backends(ctx context.Context, route gw.HTTPRoute, rule gw.HTTPRouteRule, grants []beta.ReferenceGrant) ([]model.Backend, string, error) {
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
			return nil, "", invalid("UnsupportedValue", "invalid backend weight")
		}
		targets, why, err := r.resolveBackend(ctx, route.Namespace, b.BackendObjectReference, grants)
		if err != nil {
			return nil, "", err
		}
		if why != "" && reason == "" {
			reason = why
		}
		if weight == 0 {
			continue
		}
		n := int64(len(targets))
		if n < 1 || n > 16 {
			return nil, "", fmt.Errorf("invalid service endpoint group")
		}
		common = common / gcd(common, n) * n
		groups = append(groups, group{targets, int64(weight)})
	}
	weights := map[string]int64{}
	for _, g := range groups {
		per := g.weight * common / int64(len(g.targets))
		for _, target := range g.targets {
			weights[target] += per
		}
	}
	if len(weights) == 0 {
		weights["invalid"] = 1
	}
	// Avoid silently truncating a large endpoint group or exposing a less
	// specific fallback route. The local unavailable backend holds the match.
	if len(weights) > 16 {
		return []model.Backend{{Target: "unavailable", Weight: 1}}, "UnsupportedValue", nil
	}
	max, divisor := int64(0), int64(0)
	for _, w := range weights {
		if w > max {
			max = w
		}
		divisor = gcd(divisor, w)
	}
	// Preserve configured weights for ordinary Services; normalize expanded
	// endpoint groups to exact ratios whenever they fit the native limits.
	if common == 1 && max > 1000000 {
		return nil, "", invalid("UnsupportedValue", "backend weight exceeds provider limit")
	}
	if max > 1000000 {
		for target, w := range weights {
			weights[target] = w / divisor
		}
		max /= divisor
	}
	if max > 1000000 {
		// Bounded quantization only when the exact ratio exceeds the native
		// integer range; a positive share is never silently removed.
		for target, w := range weights {
			v := int64(float64(w)/float64(max)*1000000 + 0.5)
			if v < 1 {
				v = 1
			}
			weights[target] = v
		}
	}
	out := []model.Backend{}
	for target, w := range weights {
		out = append(out, model.Backend{Target: target, Weight: int32(w)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Target < out[j].Target })
	return out, reason, nil
}

var safeQueryLiteral = regexp.MustCompile(`^[A-Za-z0-9_.~-]{1,256}$`)

func pathModifier(p *gw.HTTPPathModifier) (*model.PathModifier, error) {
	if p == nil {
		return nil, nil
	}
	var value, kind string
	switch p.Type {
	case gw.FullPathHTTPPathModifier:
		kind = "full"
		value = ptr(p.ReplaceFullPath, "")
	case gw.PrefixMatchHTTPPathModifier:
		kind = "prefix"
		value = ptr(p.ReplacePrefixMatch, "")
	default:
		return nil, invalid("UnsupportedValue", "unsupported path modifier")
	}
	if !safePath(value) {
		return nil, invalid("UnsupportedValue", "invalid replacement path")
	}
	return &model.PathModifier{Type: kind, Value: value}, nil
}
func deadlineMS(d *gw.Duration, max int) (*int, error) {
	if d == nil {
		return nil, nil
	}
	v, err := time.ParseDuration(string(*d))
	if err != nil || v < 0 || v > time.Duration(max)*time.Millisecond || v%time.Millisecond != 0 {
		return nil, invalid("UnsupportedValue", "duration outside supported millisecond range")
	}
	ms := int(v / time.Millisecond)
	return &ms, nil
}
func routeDeadlines(t *gw.HTTPRouteTimeouts) (*model.Deadlines, error) {
	if t == nil {
		return nil, nil
	}
	request, err := deadlineMS(t.Request, 3600000)
	if err != nil {
		return nil, err
	}
	backend, err := deadlineMS(t.BackendRequest, 3600000)
	if err != nil {
		return nil, err
	}
	if request == nil && backend == nil {
		return nil, nil
	}
	if request != nil && *request > 0 && backend != nil && *backend > *request {
		return nil, invalid("UnsupportedValue", "backend timeout exceeds request timeout")
	}
	return &model.Deadlines{RequestMS: request, BackendMS: backend}, nil
}
func (r Reader) routeRules(ctx context.Context, p *model.Plan, route gw.HTTPRoute, hosts []string, scheme string, grants []beta.ReferenceGrant, policy Policy, priority int, refReason *string, origin model.Origin) error {
	for ruleIndex, rule := range route.Spec.Rules {
		if rule.SessionPersistence != nil {
			return invalid("UnsupportedValue", "unsupported HTTPRoute persistence")
		}
		deadlines, err := routeDeadlines(rule.Timeouts)
		if err != nil {
			return err
		}
		headers := []model.HeaderOperation{}
		responseHeaders := []model.HeaderOperation{}
		var redirect *model.Redirect
		var rewrite *model.Rewrite
		mirrors := []model.Mirror{}
		mirrorSeen := map[string]bool{}

		for _, filter := range rule.Filters {
			if filter.Type == gw.HTTPRouteFilterRequestMirror {
				f := filter.RequestMirror
				if f == nil || (f.Percent != nil && f.Fraction != nil) {
					return invalid("UnsupportedValue", "invalid request mirror sampling")
				}
				points := 10000
				if f.Percent != nil {
					if *f.Percent < 0 || *f.Percent > 100 {
						return invalid("UnsupportedValue", "invalid mirror percentage")
					}
					points = int(*f.Percent) * 100
				}
				if f.Fraction != nil {
					num, den := int64(f.Fraction.Numerator), int64(ptr(f.Fraction.Denominator, int32(100)))
					if den <= 0 || num < 0 || num > den {
						return invalid("UnsupportedValue", "invalid mirror fraction")
					}
					points = int((num*10000 + den/2) / den)
					if num > 0 && points == 0 {
						points = 1
					}
					if num < den && points == 10000 {
						points = 9999
					}
				}
				selected, err := r.backendTLSFor(ctx, route.Namespace, f.BackendRef, grants)
				if err != nil {
					return err
				}
				if selected.Selected != nil {
					if *refReason == "" {
						*refReason = "UnsupportedValue"
					}
					continue
				}
				targets, reason, err := r.resolveBackend(ctx, route.Namespace, f.BackendRef, grants)
				if err != nil {
					return err
				}
				if reason != "" {
					if *refReason == "" {
						*refReason = reason
					}
					continue
				}
				if points == 0 {
					continue
				}
				if len(targets) != 1 || targets[0] == "unavailable" {
					if *refReason == "" {
						*refReason = "UnsupportedValue"
					}
					continue
				}
				target := targets[0]
				if mirrorSeen[target] {
					return invalid("UnsupportedValue", "duplicate mirror destination")
				}
				mirrors = append(mirrors, model.Mirror{Target: target, BasisPoints: points})
				mirrorSeen[target] = true
				if len(mirrors) > 4 {
					return invalid("UnsupportedValue", "too many mirror destinations")
				}
				continue
			}

			if filter.Type == gw.HTTPRouteFilterRequestRedirect && filter.RequestRedirect != nil {
				f := filter.RequestRedirect
				if redirect != nil || rewrite != nil {
					return invalid("UnsupportedValue", "conflicting redirect/rewrite filters")
				}
				modifier, err := pathModifier(f.Path)
				if err != nil {
					return err
				}
				redirect = &model.Redirect{Path: modifier, Hostname: string(ptr(f.Hostname, gw.PreciseHostname(""))), Scheme: ptr(f.Scheme, ""), Port: int32(ptr(f.Port, gw.PortNumber(0))), StatusCode: ptr(f.StatusCode, 302)}
				continue
			}
			if filter.Type == gw.HTTPRouteFilterURLRewrite && filter.URLRewrite != nil {
				if rewrite != nil || redirect != nil {
					return invalid("UnsupportedValue", "conflicting redirect/rewrite filters")
				}
				f := filter.URLRewrite
				modifier, err := pathModifier(f.Path)
				if err != nil {
					return err
				}
				rewrite = &model.Rewrite{Hostname: string(ptr(f.Hostname, gw.PreciseHostname(""))), Path: modifier}
				if rewrite.Hostname == "" && rewrite.Path == nil {
					return invalid("UnsupportedValue", "empty rewrite")
				}
				continue
			}
			var f *gw.HTTPHeaderFilter
			var dest *[]model.HeaderOperation
			switch filter.Type {
			case gw.HTTPRouteFilterRequestHeaderModifier:
				f = filter.RequestHeaderModifier
				dest = &headers
			case gw.HTTPRouteFilterResponseHeaderModifier:
				f = filter.ResponseHeaderModifier
				dest = &responseHeaders
			default:
				return invalid("UnsupportedValue", "unsupported HTTPRoute filter")
			}
			if f == nil {
				return invalid("UnsupportedValue", "missing header filter")
			}
			for _, h := range f.Set {
				*dest = append(*dest, model.HeaderOperation{Op: "set", Name: strings.ToLower(string(h.Name)), Value: h.Value})
			}
			for _, h := range f.Add {
				*dest = append(*dest, model.HeaderOperation{Op: "add", Name: strings.ToLower(string(h.Name)), Value: h.Value})
			}
			for _, h := range f.Remove {
				*dest = append(*dest, model.HeaderOperation{Op: "remove", Name: strings.ToLower(h)})
			}
		}

		if len(mirrors) > 0 && (redirect != nil || rewrite != nil) {
			return invalid("UnsupportedValue", "mirroring with request transformations unsupported")
		}
		sort.Slice(mirrors, func(i, j int) bool { return mirrors[i].Target < mirrors[j].Target })
		if len(mirrors) == 0 {
			mirrors = nil
		}
		seenHeaders := map[string]bool{}
		for _, h := range headers {
			if !safeHeaderOp(h) || seenHeaders[h.Name] {
				return invalid("UnsupportedValue", "unsupported, protected or duplicate header operation")
			}
			seenHeaders[h.Name] = true
		}
		seenResponse := map[string]bool{}
		for _, h := range responseHeaders {
			protected := false
			switch h.Name {
			case "x-content-type-options", "x-frame-options", "x-powered-by", "x-xss-protection", "x-webkit-csp", "x-content-security-policy":
				protected = true
			}
			if protected || !safeHeaderOp(h) || seenResponse[h.Name] {
				return invalid("UnsupportedValue", "unsupported, protected or duplicate response header operation")
			}
			seenResponse[h.Name] = true
		}
		if len(responseHeaders) > 20 {
			return invalid("UnsupportedValue", "too many response header operations")
		}
		if len(responseHeaders) == 0 {
			responseHeaders = nil
		}
		if len(headers) > 20 {
			return invalid("UnsupportedValue", "too many header operations")
		}
		if redirect != nil && (redirect.StatusCode != 301 && redirect.StatusCode != 302 && redirect.StatusCode != 303 && redirect.StatusCode != 307 && redirect.StatusCode != 308 || redirect.Scheme != "" && redirect.Scheme != "http" && redirect.Scheme != "https" || redirect.Port < 0 || redirect.Port > 65535) {
			return invalid("UnsupportedValue", "invalid redirect")
		}
		if len(headers) == 0 {
			headers = nil
		}
		var backends []model.Backend
		if redirect != nil {
			if len(rule.BackendRefs) > 0 || len(headers) > 0 {
				return invalid("UnsupportedValue", "redirect cannot be combined with backends or header operations")
			}
		} else {
			var err error
			var reason string
			backends, reason, err = r.backends(ctx, route, rule, grants)
			if reason != "" && *refReason == "" {
				*refReason = reason
			}
			if err != nil {
				return err
			}
		}
		var backendTLS *model.BackendTLS
		var backendTLSPeers map[string]*model.BackendTLS
		tlsFailed := false
		if redirect == nil {
			var err error
			backends, backendTLS, backendTLSPeers, tlsFailed, err = r.translateBackendTLS(ctx, route, rule, backends, grants, mirrors, origin.Gateway)
			if err != nil {
				return err
			}
			if tlsFailed && *refReason == "" {
				*refReason = "UnsupportedValue"
			}
			if tlsFailed {
				mirrors = nil
				if err := r.rejectBackendTLSRule(ctx, route, rule, origin.Gateway, grants); err != nil {
					return err
				}
			}
		}
		var retry *model.Retry
		if rule.Retry != nil && !tlsFailed {
			if redirect != nil {
				return invalid("UnsupportedValue", "redirect cannot have retry")
			}
			f := rule.Retry
			backoff, err := deadlineMS(f.Backoff, 60000)
			if err != nil {
				return err
			}
			backoffMS := ptr(backoff, 0)
			if attempts := ptr(f.Attempts, 1); attempts == 0 && backoffMS > 0 {
				return invalid("UnsupportedValue", "disabled retries cannot have backoff")
			}
			attempts := ptr(f.Attempts, 1)
			if attempts < 0 || attempts > 4 {
				return invalid("UnsupportedValue", "retry attempts must be 0–4")
			}
			if attempts > 0 {
				if len(backends) < 2 && deadlines == nil && backoffMS == 0 && len(backendTLSPeers) == 0 {
					return invalid("UnsupportedValue", "retries require multiple distinct backends")
				}
				for _, b := range backends {
					if b.Target == "invalid" || b.Target == "unavailable" {
						return invalid("UnsupportedValue", "retry with invalid backend unsupported")
					}
				}
			}
			retry = &model.Retry{Attempts: attempts, BackoffMS: backoffMS}
			seen := map[int]bool{}
			for _, c := range f.Codes {
				n := int(c)
				if attempts == 0 || (n != 500 && n != 502 && n != 503 && n != 504 && n != 429) || seen[n] {
					return invalid("UnsupportedValue", "unsupported retry status code")
				}
				retry.Codes = append(retry.Codes, n)
				seen[n] = true
			}
			sort.Ints(retry.Codes)
		}
		if deadlines != nil || retry != nil && retry.BackoffMS > 0 {
			if redirect != nil || len(mirrors) > 0 {
				return invalid("UnsupportedValue", "deadlines/backoff cannot be combined with redirects or mirrors")
			}
		}
		routePolicy := policy
		if tlsFailed {
			deadlines = nil
			routePolicy.Health = nil
		}
		matches := rule.Matches
		if len(matches) == 0 {
			matches = []gw.HTTPRouteMatch{{}}
		}
		for _, m := range matches {
			queries := []model.HeaderMatch{}
			querySeen := map[string]bool{}
			for _, q := range m.QueryParams {
				name := string(q.Name)
				if ptr(q.Type, gw.QueryParamMatchExact) != gw.QueryParamMatchExact || !safeQueryLiteral.MatchString(name) || !safeQueryLiteral.MatchString(q.Value) {
					return invalid("UnsupportedValue", "only exact unreserved query literals supported")
				}
				if querySeen[name] {
					continue
				}
				querySeen[name] = true
				queries = append(queries, model.HeaderMatch{Name: name, Value: q.Value})
			}
			if len(queries) == 0 {
				queries = nil
			}
			predicates := []model.HeaderMatch{}
			seen := map[string]bool{}
			for _, h := range m.Headers {
				if ptr(h.Type, gw.HeaderMatchExact) != gw.HeaderMatchExact {
					return invalid("UnsupportedValue", "only exact header matches supported")
				}
				name := strings.ToLower(string(h.Name))
				if !safeHeaderName.MatchString(name) || !safeHeaderValue.MatchString(h.Value) {
					return invalid("UnsupportedValue", "unsupported header predicate")
				}
				if seen[name] {
					continue
				}
				seen[name] = true
				predicates = append(predicates, model.HeaderMatch{Name: name, Value: h.Value})
			}
			if len(predicates) == 0 {
				predicates = nil
			}
			match, path := "prefix", "/"
			if m.Path != nil {
				path = ptr(m.Path.Value, "/")
				switch ptr(m.Path.Type, gw.PathMatchPathPrefix) {
				case gw.PathMatchExact:
					match = "exact"
				case gw.PathMatchPathPrefix:
				default:
					return invalid("UnsupportedValue", "unsupported path match")
				}
			}
			if match == "prefix" {
				path = strings.TrimRight(path, "/")
				if path == "" {
					path = "/"
				}
			}
			if (redirect != nil && redirect.Path != nil && redirect.Path.Type == "prefix" || rewrite != nil && rewrite.Path != nil && rewrite.Path.Type == "prefix") && match != "prefix" {
				return invalid("UnsupportedValue", "prefix replacement requires a prefix match")
			}
			if !safePath(path) {
				return invalid("UnsupportedValue", "unsafe or unsupported path")
			}
			for _, h := range hosts {
				if err := p.Add(h, routePolicy.apply(model.Route{Origins: []model.Origin{origin}, Deadlines: deadlines, Retry: retry, BackendTLS: backendTLS, BackendTLSPeers: backendTLSPeers, Mirrors: mirrors, Match: match, Path: path, Backends: backends, Schemes: []string{scheme}, RequestHeaders: headers, ResponseHeaders: responseHeaders, Redirect: redirect, Rewrite: rewrite, QueryMatches: queries, HeaderMatches: predicates, Method: string(ptr(m.Method, gw.HTTPMethod(""))), HostPriority: routeHostPriority(route, h), Precedence: priority + ruleIndex})); err != nil {
					return invalid("Conflicted", "%v", err)
				}
			}
		}
	}
	return nil
}

type listenerPlan struct {
	gateway  gw.Gateway
	listener gw.Listener
	scheme   string
	tls      *model.TLS
	plan     *model.Plan
}

func listenerKey(g gw.Gateway, l gw.Listener) string {
	return g.Namespace + "/" + g.Name + "/" + string(l.Name)
}
func (r Reader) gateway(ctx context.Context, inv *Inventory) error {
	class, err := get[gw.GatewayClass](ctx, r.Client, GatewayClassGVR, "", r.Config.GatewayClass)
	if err != nil {
		return err
	}
	if string(class.Spec.ControllerName) != r.Config.ControllerName {
		return fmt.Errorf("GatewayClass owned by another controller")
	}
	// A controller must resolve the status of classes naming its controller
	// identity, without adopting classes outside its configured provisioning scope.
	classes, err := list[gw.GatewayClass](ctx, r.Client, GatewayClassGVR)
	if err != nil {
		return err
	}
	for _, c := range classes {
		if string(c.Spec.ControllerName) == r.Config.ControllerName {
			inv.Classes = append(inv.Classes, c)
		}
	}
	if class.Spec.ParametersRef != nil {
		return fmt.Errorf("GatewayClass parametersRef unsupported; configure explicit target")
	}
	gateways, err := list[gw.Gateway](ctx, r.Client, GatewayGVR)
	if err != nil {
		return err
	}
	grants, err := list[beta.ReferenceGrant](ctx, r.Client, grantGVR)
	if err != nil {
		return err
	}
	r.backendTLS, err = r.loadBackendTLS(ctx)
	if err != nil {
		return err
	}
	inv.backendTLS = r.backendTLS
	byName := map[string]gw.Gateway{}
	listeners := map[string]*listenerPlan{}
	for _, g := range gateways {
		if string(g.Spec.GatewayClassName) != r.Config.GatewayClass || !r.Config.OwnsGateway(g.Namespace+"/"+g.Name) {
			continue
		}
		inv.Gateways = append(inv.Gateways, g)
		key := g.Namespace + "/" + g.Name
		byName[key] = g
		if err := validateGateway(g, r.Config.Addresses); err != nil {
			reason, _ := rejection(err)
			inv.GatewayErrors[key] = reason
			continue
		}
		counts := map[string]int{}
		for _, l := range g.Spec.Listeners {
			counts[fmt.Sprintf("%s/%d/%s", l.Protocol, l.Port, ptr(l.Hostname, gw.Hostname("*")))]++
		}
		for _, l := range g.Spec.Listeners {
			lk := listenerKey(g, l)
			if counts[fmt.Sprintf("%s/%d/%s", l.Protocol, l.Port, ptr(l.Hostname, gw.Hostname("*")))] > 1 {
				inv.ListenerErrors[lk] = ListenerFailure{Reason: "Conflicted"}
				continue
			}
			if l.Protocol == gw.HTTPSProtocolType && l.Hostname == nil && !r.Config.GatewayCatchAllHTTPS {
				inv.ListenerErrors[lk] = ListenerFailure{Reason: "UnsupportedValue"}
				continue
			}
			if err := r.validateListener(l); err != nil {
				reason, _ := rejection(err)
				failure := ListenerFailure{Reason: reason}
				if reason == "InvalidRouteKinds" {
					failure.RefReason = reason
				}
				inv.ListenerErrors[lk] = failure
				// A mixed allowedRoutes.kinds list still permits the supported
				// kind, but ResolvedRefs must report the unsupported entries.
				if reason != "InvalidRouteKinds" {
					continue
				}
				supported := false
				for _, k := range l.AllowedRoutes.Kinds {
					if ptr(k.Group, gw.Group(gatewayGroup)) == gw.Group(gatewayGroup) && r.kindAllowed(l, string(k.Kind)) {
						supported = true
					}
				}
				if !supported {
					continue
				}
				inv.ListenerErrors[lk] = ListenerFailure{RefReason: reason}
			}
			scheme := listenerScheme(l)
			var t *model.TLS
			if l.Protocol == gw.HTTPSProtocolType {
				t, err = r.listenerTLS(ctx, g, l, grants)
				if err == nil {
					err = covers(t, string(ptr(l.Hostname, gw.Hostname("*"))))
					if err != nil && r.Config.GatewayClientValidatedFrontend {
						inv.FrontendCertificateWarnings[lk] = true
						err = nil
					}
				}
				if err != nil {
					if reason, ok := rejection(err); ok {
						inv.ListenerErrors[lk] = ListenerFailure{Reason: "Invalid", RefReason: reason}
						continue
					}
					return err
				}
			}
			listeners[lk] = &listenerPlan{gateway: g, listener: l, scheme: scheme, tls: t, plan: model.NewPlan()}
		}
		good := false
		for _, l := range g.Spec.Listeners {
			if listeners[listenerKey(g, l)] != nil {
				good = true
				break
			}
		}
		if !good {
			inv.GatewayErrors[key] = "ListenersNotValid"
		}
	}
	routes, err := list[gw.HTTPRoute](ctx, r.Client, HTTPRouteGVR)
	if err != nil {
		return err
	}
	sort.SliceStable(routes, func(i, j int) bool {
		a, b := routes[i], routes[j]
		if !a.CreationTimestamp.Equal(&b.CreationTimestamp) {
			return a.CreationTimestamp.Before(&b.CreationTimestamp)
		}
		return a.Namespace+"/"+a.Name < b.Namespace+"/"+b.Name
	})
	inv.Routes = routes
	if err := r.allocateBackendTLS(ctx, gateways, routes, grants); err != nil {
		return err
	}
	policies := map[string]Policy{}
	if r.Config.Policies {
		policies, err = r.policies(ctx, inv, byName)
		if err != nil {
			return err
		}
	}
	for key := range inv.GatewayPolicyErrors {
		inv.GatewayErrors[key] = "ListenersNotValid"
		g := byName[key]
		for _, l := range g.Spec.Listeners {
			lk := listenerKey(g, l)
			delete(listeners, lk)
			inv.ListenerErrors[lk] = ListenerFailure{Reason: "UnsupportedValue"}
		}
	}
	// Each listener owns its own route candidates. A bad resource never commits
	// partial routes. Only API read/transport failures abort the complete plan.
	claims := map[string]string{}
	ingressSites := inv.Plan.Snapshot(0).Sites

	for routeIndex, route := range routes {
		var refReason string
		refsChecked := false
		for _, parent := range route.Spec.ParentRefs {
			if ptr(parent.Group, gw.Group(gatewayGroup)) != gw.Group(gatewayGroup) || ptr(parent.Kind, gw.Kind("Gateway")) != "Gateway" {
				continue
			}
			ns := string(ptr(parent.Namespace, gw.Namespace(route.Namespace)))
			key := ns + "/" + string(parent.Name)
			g, ok := byName[key]
			if !ok {
				continue
			}
			allowedParent := false
			// AttachedRoutes counts parent selection and AllowedRoutes, not
			// successful programming or Accepted/ResolvedRefs conditions.
			for _, l := range g.Spec.Listeners {
				if l.Protocol != gw.HTTPProtocolType && l.Protocol != gw.HTTPSProtocolType {
					continue
				}
				if parent.SectionName != nil && *parent.SectionName != l.Name || parent.Port != nil && *parent.Port != l.Port {
					continue
				}
				allowed, err := r.namespaceAllowed(ctx, l, g.Namespace, route.Namespace)
				if err != nil {
					return err
				}
				if allowed {
					allowedParent = true
					inv.Attachments = append(inv.Attachments, Attachment{Gateway: key, Listener: l.Name, Route: route.Namespace + "/" + route.Name})
				}
			}
			if allowedParent {
				if err := r.recordBackendTLS(ctx, route, key, grants); err != nil {
					return err
				}
			}
			if !refsChecked {
				refReason, err = r.routeRefReason(ctx, route, grants)
				if err != nil {
					return err
				}
				refsChecked = true
			}
			status := RouteParent{Route: route, Parent: parent, RefReason: refReason}
			if inv.GatewayPolicyErrors[key] != "" {
				status.RejectedReason = "UnsupportedValue"
				inv.Parents = append(inv.Parents, status)
				continue
			}

			if inv.RoutePolicyErrors[route.Namespace+"/"+route.Name] != "" {
				status.RejectedReason = "UnsupportedValue"
				inv.Parents = append(inv.Parents, status)
				continue
			}
			denied, matched, attached := false, false, false
			reject := ""
			policy, policyErr := inheritPolicy(policies["Gateway:"+key], policies[route.Namespace+"/"+route.Name], route.Namespace == g.Namespace)
			if policyErr != nil {
				status.RejectedReason = "UnsupportedValue"
				inv.Parents = append(inv.Parents, status)
				continue
			}
			for _, l := range g.Spec.Listeners {
				if r.streamListener(l) {
					continue
				}
				if parent.SectionName != nil && *parent.SectionName != l.Name || parent.Port != nil && *parent.Port != l.Port {
					continue
				}
				matched = true
				lp := listeners[listenerKey(g, l)]
				if lp == nil {
					reject = "NoMatchingParent"
					continue
				}
				allowed, err := r.namespaceAllowed(ctx, l, g.Namespace, route.Namespace)
				if err != nil {
					return err
				}
				if !allowed {
					denied = true
					continue
				}
				hosts, err := listenerHosts(l, route)
				if err != nil {
					return err
				}
				eligible := hosts[:0]
				for _, h := range hosts {
					if selectedListener(g, l, h) {
						eligible = append(eligible, h)
					}
				}
				hosts = eligible
				if len(hosts) == 0 {
					continue
				}
				collision := false
				for _, h := range hosts {
					// An explicitly enabled hostname-less TLS listener owns
					// the HTTPS fallback on this partition. Other Gateway
					// owners cannot share that listener's address.
					if l.Protocol == gw.HTTPSProtocolType && l.Hostname == nil {
						for existing, owner := range claims {
							if strings.HasPrefix(existing, lp.scheme+"/") && owner != key {
								collision = true
							}
						}
					}
					for _, site := range ingressSites {
						for _, scheme := range site.Listeners {
							if scheme != lp.scheme {
								continue
							}
							// Explicit Gateway hosts are independent of a global
							// Ingress fallback. Other overlapping scopes are
							// not safe to merge across the two APIs.
							if site.Host == "*" && h != "*" {
								continue
							}
							if _, ok := intersectHost(site.Host, h); ok {
								collision = true
							}
						}
					}
					for existing, owner := range claims {
						parts := strings.SplitN(existing, "/", 2)
						if owner != key && parts[0] == lp.scheme {
							if _, ok := intersectHost(h, parts[1]); ok {
								collision = true
							}
						}
					}
					if lp.tls != nil {
						if err := covers(lp.tls, h); err != nil {
							if r.Config.GatewayClientValidatedFrontend {
								inv.FrontendCertificateWarnings[listenerKey(g, l)] = true
							} else {
								collision = true
							}
						}
					}
				}
				if collision {
					reject = "UnsupportedValue"
					continue
				}
				candidate := lp.plan.Clone()
				reason := ""
				err = r.routeRules(ctx, candidate, route, hosts, lp.scheme, grants, policy, 1+routeIndex*100, &reason, model.Origin{Kind: "HTTPRoute", Key: route.Namespace + "/" + route.Name, Gateway: key, Listener: string(l.Name)})
				if err != nil {
					if why, ok := rejection(err); ok {
						reject = why
						continue
					}
					return err
				}
				// Reserve ownership only after the entire attachment validates.
				for _, h := range hosts {
					claims[lp.scheme+"/"+h] = key
				}
				if l.Protocol == gw.HTTPSProtocolType && l.Hostname == nil {
					claims[lp.scheme+"/*"] = key
				}
				lp.plan = candidate
				if status.RefReason == "" {
					status.RefReason = reason
				}
				attached = true
			}
			if !attached {
				status.RejectedReason = "NoMatchingListenerHostname"
				if reject != "" {
					status.RejectedReason = reject
				} else if denied {
					status.RejectedReason = "NotAllowedByListeners"
				} else if !matched {
					status.RejectedReason = "NoMatchingParent"
				}
			}
			inv.Parents = append(inv.Parents, status)
		}
	}
	if err := r.extraRoutes(ctx, inv, byName, listeners, grants, claims, ingressSites, policies); err != nil {
		return err
	}

	keys := []string{}
	for k := range listeners {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	// Expand matching broader route hostnames into each narrower vhost only
	// inside the SAME listener. The NGINX vhost chosen by hostname then has
	// all eligible rules, with original route-host specificity preserved.
	for _, key := range keys {
		lp := listeners[key]
		if r.streamListener(lp.listener) {
			continue
		}
		sites := lp.plan.Snapshot(0).Sites
		if lp.listener.Protocol == gw.HTTPSProtocolType && lp.listener.Hostname == nil && len(sites) > 0 {
			// Unknown Host/SNI names receive the dedicated listener certificate
			// and an empty 404 route table, rather than another listener.
			fallback := inv.Plan.Clone()
			fallback.Reserve("*", lp.scheme)
			fallback.AddOrigins("*", model.Origin{Kind: "Listener", Key: lp.gateway.Namespace + "/" + lp.gateway.Name, Listener: string(lp.listener.Name)})
			if err := fallback.SetListenerTLS("*", lp.scheme, lp.tls); err != nil {
				return err
			}
			inv.Plan = fallback
		}
		for _, site := range sites {
			candidates := []model.Route{}
			for _, source := range sites {
				if h, ok := intersectHost(source.Host, site.Host); ok && h == site.Host {
					candidates = append(candidates, source.Routes...)
				}
			}
			sort.SliceStable(candidates, func(i, j int) bool {
				a, b := candidates[i], candidates[j]
				if a.HostPriority != b.HostPriority {
					return a.HostPriority > b.HostPriority
				}
				return a.Precedence < b.Precedence
			})
			out := inv.Plan.Clone()
			out.Reserve(site.Host, lp.scheme)
			out.AddOrigins(site.Host, site.Origins...)
			out.AddOrigins(site.Host, model.Origin{Kind: "Listener", Key: lp.gateway.Namespace + "/" + lp.gateway.Name, Listener: string(lp.listener.Name)})
			if lp.tls != nil {
				if err := out.SetListenerTLS(site.Host, lp.scheme, lp.tls); err != nil {
					return err
				}
			}
			for _, route := range candidates {
				if err := out.AddInherited(site.Host, route); err != nil {
					return err
				}
			}
			inv.Plan = out
		}
	}
	// A more-specific listener with no routes must still block fallthrough
	// from a broader listener on the same Gateway and scheme.
	for _, g := range inv.Gateways {
		for _, l := range g.Spec.Listeners {
			lp := listeners[listenerKey(g, l)]
			h := string(ptr(l.Hostname, gw.Hostname("*")))
			if h == "*" {
				continue
			}
			if l.Protocol != gw.HTTPProtocolType && l.Protocol != gw.HTTPSProtocolType {
				continue
			}
			scheme := listenerScheme(l)
			if l.Protocol == gw.HTTPProtocolType && !r.httpPortAllowed(l.Port) || l.Protocol == gw.HTTPSProtocolType && !r.httpsPortAllowed(l.Port) {
				continue
			}
			for key, owner := range claims {
				parts := strings.SplitN(key, "/", 2)
				if owner != g.Namespace+"/"+g.Name || parts[0] != scheme || hostSpecificity(h) <= hostSpecificity(parts[1]) {
					continue
				}
				if x, ok := intersectHost(h, parts[1]); ok && x == h {
					// Invalid HTTPS listener must not use another listener's certificate.
					// Do not add a TLS vhost if we cannot validate its certificate.
					inv.Plan.AddOrigins(h, model.Origin{Kind: "Listener", Key: g.Namespace + "/" + g.Name, Listener: string(l.Name)})
					if l.Protocol == gw.HTTPSProtocolType && lp == nil {
						if err := inv.Plan.RejectListenerTLS(h, scheme); err != nil {
							return err
						}
						break
					}
					inv.Plan.Reserve(h, scheme)
					if lp != nil && lp.tls != nil {
						if err := inv.Plan.SetListenerTLS(h, scheme, lp.tls); err != nil {
							return err
						}
					}
					break
				}
			}
		}
	}
	return nil
}

type Attachment struct {
	Gateway  string
	Listener gw.SectionName
	Route    string
}

type NativePolicy struct {
	meta.TypeMeta   `json:",inline"`
	meta.ObjectMeta `json:"metadata,omitempty"`
	Spec            struct {
		TargetRef struct {
			Group string `json:"group"`
			Kind  string `json:"kind"`
			Name  string `json:"name"`
		} `json:"targetRef"`
		WAF struct {
			Enabled       *bool  `json:"enabled,omitempty"`
			ParanoiaLevel int    `json:"paranoiaLevel,omitempty"`
			Profile       string `json:"profile,omitempty"`
		} `json:"waf,omitempty"`
		RateLimit struct {
			RequestsPerSecond *int `json:"requestsPerSecond,omitempty"`
		} `json:"rateLimit,omitempty"`
		MaxBodySize string             `json:"maxBodySize,omitempty"`
		AllowIPs    []string           `json:"allowIPs,omitempty"`
		HealthCheck *model.HealthCheck `json:"healthCheck,omitempty"`
	} `json:"spec"`
	Status struct {
		Conditions []meta.Condition `json:"conditions,omitempty"`
	} `json:"status,omitempty"`
}

func (r Reader) policies(ctx context.Context, inv *Inventory, gateways map[string]gw.Gateway) (map[string]Policy, error) {
	items, err := list[NativePolicy](ctx, r.Client, policyGVR)
	if err != nil {
		return nil, err
	}
	result := map[string]Policy{}
	owned := map[string]bool{}
	for _, route := range inv.Routes {
		for _, parent := range route.Spec.ParentRefs {
			if ptr(parent.Group, gw.Group(gatewayGroup)) != gw.Group(gatewayGroup) || ptr(parent.Kind, gw.Kind("Gateway")) != "Gateway" {
				continue
			}
			ns := string(ptr(parent.Namespace, gw.Namespace(route.Namespace)))
			if _, ok := gateways[ns+"/"+string(parent.Name)]; ok {
				owned[route.Namespace+"/"+route.Name] = true
			}
		}
	}
	for _, p := range items {
		key := p.Namespace + "/" + p.Spec.TargetRef.Name
		if p.Spec.TargetRef.Kind == "Gateway" {
			if _, ok := gateways[key]; !ok {
				continue
			}
		} else if !owned[key] {
			continue
		}
		inv.Policies = append(inv.Policies, p)
	}
	counts := map[string]int{}
	targetKey := func(p NativePolicy) string {
		key := p.Namespace + "/" + p.Spec.TargetRef.Name
		if p.Spec.TargetRef.Kind == "Gateway" {
			return "Gateway:" + key
		}
		return key
	}
	for _, p := range inv.Policies {
		t := p.Spec.TargetRef
		if t.Group == gatewayGroup && (t.Kind == "HTTPRoute" || t.Kind == "Gateway") && t.Name != "" {
			counts[targetKey(p)]++
		}
	}
	for _, p := range inv.Policies {
		t := p.Spec.TargetRef
		key := targetKey(p)
		pkey := p.Namespace + "/" + p.Name
		if t.Group != gatewayGroup || (t.Kind != "HTTPRoute" && t.Kind != "Gateway") || t.Name == "" {
			inv.PolicyErrors[pkey] = "InvalidTargetRef"
			continue
		}
		policy := Policy{WAFPL: p.Spec.WAF.ParanoiaLevel, WAFProfile: p.Spec.WAF.Profile, RateCount: ptr(p.Spec.RateLimit.RequestsPerSecond, 0), RateSpecified: p.Spec.RateLimit.RequestsPerSecond != nil, MaxBody: p.Spec.MaxBodySize, AllowIPs: p.Spec.AllowIPs, Health: p.Spec.HealthCheck}
		if policy.WAFPL != 0 {
			policy.LevelOwner = pkey
		}
		if policy.WAFProfile != "" {
			policy.ProfileOwner = pkey
		}
		reason := ""
		if counts[key] > 1 {
			reason = "Conflicted"
		} else if p.Spec.WAF.Enabled != nil && !*p.Spec.WAF.Enabled {
			reason = "InvalidPolicy"
		} else if err := policy.validate(); err != nil {
			reason = "InvalidPolicy"
		}
		if reason != "" {
			inv.PolicyErrors[pkey] = reason
			if t.Kind == "Gateway" {
				inv.GatewayPolicyErrors[p.Namespace+"/"+t.Name] = reason
			} else {
				inv.RoutePolicyErrors[key] = reason
			}
			continue
		}
		result[key] = policy
	}

	return result, nil
}
