package kube

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"reflect"
	"sort"
	"strings"

	"github.com/theonemule/docker-waf/controller/internal/model"
	core "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/validation"
	gw "sigs.k8s.io/gateway-api/apis/v1"
	beta "sigs.k8s.io/gateway-api/apis/v1beta1"
)

var backendTLSGVR = schema.GroupVersionResource{Group: gatewayGroup, Version: "v1", Resource: "backendtlspolicies"}
var backendTLSAlpha3GVR = schema.GroupVersionResource{Group: gatewayGroup, Version: "v1alpha3", Resource: "backendtlspolicies"}
var configMapGVR = schema.GroupVersionResource{Version: "v1", Resource: "configmaps"}

type backendTLSDecision struct {
	TLS                       *model.BackendTLS
	AcceptedReason, RefReason string
}
type backendTLSMatch struct {
	Policy   string
	Decision backendTLSDecision
}
type backendTLSSelection struct {
	Selected       *backendTLSDecision
	SelectedPolicy string
	Matches        []backendTLSMatch
}
type backendTLSIndex struct {
	policies      []gw.BackendTLSPolicy
	gvr           schema.GroupVersionResource
	allocated     map[string]map[string]bool
	decisions     map[string]backendTLSDecision
	cache         map[string]backendTLSSelection
	statuses      map[string]map[string]backendTLSDecision
	routePolicies map[string]map[string]bool
}

func policyKey(p gw.BackendTLSPolicy) string { return p.Namespace + "/" + p.Name }

// BackendTLSPolicy is optional on older Gateway API installations. A missing
// CRD is distinct from a denied/failed read, which must not cause HTTP downgrade.
func (r Reader) loadBackendTLS(ctx context.Context) (*backendTLSIndex, error) {
	gvr := backendTLSGVR
	items, err := list[gw.BackendTLSPolicy](ctx, r.Client, gvr)
	if apierrors.IsNotFound(err) {
		// The v1alpha3 shape is compatible with v1. Only fall back when the
		// version is absent, never on RBAC, transport or decoding errors.
		gvr = backendTLSAlpha3GVR
		items, err = list[gw.BackendTLSPolicy](ctx, r.Client, gvr)
	}
	if err != nil && !apierrors.IsNotFound(err) {
		return nil, err
	}
	for _, p := range items {
		if len(p.Spec.TargetRefs) == 0 {
			return nil, fmt.Errorf("backend TLS policy %s/%s has unsupported target schema", p.Namespace, p.Name)
		}
	}
	return &backendTLSIndex{gvr: gvr, policies: items, allocated: map[string]map[string]bool{}, decisions: map[string]backendTLSDecision{}, cache: map[string]backendTLSSelection{}, statuses: map[string]map[string]backendTLSDecision{}, routePolicies: map[string]map[string]bool{}}, nil
}

func validBackendCA(data string) (string, bool) {
	if len(data) == 0 || len(data) > 32768 {
		return "", false
	}
	data = strings.TrimSpace(strings.ReplaceAll(data, "\r\n", "\n")) + "\n"
	rest := []byte(data)
	seen := map[string]bool{}
	for len(bytes.TrimSpace(rest)) > 0 {
		rest = bytes.TrimSpace(rest)
		if !bytes.HasPrefix(rest, []byte("-----BEGIN CERTIFICATE-----")) {
			return "", false
		}
		block, next := pem.Decode(rest)
		if block == nil || block.Type != "CERTIFICATE" || len(block.Headers) > 0 {
			return "", false
		}
		c, err := x509.ParseCertificate(block.Bytes)
		if err != nil || !c.IsCA || !c.BasicConstraintsValid || seen[string(block.Bytes)] {
			return "", false
		}
		seen[string(block.Bytes)] = true
		if len(seen) > 8 {
			return "", false
		}
		rest = next
	}
	return data, len(seen) > 0
}

