package kube

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"net"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/theonemule/docker-waf/controller/internal/model"
	core "k8s.io/api/core/v1"
	discovery "k8s.io/api/discovery/v1"
	netv1 "k8s.io/api/networking/v1"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	gw "sigs.k8s.io/gateway-api/apis/v1"
)

var (
	IngressGVR       = schema.GroupVersionResource{Group: "networking.k8s.io", Version: "v1", Resource: "ingresses"}
	ingressClassGVR  = schema.GroupVersionResource{Group: "networking.k8s.io", Version: "v1", Resource: "ingressclasses"}
	GatewayGVR       = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1", Resource: "gateways"}
	GatewayClassGVR  = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1", Resource: "gatewayclasses"}
	HTTPRouteGVR     = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1", Resource: "httproutes"}
	grantGVR         = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1beta1", Resource: "referencegrants"}
	endpointSliceGVR = schema.GroupVersionResource{Group: "discovery.k8s.io", Version: "v1", Resource: "endpointslices"}
	serviceGVR       = schema.GroupVersionResource{Version: "v1", Resource: "services"}
	secretGVR        = schema.GroupVersionResource{Version: "v1", Resource: "secrets"}
	namespaceGVR     = schema.GroupVersionResource{Version: "v1", Resource: "namespaces"}
	policyGVR        = schema.GroupVersionResource{Group: "lightedge.blaize.net", Version: "v1alpha1", Resource: "lightedgepolicies"}
)

type Config struct {
	ControllerName, IngressClass, GatewayClass, BackendMode, NodeAddress string
	Addresses                                                            []string
	Ingress, Gateway, Policies                                           bool
	IngressWildcard, IngressCatchAll                                     bool
	GatewayCatchAllHTTPS                                                 bool
	GatewayClientValidatedFrontend                                       bool
	ExtraHTTPPorts                                                       []int
	ExtraHTTPSPorts                                                      []int
	GRPC                                                                 bool
	StreamPorts                                                          map[string][]int
	Scope                                                                *GatewayScope
}

// GatewayScope is nil for the legacy single-appliance mode. A non-nil
// scope assigns Gateways by namespace/name; the default owns unassigned keys.
type GatewayScope struct {
	Default   bool
	Assigned  map[string]bool
	Elsewhere map[string]bool
}

func (c Config) OwnsGateway(key string) bool {
	if c.Scope == nil {
		return true
	}
	if c.Scope.Default {
		return !c.Scope.Elsewhere[key]
	}
	return c.Scope.Assigned[key]
}

type Reader struct {
	Client     dynamic.Interface
	Config     Config
	backendTLS *backendTLSIndex
}

func list[T any](ctx context.Context, c dynamic.Interface, gvr schema.GroupVersionResource) ([]T, error) {
	out := []T{}
	next := ""
	for {
		page, err := c.Resource(gvr).List(ctx, meta.ListOptions{Limit: 500, Continue: next})
		if err != nil {
			return nil, fmt.Errorf("list %s: %w", gvr.Resource, err)
		}
		for _, o := range page.Items {
			var value T
			if err := runtime.DefaultUnstructuredConverter.FromUnstructured(o.Object, &value); err != nil {
				return nil, fmt.Errorf("decode %s: %w", gvr.Resource, err)
			}
			out = append(out, value)
		}
		next = page.GetContinue()
		if next == "" {
			return out, nil
		}
	}
}
func get[T any](ctx context.Context, c dynamic.Interface, gvr schema.GroupVersionResource, ns, name string) (T, error) {
	var value T
	var o *unstructured.Unstructured
	var err error
	if ns == "" {
		o, err = c.Resource(gvr).Get(ctx, name, meta.GetOptions{})
	} else {
		o, err = c.Resource(gvr).Namespace(ns).Get(ctx, name, meta.GetOptions{})
	}
	if err != nil {
		return value, fmt.Errorf("get %s %s/%s: %w", gvr.Resource, ns, name, err)
	}
	err = runtime.DefaultUnstructuredConverter.FromUnstructured(o.Object, &value)
	return value, err
}
func ptr[T comparable](v *T, fallback T) T {
	if v == nil {
		return fallback
	}
	return *v
}

type resourceError struct{ reason, message string }

func (e resourceError) Error() string { return e.message }
func invalid(reason, format string, args ...any) error {
	return resourceError{reason, fmt.Sprintf(format, args...)}
}
func rejection(err error) (string, bool) {
	var e resourceError
	if errors.As(err, &e) {
		return e.reason, true
	}
	return "", false
}

