package kube

import (
	"context"
	"fmt"
	"net"
	"reflect"
	"sort"

	netv1 "k8s.io/api/networking/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metaapi "k8s.io/apimachinery/pkg/api/meta"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	gw "sigs.k8s.io/gateway-api/apis/v1"
)

func condition(conditions *[]meta.Condition, typ string, value meta.ConditionStatus, reason, message string, generation int64) {
	metaapi.SetStatusCondition(conditions, meta.Condition{Type: typ, Status: value, Reason: reason, Message: message, ObservedGeneration: generation})
}
func updateStatus[T any](ctx context.Context, c dynamic.Interface, gvr schema.GroupVersionResource, object meta.Object, mutate func(*T) any) error {
	var ri dynamic.ResourceInterface = c.Resource(gvr)
	if object.GetNamespace() != "" {
		ri = c.Resource(gvr).Namespace(object.GetNamespace())
	}
	current, err := ri.Get(ctx, object.GetName(), meta.GetOptions{})
	if apierrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if current.GetUID() != object.GetUID() || current.GetGeneration() != object.GetGeneration() {
		// This observation is stale. The next normal reconciliation sees
		// the new generation; do not publish old status or back off globally.
		return nil
	}
	var typed T
	if err = runtime.DefaultUnstructuredConverter.FromUnstructured(current.Object, &typed); err != nil {
		return err
	}
	st := mutate(&typed)
	status, err := runtime.DefaultUnstructuredConverter.ToUnstructured(st)
	if err != nil {
		return err
	}
	old, _, _ := unstructured.NestedMap(current.Object, "status")
	if reflect.DeepEqual(old, status) {
		return nil
	}
	if err := unstructured.SetNestedMap(current.Object, status, "status"); err != nil {
		return err
	}
	_, err = ri.UpdateStatus(ctx, current, meta.UpdateOptions{})
	if apierrors.IsNotFound(err) || apierrors.IsConflict(err) {
		return nil
	}
	return err
}
func (r Reader) Report(ctx context.Context, inv Inventory, valid, applied bool) error {
	var first error
	record := func(err error) {
		if err != nil && first == nil {
			first = err
		}
	}
	if applied {
		for _, ing := range inv.Ingresses {
			record(updateStatus[netv1.Ingress](ctx, r.Client, IngressGVR, &ing, func(o *netv1.Ingress) any {
				addrs := []netv1.IngressLoadBalancerIngress{}
				for _, v := range r.Config.Addresses {
					a := netv1.IngressLoadBalancerIngress{}
					if net.ParseIP(v) != nil {
						a.IP = v
					} else {
						a.Hostname = v
					}
					addrs = append(addrs, a)
				}
				if inv.IngressErrors[ing.Namespace+"/"+ing.Name] != "" {
					addrs = nil
				}
				o.Status.LoadBalancer.Ingress = addrs
				return &o.Status
			}))
		}
	}
	for _, class := range inv.Classes {
		record(updateStatus[gw.GatewayClass](ctx, r.Client, GatewayClassGVR, &class, func(o *gw.GatewayClass) any {
			accepted := meta.ConditionTrue
			reason, msg := "Accepted", "LightEdge controller owns this class"
			if o.Name != r.Config.GatewayClass {
				accepted = meta.ConditionFalse
				reason, msg = "Unsupported", "Class is outside the configured LightEdge provisioning scope"
			} else if o.Spec.ParametersRef != nil {
				accepted = meta.ConditionFalse
				reason, msg = "InvalidParameters", "parametersRef is not supported"
			}
			condition(&o.Status.Conditions, "Accepted", accepted, reason, msg, o.Generation)
			return &o.Status
		}))
	}
	for _, g := range inv.Gateways {
		record(updateStatus[gw.Gateway](ctx, r.Client, GatewayGVR, &g, func(o *gw.Gateway) any {
			accept := meta.ConditionTrue
			ar, am := "Accepted", "Gateway configuration accepted"
			if !valid {
				accept = meta.ConditionFalse
				ar, am = "Pending", "Desired snapshot has unsupported or invalid resources"
			}
			program := meta.ConditionFalse
			pr, pm := "Pending", "Desired state is not confirmed by LightEdge"
			if applied && inv.GatewayErrors[g.Namespace+"/"+g.Name] == "" {
				program = meta.ConditionTrue
				pr, pm = "Programmed", "LightEdge applied desired state"
			}
			if valid && inv.GatewayErrors[g.Namespace+"/"+g.Name] != "" {
				accept = meta.ConditionFalse
				ar = inv.GatewayErrors[g.Namespace+"/"+g.Name]
				am = "Gateway has no usable configuration"
			}
			condition(&o.Status.Conditions, "Accepted", accept, ar, am, o.Generation)
			condition(&o.Status.Conditions, "Programmed", program, pr, pm, o.Generation)
			if applied {
				o.Status.Addresses = []gw.GatewayStatusAddress{}
				for _, v := range r.Config.Addresses {
					if accept != meta.ConditionTrue {
						break
					}
					t := gw.HostnameAddressType
					if net.ParseIP(v) != nil {
						t = gw.IPAddressType
					}
					o.Status.Addresses = append(o.Status.Addresses, gw.GatewayStatusAddress{Type: &t, Value: v})
				}
			}
			previous := map[gw.SectionName]gw.ListenerStatus{}
			for _, s := range o.Status.Listeners {
				previous[s.Name] = s
			}
			o.Status.Listeners = []gw.ListenerStatus{}
			for _, l := range o.Spec.Listeners {
				s := previous[l.Name]
				s.Name = l.Name
				group := gw.Group(gatewayGroup)
				s.SupportedKinds = []gw.RouteGroupKind{}
				for _, kind := range r.supportedKinds(l) {
					allowed := l.AllowedRoutes == nil || len(l.AllowedRoutes.Kinds) == 0
					if !allowed {
						for _, k := range l.AllowedRoutes.Kinds {
							if ptr(k.Group, group) == group && string(k.Kind) == kind {
								allowed = true
								break
							}
						}
					}
					if allowed {
						s.SupportedKinds = append(s.SupportedKinds, gw.RouteGroupKind{Group: &group, Kind: gw.Kind(kind)})
					}
				}
				count := map[string]bool{}
				for _, a := range inv.Attachments {
					if a.Gateway == o.Namespace+"/"+o.Name && a.Listener == l.Name {
						count[a.Route] = true
					}
				}
				s.AttachedRoutes = int32(len(count))
				la, lar, lam := accept, ar, am
				lp, lpr, lpm := program, pr, pm
				failure := inv.ListenerErrors[listenerKey(g, l)]
				if valid && failure.Reason != "" {
					la = meta.ConditionFalse
					lar = failure.Reason
					lam = "Listener configuration rejected"
					lp = meta.ConditionFalse
					lpr = "Invalid"
					lpm = "Listener configuration rejected"
				}
				condition(&s.Conditions, "Accepted", la, lar, lam, o.Generation)
				condition(&s.Conditions, "Conflicted", meta.ConditionFalse, "NoConflicts", "No listener conflicts", o.Generation)
				if failure.Reason == "Conflicted" {
					condition(&s.Conditions, "Conflicted", meta.ConditionTrue, "HostnameConflict", "Listener conflicts with another listener", o.Generation)
				}
				resolved := meta.ConditionTrue
				rr, rm := "ResolvedRefs", "Listener references resolved"
				if !valid {
					resolved = meta.ConditionUnknown
					rr, rm = "Pending", "References not confirmed"
				}
				if valid && failure.RefReason != "" {
					resolved = meta.ConditionFalse
					rr = failure.RefReason
					rm = "Listener reference rejected"
				}
				condition(&s.Conditions, "ResolvedRefs", resolved, rr, rm, o.Generation)
				condition(&s.Conditions, "Programmed", lp, lpr, lpm, o.Generation)
				if valid && inv.FrontendCertificateWarnings[listenerKey(g, l)] {
					condition(&s.Conditions, "lightedge.blaize.net/FrontendCertificateHostnameMismatch", meta.ConditionTrue, "ClientValidationRequired", "The configured frontend certificate does not cover every listener/route hostname; clients must authenticate it", o.Generation)
				} else if valid {
					metaapi.RemoveStatusCondition(&s.Conditions, "lightedge.blaize.net/FrontendCertificateHostnameMismatch")
				}
				o.Status.Listeners = append(o.Status.Listeners, s)
			}
			return &o.Status
		}))
	}
	parents := map[string][]RouteParent{}
	for _, p := range inv.Parents {
		key := p.Route.Namespace + "/" + p.Route.Name
		parents[key] = append(parents[key], p)
	}
	routes := map[string]gw.HTTPRoute{}
	for _, p := range inv.Parents {
		routes[p.Route.Namespace+"/"+p.Route.Name] = p.Route
	}
	if valid && applied {
		for _, route := range inv.Routes {
			for _, p := range route.Status.Parents {
				if string(p.ControllerName) == r.Config.ControllerName && r.Config.OwnsGateway(string(ptr(p.ParentRef.Namespace, gw.Namespace(route.Namespace)))+"/"+string(p.ParentRef.Name)) {
					routes[route.Namespace+"/"+route.Name] = route
				}
			}
		}
	}
	for key, route := range routes {
		selected := parents[key]
		record(updateStatus[gw.HTTPRoute](ctx, r.Client, HTTPRouteGVR, &route, func(o *gw.HTTPRoute) any {
			out := []gw.RouteParentStatus{}
			previous := o.Status.Parents
			for _, p := range previous {
				if string(p.ControllerName) != r.Config.ControllerName || !r.Config.OwnsGateway(string(ptr(p.ParentRef.Namespace, gw.Namespace(o.Namespace)))+"/"+string(p.ParentRef.Name)) {
					out = append(out, p)
				} else if !valid {
					found := false
					for _, item := range selected {
						if reflect.DeepEqual(item.Parent, p.ParentRef) {
							found = true
						}
					}
					if !found {
						out = append(out, p)
					}
				}
			}
			for _, item := range selected {
				s := gw.RouteParentStatus{ParentRef: item.Parent, ControllerName: gw.GatewayController(r.Config.ControllerName)}
				for _, old := range previous {
					if old.ControllerName == s.ControllerName && reflect.DeepEqual(old.ParentRef, s.ParentRef) {
						s = old
						break
					}
				}
				accepted, resolved := meta.ConditionTrue, meta.ConditionTrue
				ar, am := "Accepted", "Route accepted"
				rr, rm := "ResolvedRefs", "Backend references resolved"
				if !valid {
					accepted, resolved = meta.ConditionFalse, meta.ConditionUnknown
					ar, am = "Pending", "Snapshot validation did not complete"
					rr, rm = "Pending", "References not confirmed"
				}
				if valid && item.RejectedReason != "" {
					accepted = meta.ConditionFalse
					ar = item.RejectedReason
					am = "No permitted matching listener"
				}
				if valid && item.RefReason != "" {
					resolved = meta.ConditionFalse
					rr = item.RefReason
					rm = "One or more backend references are invalid"
				}
				condition(&s.Conditions, "Accepted", accepted, ar, am, o.Generation)
				condition(&s.Conditions, "ResolvedRefs", resolved, rr, rm, o.Generation)
				programmed := meta.ConditionFalse
				pr, pm := "Pending", "LightEdge has not confirmed desired state"
				if applied && item.RejectedReason == "" {
					programmed = meta.ConditionTrue
					pr, pm = "Programmed", "LightEdge applied desired state"
				}
				condition(&s.Conditions, "Programmed", programmed, pr, pm, o.Generation)
				out = append(out, s)
			}
			sort.SliceStable(out, func(i, j int) bool {
				return fmt.Sprint(out[i].ControllerName, out[i].ParentRef.Name) < fmt.Sprint(out[j].ControllerName, out[j].ParentRef.Name)
			})
			o.Status.Parents = out
			return &o.Status
		}))
	}
	record(r.reportExtraRoutes(ctx, inv, valid, applied))
	record(r.reportBackendTLS(ctx, inv.backendTLS, valid, applied))
	if r.Config.Scope == nil {
		record(r.ReportPolicies(ctx, inv, valid, applied))
	}
	return first
}
func (r Reader) ReportPolicies(ctx context.Context, inv Inventory, valid, applied bool) error {
	var first error
	record := func(err error) {
		if err != nil && first == nil {
			first = err
		}
	}
	for _, p := range inv.Policies {
		record(updateStatus[NativePolicy](ctx, r.Client, policyGVR, &p, func(o *NativePolicy) any {
			status, reason, message := meta.ConditionFalse, "Pending", "Policy is not confirmed by LightEdge"
			if applied {
				status, reason, message = meta.ConditionTrue, "Accepted", "Policy applied by LightEdge"
			}
			if !valid {
				reason, message = "InvalidSnapshot", "Desired configuration did not validate"
			}
			if valid && inv.PolicyErrors[p.Namespace+"/"+p.Name] != "" {
				status = meta.ConditionFalse
				reason = inv.PolicyErrors[p.Namespace+"/"+p.Name]
				message = "Policy rejected; target route not programmed"
			} else if valid && p.Spec.TargetRef.Kind == "Gateway" {
				key := p.Namespace + "/" + p.Spec.TargetRef.Name
				accepted := false
				for _, g := range inv.Gateways {
					if g.Namespace+"/"+g.Name == key && inv.GatewayErrors[key] == "" {
						accepted = true
					}
				}
				if !accepted {
					status = meta.ConditionFalse
					reason = "TargetNotAccepted"
					message = "Gateway target is not accepted"
				}
			} else if valid {
				attached := false
				for _, parent := range inv.Parents {
					if parent.Route.Namespace == p.Namespace && parent.Route.Name == p.Spec.TargetRef.Name && parent.RejectedReason == "" {
						attached = true
					}
				}
				if !attached {
					status = meta.ConditionFalse
					reason = "TargetNotAccepted"
					message = "Target route is not accepted"
				}
			}
			condition(&o.Status.Conditions, "Accepted", status, reason, message, o.Generation)
			return &o.Status
		}))
	}
	return first
}