func (r Reader) validateBackendTLS(ctx context.Context, p gw.BackendTLSPolicy) (backendTLSDecision, error) {
	v := p.Spec.Validation
	bad := backendTLSDecision{AcceptedReason: "Invalid"}
	host := string(v.Hostname)
	if len(validation.IsDNS1123Subdomain(host)) > 0 || net.ParseIP(host) != nil || len(v.SubjectAltNames) > 0 || len(p.Spec.Options) > 0 || v.WellKnownCACertificates != nil {
		return bad, nil
	}
	bad = backendTLSDecision{AcceptedReason: "NoValidCACertificate", RefReason: "InvalidCACertificateRef"}
	if len(v.CACertificateRefs) != 1 {
		return bad, nil
	}
	ref := v.CACertificateRefs[0]
	if ref.Group != "" || ref.Kind != "ConfigMap" {
		bad.RefReason = "InvalidKind"
		return bad, nil
	}
	cm, err := get[core.ConfigMap](ctx, r.Client, configMapGVR, p.Namespace, string(ref.Name))
	if err != nil {
		if apierrors.IsNotFound(err) {
			return bad, nil
		}
		return backendTLSDecision{}, err
	}
	ca, ok := validBackendCA(cm.Data["ca.crt"])
	if !ok {
		return bad, nil
	}
	return backendTLSDecision{TLS: &model.BackendTLS{Hostname: host, CACertificate: ca}}, nil
}

// Section-specific policies take precedence over service-wide defaults.
// Within the same scope, the oldest policy wins, followed by lexical name.
// Invalid winning policies never fall back to a different policy or plaintext.
func (r Reader) backendTLSFor(ctx context.Context, ns string, b gw.BackendObjectReference, grants []beta.ReferenceGrant) (backendTLSSelection, error) {
	idx := r.backendTLS
	if idx == nil || len(idx.policies) == 0 || b.Port == nil || ptr(b.Group, gw.Group("")) != "" || ptr(b.Kind, gw.Kind("Service")) != "Service" {
		return backendTLSSelection{}, nil
	}
	namespace := string(ptr(b.Namespace, gw.Namespace(ns)))
	if !permitted(grants, ns, "HTTPRoute", namespace, "Service", string(b.Name)) {
		return backendTLSSelection{}, nil
	}
	key := fmt.Sprintf("%s/%s:%d", namespace, b.Name, *b.Port)
	if selected, ok := idx.cache[key]; ok {
		return selected, nil
	}
	var candidates []gw.BackendTLSPolicy
	needsPort := false
	for _, p := range idx.policies {
		if p.Namespace != namespace {
			continue
		}
		found := false
		for _, t := range p.Spec.TargetRefs {
			if t.Group == "" && t.Kind == "Service" && t.Name == b.Name {
				found = true
				if t.SectionName != nil && *t.SectionName != "" {
					needsPort = true
				}
			}
		}
		if found {
			candidates = append(candidates, p)
		}
	}
	if len(candidates) == 0 {
		idx.cache[key] = backendTLSSelection{}
		return backendTLSSelection{}, nil
	}
	portName := ""
	if needsPort {
		svc, err := get[core.Service](ctx, r.Client, serviceGVR, namespace, string(b.Name))
		if err != nil {
			if apierrors.IsNotFound(err) {
				return backendTLSSelection{}, nil
			}
			return backendTLSSelection{}, err
		}
		for _, p := range svc.Spec.Ports {
			if p.Port == int32(*b.Port) {
				portName = p.Name
				break
			}
		}
	}
	type candidate struct {
		p        gw.BackendTLSPolicy
		specific bool
	}
	var matched []candidate
	for _, p := range candidates {
		found, specific := false, false
		for _, t := range p.Spec.TargetRefs {
			if t.Group != "" || t.Kind != "Service" || t.Name != b.Name {
				continue
			}
			if t.SectionName == nil || *t.SectionName == "" {
				found = true
			}
			if t.SectionName != nil && string(*t.SectionName) == portName && portName != "" {
				found = true
				specific = true
			}
		}
		if found {
			matched = append(matched, candidate{p, specific})
		}
	}
	sort.Slice(matched, func(i, j int) bool {
		a, b := matched[i], matched[j]
		if a.specific != b.specific {
			return a.specific
		}
		if !a.p.CreationTimestamp.Equal(&b.p.CreationTimestamp) {
			return a.p.CreationTimestamp.Before(&b.p.CreationTimestamp)
		}
		return a.p.Name < b.p.Name
	})
	result := backendTLSSelection{}
	seenScope := map[bool]bool{}
	for i, c := range matched {
		pk := policyKey(c.p)
		d := backendTLSDecision{AcceptedReason: "Conflicted"}
		if !seenScope[c.specific] {
			seenScope[c.specific] = true
			// A whole-Service default remains accepted when a section policy overrides
			// one port; it may govern other ports of the same Service.
			var ok bool
			d, ok = idx.decisions[pk]
			if !ok {
				var err error
				d, err = r.validateBackendTLS(ctx, c.p)
				if err != nil {
					return result, err
				}
				idx.decisions[pk] = d
			}
		}
		if i == 0 {
			copy := d
			result.Selected = &copy
			result.SelectedPolicy = pk
		}
		result.Matches = append(result.Matches, backendTLSMatch{pk, d})
	}
	idx.cache[key] = result
	return result, nil
}