type invalidBackend struct{ reason string }

func (e invalidBackend) Error() string { return e.reason }
func (r Reader) serviceTargets(ctx context.Context, ns, name string, number int32, portName string) ([]string, error) {
	return r.serviceProtocolTargets(ctx, ns, name, number, portName, core.ProtocolTCP, "http")
}
func (r Reader) serviceProtocolTargets(ctx context.Context, ns, name string, number int32, portName string, protocol core.Protocol, scheme string) ([]string, error) {
	svc, err := get[core.Service](ctx, r.Client, serviceGVR, ns, name)
	if err != nil {
		if apierrors.IsNotFound(err) {
			return nil, invalidBackend{"BackendNotFound"}
		}
		return nil, err
	}
	if svc.Spec.Type == core.ServiceTypeExternalName {
		return nil, invalidBackend{"BackendNotFound"}
	}
	var port *core.ServicePort
	for i := range svc.Spec.Ports {
		p := &svc.Spec.Ports[i]
		if ((portName != "" && p.Name == portName) || (portName == "" && number == p.Port)) && (p.Protocol == protocol || p.Protocol == "" && protocol == core.ProtocolTCP) {
			port = p
			break
		}
	}
	if port == nil {
		return nil, invalidBackend{"BackendNotFound"}
	}
	host, n := svc.Spec.ClusterIP, port.Port
	switch r.Config.BackendMode {
	case "clusterip":
		if host == core.ClusterIPNone {
			return r.headlessProtocolTargets(ctx, svc, *port, protocol, scheme)
		}
		if net.ParseIP(host) == nil || strings.Contains(host, ":") {
			return nil, invalidBackend{"BackendNotFound"}
		}
	case "nodeport":
		if svc.Spec.ExternalTrafficPolicy == core.ServiceExternalTrafficPolicyLocal {
			return nil, invalidBackend{"BackendNotFound"}
		}
		host, n = r.Config.NodeAddress, port.NodePort
		if net.ParseIP(host) == nil || strings.Contains(host, ":") || n == 0 {
			return nil, invalidBackend{"BackendNotFound"}
		}
	case "loadbalancer":
		if svc.Spec.Type != core.ServiceTypeLoadBalancer {
			return nil, invalidBackend{"BackendNotFound"}
		}
		addresses := []string{}
		for _, entry := range svc.Status.LoadBalancer.Ingress {
			if entry.IP != "" && !strings.Contains(entry.IP, ":") {
				addresses = append(addresses, entry.IP)
			} else if entry.Hostname != "" {
				addresses = append(addresses, entry.Hostname)
			}
		}
		sort.Strings(addresses)
		if len(addresses) == 0 {
			return nil, invalidBackend{"BackendNotFound"}
		}
		host = addresses[0]
	default:
		return nil, fmt.Errorf("unknown backend mode")
	}
	return []string{scheme + "://" + net.JoinHostPort(host, strconv.Itoa(int(n)))}, nil
}

// Headless Services are resolved from their namespace-local EndpointSlices.
// Endpoint port names, not Service ports, determine the target socket.
// A valid Service without ready endpoints is not an invalid reference.
func (r Reader) headlessTargets(ctx context.Context, svc core.Service, port core.ServicePort) ([]string, error) {
	return r.headlessProtocolTargets(ctx, svc, port, core.ProtocolTCP, "http")
}
func (r Reader) headlessProtocolTargets(ctx context.Context, svc core.Service, port core.ServicePort, protocol core.Protocol, scheme string) ([]string, error) {
	targets := map[string]bool{}
	next := ""
	for {
		page, err := r.Client.Resource(endpointSliceGVR).Namespace(svc.Namespace).List(ctx, meta.ListOptions{LabelSelector: discovery.LabelServiceName + "=" + svc.Name, Limit: 100, Continue: next})
		if err != nil {
			return nil, fmt.Errorf("list EndpointSlices for %s/%s: %w", svc.Namespace, svc.Name, err)
		}
		for _, raw := range page.Items {
			var slice discovery.EndpointSlice
			if err := runtime.DefaultUnstructuredConverter.FromUnstructured(raw.Object, &slice); err != nil {
				return nil, err
			}
			if slice.Labels[discovery.LabelServiceName] != svc.Name || slice.AddressType != discovery.AddressTypeIPv4 {
				continue
			}
			stale := false
			for _, owner := range slice.OwnerReferences {
				if owner.Kind == "Service" && owner.UID != svc.UID && svc.UID != "" {
					stale = true
				}
			}
			if stale {
				continue
			}
			for _, epPort := range slice.Ports {
				if ptr(epPort.Name, "") != port.Name || ptr(epPort.Protocol, core.ProtocolTCP) != protocol || epPort.Port == nil || *epPort.Port < 1 || *epPort.Port > 65535 {
					continue
				}
				for _, ep := range slice.Endpoints {
					if !ptr(ep.Conditions.Ready, true) || ptr(ep.Conditions.Terminating, false) {
						continue
					}
					for _, address := range ep.Addresses {
						ip := net.ParseIP(address)
						if ip == nil || ip.To4() == nil || strings.Contains(address, ":") || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsMulticast() || ip.IsUnspecified() {
							continue
						}
						targets[scheme+"://"+net.JoinHostPort(ip.String(), strconv.Itoa(int(*epPort.Port)))] = true
						if len(targets) > 16 {
							return nil, invalidBackend{"UnsupportedValue"}
						}
					}
				}
			}
		}
		next = page.GetContinue()
		if next == "" {
			break
		}
	}
	if len(targets) == 0 {
		return []string{"unavailable"}, nil
	}
	out := []string{}
	for target := range targets {
		out = append(out, target)
	}
	sort.Strings(out)
	return out, nil
}

