package kube

import (
	"github.com/theonemule/docker-waf/controller/internal/provider"
	gw "sigs.k8s.io/gateway-api/apis/v1"
)

// Report the resource whose requested action was rejected, not its healthy
// neighbours. Route programming is false even though its fail-closed
// placeholder is installed.
func (inv *Inventory) ProviderRejected(rejections []provider.RejectedResource) {
	for _, rejection := range rejections {
		if rejection.PolicyKey != "" {
			inv.PolicyErrors[rejection.PolicyKey] = "InvalidPolicy"
		}
		for _, origin := range rejection.Origins {
			switch origin.Kind {
			case "Ingress":
				inv.IngressErrors[origin.Key] = "ProviderRejected"
			case "HTTPRoute":
				if inv.backendTLS != nil {
					for pk := range inv.backendTLS.routePolicies[origin.Key+"|"+origin.Gateway] {
						d := inv.backendTLS.statuses[pk][origin.Gateway]
						if d.AcceptedReason == "" {
							d.AcceptedReason = "Invalid"
							inv.backendTLS.statuses[pk][origin.Gateway] = d
						}
					}
				}
				for i := range inv.Parents {
					p := &inv.Parents[i]
					if p.Route.Namespace+"/"+p.Route.Name != origin.Key {
						continue
					}
					parent := string(ptr(p.Parent.Namespace, gw.Namespace(p.Route.Namespace))) + "/" + string(p.Parent.Name)
					if parent == origin.Gateway {
						p.RejectedReason = "UnsupportedValue"
					}
				}
			case "GRPCRoute", "TCPRoute", "UDPRoute", "TLSRoute":
				for i := range inv.ExtraParents {
					p := &inv.ExtraParents[i]
					if p.Route.Kind != origin.Kind || p.Route.Namespace+"/"+p.Route.Name != origin.Key {
						continue
					}
					parent := string(ptr(p.Parent.Namespace, gw.Namespace(p.Route.Namespace))) + "/" + string(p.Parent.Name)
					if parent == origin.Gateway {
						p.RejectedReason = "UnsupportedValue"
					}
				}
			case "Listener":
				inv.ListenerErrors[origin.Key+"/"+origin.Listener] = ListenerFailure{Reason: "UnsupportedValue"}
			}
		}
	}
	// Attachment counts are independent of programming rejection.
	for _, g := range inv.Gateways {
		key := g.Namespace + "/" + g.Name
		good := false
		for _, l := range g.Spec.Listeners {
			if inv.ListenerErrors[listenerKey(g, l)].Reason == "" {
				good = true
				break
			}
		}
		if !good {
			inv.GatewayErrors[key] = "ListenersNotValid"
		}
	}
}