// Allocate ancestor slots before creating any route. Every partition sees
// the same class-wide candidate set, so independently reconciled partitions
// do not each assume that all 16 slots are free. Existing status entries,
// including foreign controllers, reserve capacity until their owner removes them.
func (r Reader) allocateBackendTLS(ctx context.Context, gateways []gw.Gateway, routes []gw.HTTPRoute, grants []beta.ReferenceGrant) error {
	idx := r.backendTLS
	if idx == nil || len(idx.policies) == 0 {
		return nil
	}
	byName := map[string]gw.Gateway{}
	for _, g := range gateways {
		if string(g.Spec.GatewayClassName) == r.Config.GatewayClass {
			byName[g.Namespace+"/"+g.Name] = g
		}
	}
	candidates := map[string]map[string]bool{}
	for _, route := range routes {
		for _, parent := range route.Spec.ParentRefs {
			if ptr(parent.Group, gw.Group(gatewayGroup)) != gw.Group(gatewayGroup) || ptr(parent.Kind, gw.Kind("Gateway")) != "Gateway" {
				continue
			}
			key := string(ptr(parent.Namespace, gw.Namespace(route.Namespace))) + "/" + string(parent.Name)
			g, ok := byName[key]
			if !ok {
				continue
			}
			allowed := false
			for _, l := range g.Spec.Listeners {
				if l.Protocol != gw.HTTPProtocolType && l.Protocol != gw.HTTPSProtocolType {
					continue
				}
				if parent.SectionName != nil && *parent.SectionName != l.Name || parent.Port != nil && *parent.Port != l.Port {
					continue
				}
				ok, err := r.namespaceAllowed(ctx, l, g.Namespace, route.Namespace)
				if err != nil {
					return err
				}
				if ok {
					allowed = true
					break
				}
			}
			if !allowed {
				continue
			}
			record := func(b gw.BackendObjectReference) error {
				selected, err := r.backendTLSFor(ctx, route.Namespace, b, grants)
				if err != nil {
					return err
				}
				for _, m := range selected.Matches {
					if candidates[m.Policy] == nil {
						candidates[m.Policy] = map[string]bool{}
					}
					candidates[m.Policy][key] = true
				}
				return nil
			}
			for _, rule := range route.Spec.Rules {
				for _, b := range rule.BackendRefs {
					if err := record(b.BackendObjectReference); err != nil {
						return err
					}
				}
				for _, f := range rule.Filters {
					if f.Type == gw.HTTPRouteFilterRequestMirror && f.RequestMirror != nil {
						if err := record(f.RequestMirror.BackendRef); err != nil {
							return err
						}
					}
				}
			}
		}
	}
	for _, p := range idx.policies {
		pk := policyKey(p)
		allowed := map[string]bool{}
		remaining := 16 - len(p.Status.Ancestors)
		for _, a := range p.Status.Ancestors {
			k := string(ptr(a.AncestorRef.Namespace, gw.Namespace(p.Namespace))) + "/" + string(a.AncestorRef.Name)
			if string(a.ControllerName) == r.Config.ControllerName && ptr(a.AncestorRef.Kind, gw.Kind("Gateway")) == "Gateway" && ptr(a.AncestorRef.Group, gw.Group(gatewayGroup)) == gw.Group(gatewayGroup) && candidates[pk][k] {
				allowed[k] = true
			}
		}
		keys := []string{}
		for k := range candidates[pk] {
			if !allowed[k] {
				keys = append(keys, k)
			}
		}
		sort.Strings(keys)
		for _, k := range keys {
			if remaining <= 0 {
				break
			}
			allowed[k] = true
			remaining--
		}
		idx.allocated[pk] = allowed
	}
	return nil
}

func mergeTLSDecision(old, next backendTLSDecision) backendTLSDecision {
	// Preserve a concrete validation failure, then a conflict, over success.
	if old.AcceptedReason != "" && (next.AcceptedReason == "" || old.RefReason != "") {
		return old
	}
	return next
}