func unweightedTargets(targets []string) []model.Backend {
	out := make([]model.Backend, 0, len(targets))
	for _, target := range targets {
		out = append(out, model.Backend{Target: target, Weight: 1})
	}
	return out
}
func (r Reader) tls(ctx context.Context, ns, name string) (*model.TLS, error) {
	s, err := get[core.Secret](ctx, r.Client, secretGVR, ns, name)
	if err != nil {
		if apierrors.IsNotFound(err) {
			return nil, invalid("InvalidCertificateRef", "TLS Secret not found")
		}
		return nil, err
	}
	if s.Type != core.SecretTypeTLS || len(s.Data[core.TLSCertKey]) == 0 || len(s.Data[core.TLSPrivateKeyKey]) == 0 {
		return nil, invalid("InvalidCertificateRef", "invalid TLS Secret %s/%s", ns, name)
	}
	pair, err := tls.X509KeyPair(s.Data[core.TLSCertKey], s.Data[core.TLSPrivateKeyKey])
	if err != nil {
		return nil, invalid("InvalidCertificateRef", "TLS certificate/key mismatch or malformed PEM")
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil || time.Now().Before(leaf.NotBefore) || time.Now().After(leaf.NotAfter) {
		return nil, invalid("InvalidCertificateRef", "TLS certificate not currently valid")
	}
	return &model.TLS{Certificate: string(s.Data[core.TLSCertKey]), PrivateKey: string(s.Data[core.TLSPrivateKeyKey])}, nil
}
func covers(t *model.TLS, host string) error {
	if t == nil {
		return invalid("InvalidCertificateRef", "TLS certificate required")
	}
	pair, err := tls.X509KeyPair([]byte(t.Certificate), []byte(t.PrivateKey))
	if err != nil {
		return invalid("InvalidCertificateRef", "invalid TLS pair")
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return invalid("InvalidCertificateRef", "invalid TLS certificate")
	}
	if host == "*" {
		return nil
	}
	if strings.HasPrefix(host, "*.") {
		for _, name := range leaf.DNSNames {
			if strings.EqualFold(name, host) {
				return nil
			}
		}
		return invalid("InvalidCertificateRef", "TLS certificate requires matching wildcard SAN")
	}
	if leaf.VerifyHostname(host) != nil {
		return invalid("InvalidCertificateRef", "TLS certificate does not cover %s", host)
	}
	return nil
}

type Policy struct {
	WAFPL, RateCount         int
	RateSpecified            bool
	ProfileOwner, LevelOwner string
	WAFProfile               string
	MaxBody                  string
	AllowIPs                 []string
	Health                   *model.HealthCheck
}

func policyFromAnnotations(a map[string]string) (Policy, error) {
	p := Policy{}
	for k, v := range a {
		switch k {
		case "lightedge.blaize.net/waf-profile":
			p.WAFProfile = v
		case "lightedge.blaize.net/waf-paranoia-level":
			n, e := strconv.Atoi(v)
			if e != nil || n < 1 || n > 4 {
				return p, fmt.Errorf("invalid WAF paranoia level")
			}
			p.WAFPL = n
		case "lightedge.blaize.net/rate-limit":
			n, e := strconv.Atoi(v)
			if e != nil || n < 0 || n > 999999 {
				return p, fmt.Errorf("invalid rate limit")
			}
			p.RateCount = n
			p.RateSpecified = true
		case "lightedge.blaize.net/allow-ips":
			p.AllowIPs = strings.Split(v, ",")
		case "lightedge.blaize.net/health-path":
			p.Health = &model.HealthCheck{Enabled: true, Path: v}
		case "lightedge.blaize.net/max-body-size":
			p.MaxBody = v
		case "lightedge.blaize.net/waf-enabled":
			if v != "true" {
				return p, fmt.Errorf("disabling WAF is not allowed")
			}
		default:
			if strings.HasPrefix(k, "lightedge.blaize.net/") {
				return p, fmt.Errorf("unsupported LightEdge annotation %s", k)
			}
		}
	}
	return p, p.validate()
}

var policyProfile = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)
var bodySize = regexp.MustCompile(`^[1-9][0-9]{0,6}[km]?$`)
var expectedStatus = regexp.MustCompile(`^[1-5]([0-9]{2}|xx)$`)

func (p Policy) validate() error {
	if p.WAFPL < 0 || p.WAFPL > 4 || p.RateCount < 0 || p.RateCount > 999999 || p.WAFProfile != "" && !policyProfile.MatchString(p.WAFProfile) || p.MaxBody != "" && !bodySize.MatchString(p.MaxBody) {
		return fmt.Errorf("invalid policy bounds")
	}
	if len(p.AllowIPs) > 128 {
		return fmt.Errorf("too many IP allowlist entries")
	}
	for _, ip := range p.AllowIPs {
		if net.ParseIP(ip) == nil {
			if _, _, err := net.ParseCIDR(ip); err != nil {
				return fmt.Errorf("invalid policy IP allowlist")
			}
		}
	}
	if h := p.Health; h != nil {
		if h.Path != "" && !safePath(h.Path) || h.Interval != 0 && (h.Interval < 5 || h.Interval > 3600) || h.Timeout != 0 && (h.Timeout < 1 || h.Timeout > 60) || h.Interval != 0 && h.Timeout > h.Interval || h.Expected != "" && !expectedStatus.MatchString(h.Expected) {
			return fmt.Errorf("invalid health check")
		}
	}
	return nil
}
func inheritPolicy(base, override Policy, sameNamespace bool) (Policy, error) {
	out := base
	conflict := func(field string) error {
		return invalid("UnsupportedValue", "cross-namespace route policy cannot replace Gateway %s", field)
	}
	if override.WAFPL != 0 {
		if !sameNamespace && base.WAFPL != 0 && override.WAFPL < base.WAFPL {
			return out, conflict("WAF level")
		}
		out.WAFPL = override.WAFPL
		out.LevelOwner = override.LevelOwner
	}
	if override.WAFProfile != "" {
		if !sameNamespace && base.WAFProfile != "" && base.WAFProfile != override.WAFProfile {
			return out, conflict("WAF profile")
		}
		out.WAFProfile = override.WAFProfile
		out.ProfileOwner = override.ProfileOwner
	}
	if override.RateSpecified {
		if !sameNamespace && base.RateCount > 0 && (override.RateCount == 0 || override.RateCount > base.RateCount) {
			return out, conflict("rate limit")
		}
		out.RateCount = override.RateCount
		out.RateSpecified = true
	}
	if override.MaxBody != "" {
		// Cross-namespace overrides must not replace inherited maximum body size.
		if !sameNamespace && base.MaxBody != "" && override.MaxBody != base.MaxBody {
			return out, conflict("maximum body size")
		}
		out.MaxBody = override.MaxBody
	}
	if override.AllowIPs != nil {
		if !sameNamespace && len(base.AllowIPs) > 0 && !reflect.DeepEqual(base.AllowIPs, override.AllowIPs) {
			return out, conflict("IP allowlist")
		}
		out.AllowIPs = override.AllowIPs
	}
	if override.Health != nil {
		out.Health = override.Health
	}
	return out, nil
}
func (p Policy) apply(route model.Route) model.Route {
	route.WAFPL = p.WAFPL
	route.WAFProfile = p.WAFProfile
	route.WAFProfileOwner = p.ProfileOwner
	route.WAFLevelOwner = p.LevelOwner
	route.RateCount = p.RateCount
	route.MaxBody = p.MaxBody
	route.AllowIPs = p.AllowIPs
	route.Health = p.Health
	return route
}