func (r Reader) recordBackendTLS(ctx context.Context, route gw.HTTPRoute, gateway string, grants []beta.ReferenceGrant) error {
	idx := r.backendTLS
	if idx == nil {
		return nil
	}
	rk := route.Namespace + "/" + route.Name + "|" + gateway
	record := func(b gw.BackendObjectReference, mirror bool) error {
		selected, err := r.backendTLSFor(ctx, route.Namespace, b, grants)
		if err != nil {
			return err
		}
		for _, m := range selected.Matches {
			if !idx.allocated[m.Policy][gateway] {
				continue
			}
			if mirror && m.Decision.AcceptedReason == "" {
				m.Decision.AcceptedReason = "Invalid"
			}
			if idx.statuses[m.Policy] == nil {
				idx.statuses[m.Policy] = map[string]backendTLSDecision{}
			}
			old, ok := idx.statuses[m.Policy][gateway]
			if ok {
				idx.statuses[m.Policy][gateway] = mergeTLSDecision(old, m.Decision)
			} else {
				idx.statuses[m.Policy][gateway] = m.Decision
			}
			if idx.routePolicies[rk] == nil {
				idx.routePolicies[rk] = map[string]bool{}
			}
			idx.routePolicies[rk][m.Policy] = true
		}
		return nil
	}
	for _, rule := range route.Spec.Rules {
		for _, b := range rule.BackendRefs {
			if err := record(b.BackendObjectReference, false); err != nil {
				return err
			}
		}
		for _, f := range rule.Filters {
			if f.Type == gw.HTTPRouteFilterRequestMirror && f.RequestMirror != nil {
				if err := record(f.RequestMirror.BackendRef, true); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// The native TLS identity is route-wide. Until per-peer identities are
// available, mixed plaintext/TLS or differing TLS identities fail the whole
// rule with a local 500, rather than forwarding any TLS-required request as HTTP.
func (r Reader) translateBackendTLS(ctx context.Context, route gw.HTTPRoute, rule gw.HTTPRouteRule, backends []model.Backend, grants []beta.ReferenceGrant, mirrors []model.Mirror, gateway string) ([]model.Backend, *model.BackendTLS, map[string]*model.BackendTLS, bool, error) {
	fail := func() ([]model.Backend, *model.BackendTLS, map[string]*model.BackendTLS, bool, error) {
		return []model.Backend{{Target: "invalid", Weight: 1}}, nil, nil, true, nil
	}
	if r.backendTLS == nil || len(r.backendTLS.policies) == 0 {
		return backends, nil, nil, false, nil
	}
	required, failed := false, false
	byTarget := map[string]*model.BackendTLS{}
	for _, b := range rule.BackendRefs {
		if ptr(b.Weight, int32(1)) == 0 {
			continue
		}
		selected, err := r.backendTLSFor(ctx, route.Namespace, b.BackendObjectReference, grants)
		if err != nil {
			return nil, nil, nil, false, err
		}
		var trust *model.BackendTLS
		if selected.Selected != nil {
			required = true
			if selected.Selected.TLS == nil || !r.backendTLS.allocated[selected.SelectedPolicy][gateway] {
				failed = true
				continue
			}
			trust = selected.Selected.TLS
		}
		targets, _, err := r.resolveBackend(ctx, route.Namespace, b.BackendObjectReference, grants)
		if err != nil {
			return nil, nil, nil, false, err
		}
		for _, target := range targets {
			if old, ok := byTarget[target]; ok && !reflect.DeepEqual(old, trust) {
				failed = true
			}
			byTarget[target] = trust
		}
	}
	if !required {
		return backends, nil, nil, false, nil
	}
	if failed || len(mirrors) > 0 {
		return fail()
	}
	var uniform *model.BackendTLS
	allTLS, allSame := true, true
	peers := map[string]*model.BackendTLS{}
	for i, b := range backends {
		if b.Target == "unavailable" {
			// Preserve the reserved match for an empty TLS pool, never downgrade.
			return []model.Backend{{Target: "unavailable", Weight: 1}}, nil, nil, false, nil
		}
		trust, ok := byTarget[b.Target]
		if !ok || b.Target == "invalid" || !strings.HasPrefix(b.Target, "http://") {
			return fail()
		}
		if trust == nil {
			allTLS = false
			continue
		}
		if uniform == nil {
			uniform = trust
		} else if !reflect.DeepEqual(uniform, trust) {
			allSame = false
		}
		target := "https://" + strings.TrimPrefix(b.Target, "http://")
		backends[i].Target = target
		peers[target] = trust
	}
	if len(peers) == 0 {
		return fail()
	}
	sort.Slice(backends, func(i, j int) bool { return backends[i].Target < backends[j].Target })
	if allTLS && allSame {
		return backends, uniform, nil, false, nil
	}
	raw, err := json.Marshal(peers)
	if err != nil {
		return nil, nil, nil, false, err
	}
	if len(raw) > 40000 {
		return fail()
	}
	return backends, nil, peers, false, nil
}

func (r Reader) rejectBackendTLSRule(ctx context.Context, route gw.HTTPRoute, rule gw.HTTPRouteRule, gateway string, grants []beta.ReferenceGrant) error {
	if r.backendTLS == nil {
		return nil
	}
	for _, b := range rule.BackendRefs {
		if ptr(b.Weight, int32(1)) == 0 {
			continue
		}
		selection, err := r.backendTLSFor(ctx, route.Namespace, b.BackendObjectReference, grants)
		if err != nil {
			return err
		}
		for _, m := range selection.Matches {
			if statuses := r.backendTLS.statuses[m.Policy]; statuses != nil {
				if d, ok := statuses[gateway]; ok && d.AcceptedReason == "" {
					d.AcceptedReason = "Invalid"
					statuses[gateway] = d
				}
			}
		}
	}
	return nil
}

func (r Reader) reportBackendTLS(ctx context.Context, idx *backendTLSIndex, valid, applied bool) error {
	if idx == nil || !valid {
		return nil
	}
	var first error
	for _, p := range idx.policies {
		desired := idx.statuses[policyKey(p)]
		// Do not touch policies that have never been associated with this controller.
		own := false
		for _, a := range p.Status.Ancestors {
			if string(a.ControllerName) == r.Config.ControllerName && r.Config.OwnsGateway(string(ptr(a.AncestorRef.Namespace, gw.Namespace(p.Namespace)))+"/"+string(a.AncestorRef.Name)) {
				own = true
			}
		}
		if len(desired) == 0 && !own {
			continue
		}
		err := updateStatus[gw.BackendTLSPolicy](ctx, r.Client, idx.gvr, &p, func(o *gw.BackendTLSPolicy) any {
			out := []gw.PolicyAncestorStatus{}
			previous := map[string]gw.PolicyAncestorStatus{}
			for _, a := range o.Status.Ancestors {
				k := string(ptr(a.AncestorRef.Namespace, gw.Namespace(o.Namespace))) + "/" + string(a.AncestorRef.Name)
				if string(a.ControllerName) != r.Config.ControllerName || !r.Config.OwnsGateway(k) {
					out = append(out, a)
					continue
				}
				previous[k] = a
			}
			keys := []string{}
			for k := range desired {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				if len(out) >= 16 {
					break
				}
				parts := strings.SplitN(k, "/", 2)
				group := gw.Group(gatewayGroup)
				kind := gw.Kind("Gateway")
				ns := gw.Namespace(parts[0])
				a := previous[k]
				a.ControllerName = gw.GatewayController(r.Config.ControllerName)
				a.AncestorRef = gw.ParentReference{Group: &group, Kind: &kind, Namespace: &ns, Name: gw.ObjectName(parts[1])}
				d := desired[k]
				accepted, ar := meta.ConditionTrue, "Accepted"
				if d.AcceptedReason != "" {
					accepted, ar = meta.ConditionFalse, d.AcceptedReason
				} else if !applied {
					accepted, ar = meta.ConditionFalse, "Pending"
				}
				resolved, rr := meta.ConditionTrue, "ResolvedRefs"
				if d.RefReason != "" {
					resolved, rr = meta.ConditionFalse, d.RefReason
				}
				condition(&a.Conditions, "Accepted", accepted, ar, "Backend TLS policy configuration: "+ar, o.Generation)
				condition(&a.Conditions, "ResolvedRefs", resolved, rr, "Backend TLS certificate references: "+rr, o.Generation)
				out = append(out, a)
			}
			o.Status.Ancestors = out
			return &o.Status
		})
		if err != nil && first == nil {
			first = err
		}
	}
	return first
}