type Inventory struct {
	ExtraRoutes                 []ExtraRoute
	ExtraParents                []ExtraParent
	Plan                        *model.Plan
	backendTLS                  *backendTLSIndex
	Ingresses                   []netv1.Ingress
	Classes                     []gw.GatewayClass
	Gateways                    []gw.Gateway
	Parents                     []RouteParent
	Attachments                 []Attachment
	Routes                      []gw.HTTPRoute
	Policies                    []NativePolicy
	GatewayErrors               map[string]string
	GatewayPolicyErrors         map[string]string
	ListenerErrors              map[string]ListenerFailure
	FrontendCertificateWarnings map[string]bool
	IngressErrors               map[string]string
	PolicyErrors                map[string]string
	RoutePolicyErrors           map[string]string
}
type ListenerFailure struct {
	Reason    string
	RefReason string
}
type RouteParent struct {
	Route          gw.HTTPRoute
	Parent         gw.ParentReference
	RejectedReason string
	RefReason      string
}

func (r Reader) Build(ctx context.Context) (Inventory, error) {
	inv := Inventory{Plan: model.NewPlan(), GatewayErrors: map[string]string{}, GatewayPolicyErrors: map[string]string{}, ListenerErrors: map[string]ListenerFailure{}, FrontendCertificateWarnings: map[string]bool{}, IngressErrors: map[string]string{}, PolicyErrors: map[string]string{}, RoutePolicyErrors: map[string]string{}}
	if r.Config.Ingress {
		cls, err := get[netv1.IngressClass](ctx, r.Client, ingressClassGVR, "", r.Config.IngressClass)
		if err != nil {
			return inv, err
		}
		if cls.Spec.Controller != r.Config.ControllerName {
			return inv, fmt.Errorf("IngressClass owned by another controller")
		}
		if cls.Spec.Parameters != nil {
			return inv, fmt.Errorf("IngressClass parameters unsupported")
		}
		ingresses, err := list[netv1.Ingress](ctx, r.Client, IngressGVR)
		if err != nil {
			return inv, err
		}
		sort.SliceStable(ingresses, func(i, j int) bool {
			a, b := ingresses[i], ingresses[j]
			if !a.CreationTimestamp.Equal(&b.CreationTimestamp) {
				return a.CreationTimestamp.Before(&b.CreationTimestamp)
			}
			return a.Namespace+"/"+a.Name < b.Namespace+"/"+b.Name
		})
		for _, ing := range ingresses {
			if ing.Spec.IngressClassName == nil || *ing.Spec.IngressClassName != r.Config.IngressClass {
				continue
			}
			inv.Ingresses = append(inv.Ingresses, ing)
			candidate := inv.Plan.Clone()
			if err := r.ingress(ctx, candidate, ing); err != nil {
				if reason, ok := rejection(err); ok {
					inv.IngressErrors[ing.Namespace+"/"+ing.Name] = reason
					continue
				}
				return inv, fmt.Errorf("Ingress %s/%s: %w", ing.Namespace, ing.Name, err)
			}
			inv.Plan = candidate
		}
	}
	if r.Config.Ingress {
		sites := inv.Plan.Snapshot(0).Sites
		var fallback *model.Route
		for _, site := range sites {
			if site.Host == "*" {
				for _, route := range site.Routes {
					// Only a dedicated defaultBackend generates a precedence-zero root.
					if route.Match == "prefix" && route.Path == "/" && route.Precedence == 0 {
						v := route
						fallback = &v
					}
				}
			}
		}
		if fallback != nil {
			for _, site := range sites {
				if site.Host == "*" {
					continue
				}
				for _, scheme := range site.Listeners {
					root := false
					for _, route := range site.Routes {
						if route.Match == "prefix" && route.Path == "/" {
							for _, s := range route.Schemes {
								if s == scheme {
									root = true
								}
							}
						}
					}
					if !root {
						v := *fallback
						v.Schemes = []string{scheme}
						if err := inv.Plan.AddInherited(site.Host, v); err != nil {
							return inv, err
						}
					}
				}
			}
		}
	}
	if r.Config.Gateway {
		if err := r.gateway(ctx, &inv); err != nil {
			return inv, err
		}
	}
	return inv, nil
}
func (r Reader) ingress(ctx context.Context, p *model.Plan, ing netv1.Ingress) error {
	origin := model.Origin{Kind: "Ingress", Key: ing.Namespace + "/" + ing.Name}
	if ing.Spec.DefaultBackend != nil && !r.Config.IngressCatchAll {
		return invalid("UnsupportedValue", "Ingress defaultBackend requires dedicated catch-all opt-in")
	}
	policy, err := policyFromAnnotations(ing.Annotations)
	if err != nil {
		return invalid("UnsupportedValue", "%v", err)
	}
	if ing.Spec.DefaultBackend != nil {
		svc := ing.Spec.DefaultBackend.Service
		if svc == nil {
			return invalid("UnsupportedValue", "only Service defaultBackend supported")
		}
		targets, err := r.serviceTargets(ctx, ing.Namespace, svc.Name, svc.Port.Number, svc.Port.Name)
		if err != nil {
			var backend invalidBackend
			if !errors.As(err, &backend) {
				return err
			}
			targets = []string{"invalid"}
		}
		if err = p.Add("*", policy.apply(model.Route{Origins: []model.Origin{origin}, Match: "prefix", Path: "/", Backends: unweightedTargets(targets), Schemes: []string{"http"}})); err != nil {
			return invalid("Conflicted", "%v", err)
		}
	}
	tlsHosts := map[string]*model.TLS{}
	for _, item := range ing.Spec.TLS {
		if item.SecretName == "" || len(item.Hosts) == 0 {
			return invalid("InvalidCertificateRef", "TLS requires explicit hosts and Secret")
		}
		t, err := r.tls(ctx, ing.Namespace, item.SecretName)
		if err != nil {
			return err
		}
		for _, h := range item.Hosts {
			if strings.HasPrefix(h, "*.") {
				if !r.Config.IngressWildcard {
					return invalid("UnsupportedValue", "Ingress wildcard requires opt-in")
				}
				p.SingleWildcard(h)
			}
			if err := covers(t, h); err != nil {
				return err
			}
			p.AddOrigins(h, origin)
			if err := p.SetTLS(h, t); err != nil {
				return invalid("Conflicted", "%v", err)
			}
			tlsHosts[h] = t
		}
	}
	for _, rule := range ing.Spec.Rules {
		if rule.HTTP == nil {
			return invalid("UnsupportedValue", "HTTP rule required")
		}
		host := rule.Host
		if host == "" {
			if !r.Config.IngressCatchAll {
				return invalid("UnsupportedValue", "hostless Ingress requires dedicated catch-all opt-in")
			}
			host = "*"
		}
		if strings.Contains(host, "*") && host != "*" {
			if !r.Config.IngressWildcard || !strings.HasPrefix(host, "*.") || strings.Contains(host[2:], "*") {
				return invalid("UnsupportedValue", "Ingress wildcard requires opt-in")
			}
			p.SingleWildcard(host)
		}
		for _, path := range rule.HTTP.Paths {
			if path.Backend.Service == nil {
				return invalid("UnsupportedValue", "only Service backends supported")
			}
			match := ""
			switch ptr(path.PathType, netv1.PathTypeImplementationSpecific) {
			case netv1.PathTypeExact:
				match = "exact"
			case netv1.PathTypePrefix:
				match = "prefix"
			default:
				return invalid("UnsupportedValue", "ImplementationSpecific path unsupported")
			}
			if path.Path == "" {
				return invalid("UnsupportedValue", "path required")
			}
			svc := path.Backend.Service
			targets, err := r.serviceTargets(ctx, ing.Namespace, svc.Name, svc.Port.Number, svc.Port.Name)
			if err != nil {
				var backend invalidBackend
				if !errors.As(err, &backend) {
					return err
				}
				targets = []string{"invalid"}
			}
			schemes := []string{"http"}
			if tlsHosts[rule.Host] != nil {
				schemes = append(schemes, "https")
			}
			rp := path.Path
			if match == "prefix" {
				rp = strings.TrimRight(rp, "/")
				if rp == "" {
					rp = "/"
				}
			}
			if !safePath(rp) {
				return invalid("UnsupportedValue", "unsupported path")
			}
			priority := 0
			if host == "*" {
				priority = 1
			}
			if err := p.Add(host, policy.apply(model.Route{Origins: []model.Origin{origin}, Precedence: priority, Match: match, Path: rp, Backends: unweightedTargets(targets), Schemes: schemes})); err != nil {
				return invalid("Conflicted", "%v", err)
			}
		}
	}
	return nil
}
