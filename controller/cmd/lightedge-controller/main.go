package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/theonemule/docker-waf/controller/internal/kube"
	"github.com/theonemule/docker-waf/controller/internal/provider"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/dynamic"
	coordination "k8s.io/client-go/kubernetes/typed/coordination/v1"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/tools/leaderelection"
	"k8s.io/client-go/tools/leaderelection/resourcelock"
)

type partitionResult[T any] struct {
	index int
	value T
}

// Preserve concrete validation errors over generic pending/attachment status,
// independent of the order in which appliance partitions finish.
func mergePolicyError(dst map[string]string, key, reason string) {
	rank := func(v string) int {
		switch v {
		case "":
			return 0
		case "Pending":
			return 1
		case "TargetNotAccepted":
			return 2
		default:
			return 3
		}
	}
	old := dst[key]
	if rank(reason) > rank(old) || rank(reason) == rank(old) && reason < old {
		dst[key] = reason
	}
}
func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
func run() error {
	var cfg kube.Config
	var endpoint, providerID, token, ca, kubeconfig, addresses, namespace, identity, lease, health string
	var interval time.Duration
	var once bool
	var targetsFile, partitionsFile, extraHTTPPorts, extraHTTPSPorts, extraTCPPorts, extraUDPPorts, extraTLSPorts string
	flag.StringVar(&partitionsFile, "partitions-file", "", "operator JSON file mapping Gateways to independent appliance addresses")
	flag.StringVar(&targetsFile, "targets-file", "", "administrator JSON file for replicated appliance targets")
	flag.StringVar(&endpoint, "provider-url", "", "LightEdge HTTPS management origin")
	flag.StringVar(&providerID, "provider-id", "", "provider identity")
	flag.StringVar(&token, "token-file", "/credentials/token", "mounted bearer token file")
	flag.StringVar(&ca, "ca-file", "", "trusted management CA PEM")
	flag.StringVar(&kubeconfig, "kubeconfig", "", "optional kubeconfig, defaults to in-cluster")
	flag.StringVar(&cfg.ControllerName, "controller-name", "blaize.net/lightedge-controller", "controller identity")
	flag.StringVar(&cfg.IngressClass, "ingress-class", "lightedge", "managed IngressClass")
	flag.StringVar(&cfg.GatewayClass, "gateway-class", "lightedge", "managed GatewayClass")
	flag.BoolVar(&cfg.Ingress, "enable-ingress", true, "reconcile Ingress")
	flag.BoolVar(&cfg.IngressWildcard, "ingress-wildcard", false, "allow single-label Ingress wildcard hosts (requires provider authorization)")
	flag.BoolVar(&cfg.IngressCatchAll, "ingress-catch-all", false, "allow hostless Ingress/defaultBackend on a dedicated provider")

	flag.BoolVar(&cfg.Gateway, "enable-gateway", true, "reconcile Gateway API")
	flag.BoolVar(&cfg.GRPC, "enable-grpc", false, "enable GRPCRoute v1")
	flag.StringVar(&extraTCPPorts, "extra-tcp-ports", "", "operator provisioned public TCP ports")
	flag.StringVar(&extraUDPPorts, "extra-udp-ports", "", "operator provisioned public UDP ports")
	flag.StringVar(&extraTLSPorts, "extra-tls-ports", "", "operator provisioned public TLS passthrough ports")
	flag.StringVar(&extraHTTPSPorts, "extra-https-ports", "", "comma-separated operator-provisioned additional public HTTPS ports")
	flag.StringVar(&extraHTTPPorts, "extra-http-ports", "", "comma-separated operator-provisioned additional public HTTP ports")
	flag.BoolVar(&cfg.GatewayClientValidatedFrontend, "gateway-client-validated-frontend", false, "serve explicitly configured frontend certificates; clients authenticate DNS identity; provider must separately authorize")
	flag.BoolVar(&cfg.GatewayCatchAllHTTPS, "gateway-catch-all-https", false, "allow terminating hostname-less HTTPS Gateway listeners (dedicated provider authorization required)")
	flag.BoolVar(&cfg.Policies, "enable-policies", false, "watch LightEdgePolicy CRD")
	flag.StringVar(&cfg.BackendMode, "backend-mode", "clusterip", "clusterip, nodeport, loadbalancer")
	flag.StringVar(&cfg.NodeAddress, "node-address", "", "reachable node IPv4 address")
	flag.StringVar(&addresses, "addresses", "", "comma-separated public appliance addresses")
	flag.StringVar(&namespace, "lease-namespace", "lightedge-system", "leader election namespace")
	flag.StringVar(&identity, "identity", os.Getenv("HOSTNAME"), "unique pod identity")
	flag.StringVar(&lease, "lease-name", "lightedge-controller", "leader lease name")
	flag.StringVar(&health, "health-address", ":8081", "health and metrics endpoint")
	flag.DurationVar(&interval, "interval", 5*time.Second, "full reconciliation interval")
	flag.BoolVar(&once, "once", false, "run one reconciliation without leader election (test/manual)")
	flag.Parse()
	if !cfg.Ingress && !cfg.Gateway {
		return fmt.Errorf("at least one resource API must be enabled")
	}
	if cfg.Policies && !cfg.Gateway {
		return fmt.Errorf("policy CRD requires Gateway API")
	}
	if interval < time.Second {
		return fmt.Errorf("interval must be at least one second")
	}
	for _, v := range strings.Split(addresses, ",") {
		if v = strings.TrimSpace(v); v != "" {
			cfg.Addresses = append(cfg.Addresses, v)
		}
	}
	if extraHTTPPorts != "" {
		for _, v := range strings.Split(extraHTTPPorts, ",") {
			n, err := strconv.Atoi(v)
			if err != nil {
				return fmt.Errorf("invalid extra HTTP port")
			}
			cfg.ExtraHTTPPorts = append(cfg.ExtraHTTPPorts, n)
		}
		if err := provider.ValidateExtraHTTPPorts(cfg.ExtraHTTPPorts); err != nil {
			return err
		}
	}
	if extraHTTPSPorts != "" {
		for _, v := range strings.Split(extraHTTPSPorts, ",") {
			n, err := strconv.Atoi(v)
			if err != nil {
				return fmt.Errorf("invalid extra HTTPS port")
			}
			cfg.ExtraHTTPSPorts = append(cfg.ExtraHTTPSPorts, n)
		}
	}
	if err := provider.ValidateExtraHTTPPorts(append(append([]int{}, cfg.ExtraHTTPPorts...), cfg.ExtraHTTPSPorts...)); err != nil {
		return err
	}
	cfg.StreamPorts = map[string][]int{}
	for protocol, value := range map[string]string{"tcp": extraTCPPorts, "udp": extraUDPPorts, "tls": extraTLSPorts} {
		if value != "" {
			for _, v := range strings.Split(value, ",") {
				n, e := strconv.Atoi(v)
				if e != nil {
					return fmt.Errorf("invalid transport port")
				}
				cfg.StreamPorts[protocol] = append(cfg.StreamPorts[protocol], n)
			}
		}
	}
	if err := provider.ValidateTransportPorts(cfg.StreamPorts, cfg.ExtraHTTPPorts, cfg.ExtraHTTPSPorts); err != nil {
		return err
	}
	var partitions []provider.Partition
	var targets []provider.Target
	var err error
	if partitionsFile != "" {
		if targetsFile != "" || endpoint != "" || providerID != "" || addresses != "" || extraHTTPPorts != "" || extraHTTPSPorts != "" || extraTCPPorts != "" || extraUDPPorts != "" || extraTLSPorts != "" {
			return fmt.Errorf("partitions-file is mutually exclusive with provider/targets/address flags")
		}
		partitions, err = provider.LoadPartitions(partitionsFile)
	} else if targetsFile != "" {
		if endpoint != "" || providerID != "" {
			return fmt.Errorf("targets-file and single provider flags are mutually exclusive")
		}
		targets, err = provider.LoadTargets(targetsFile)
	} else {
		var p *provider.Client
		p, err = provider.New(endpoint, providerID, token, ca)
		targets = []provider.Target{{Name: "default", Client: p}}
	}
	if err != nil {
		return err
	}
	var rc *rest.Config
	if kubeconfig != "" {
		rc, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
	} else {
		rc, err = rest.InClusterConfig()
	}
	if err != nil {
		return err
	}
	rc.Timeout = 30 * time.Second
	if len(partitions) > 1 {
		// Each partition reads the same discovery inventory. Keep a bounded
		// aggregate budget while preventing serialized default-QPS delays.
		rc.QPS = 20
		rc.Burst = 40
	}
	dc, err := dynamic.NewForConfig(rc)
	if err != nil {
		return err
	}
	type workPartition struct {
		name    string
		reader  kube.Reader
		targets []provider.Target
	}
	work := []workPartition{}
	reader := kube.Reader{Client: dc, Config: cfg}
	if partitionsFile == "" {
		work = append(work, workPartition{"default", reader, targets})
	} else {
		assigned := map[string]bool{}
		for _, p := range partitions {
			for _, g := range p.Gateways {
				assigned[g] = true
			}
		}
		for _, p := range partitions {
			c := cfg
			c.Addresses = p.Addresses
			c.ExtraHTTPPorts = p.ExtraHTTPPorts
			c.ExtraHTTPSPorts = p.ExtraHTTPSPorts
			c.StreamPorts = p.StreamPorts
			c.Ingress = cfg.Ingress && p.Default
			own := map[string]bool{}
			for _, g := range p.Gateways {
				own[g] = true
			}
			c.Scope = &kube.GatewayScope{Default: p.Default, Assigned: own, Elsewhere: assigned}
			work = append(work, workPartition{p.Name, kube.Reader{Client: dc, Config: c}, p.Targets})
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var ready, leading, standby atomic.Bool
	var total, failed atomic.Uint64
	reconcile := func(ctx context.Context) error {
		total.Add(1)
		type outcome struct {
			inv            kube.Inventory
			valid, applied bool
			err            error
		}
		completed := make(chan partitionResult[outcome], len(work))
		for i, w := range work {
			go func(i int, w workPartition) {
				var result outcome
				defer func() { completed <- partitionResult[outcome]{i, result} }()
				inv, err := w.reader.Build(ctx)
				if err != nil {
					result = outcome{inv: inv, err: err}
					return
				}
				results, rejected, err := provider.Reconcile(ctx, w.targets, inv.Plan.Snapshot(0))
				inv.ProviderRejected(rejected)
				if len(rejected) > 0 {
					log.Printf("partition %s isolated %d appliance validation failures", w.name, len(rejected))
					for _, item := range rejected {
						log.Printf("partition %s rejected host=%q status=%d field=%q reason=%q", w.name, item.Host, item.Status, item.Field, item.Reason)
					}
				}
				for _, result := range results {
					if result.Err == nil && result.State.Changed {
						log.Printf("partition %s target %s revision %d applied (%d sites)", w.name, result.Name, result.State.Revision, len(result.State.Hosts))
					}
				}
				result = outcome{inv: inv, valid: true, applied: err == nil, err: err}
			}(i, w)
		}
		// Publish status as each partition finishes, instead of waiting for a
		// slow/unreachable appliance. Serialize writes for multi-parent routes.
		combined := kube.Inventory{PolicyErrors: map[string]string{}, GatewayErrors: map[string]string{}}
		seenPolicies := map[string]bool{}
		var errs []error
		for range work {
			finished := <-completed
			o := finished.value
			w := work[finished.index]
			if o.err != nil {
				errs = append(errs, fmt.Errorf("partition %s: %w", w.name, o.err))
			}
			if err := w.reader.Report(ctx, o.inv, o.valid, o.applied); err != nil {
				errs = append(errs, fmt.Errorf("partition %s status: %w", w.name, err))
			}
			if partitionsFile == "" {
				continue
			}
			combined.Parents = append(combined.Parents, o.inv.Parents...)
			combined.Gateways = append(combined.Gateways, o.inv.Gateways...)
			for k, v := range o.inv.GatewayErrors {
				combined.GatewayErrors[k] = v
			}
			for _, p := range o.inv.Policies {
				key := p.Namespace + "/" + p.Name
				if !seenPolicies[key] {
					combined.Policies = append(combined.Policies, p)
					seenPolicies[key] = true
				}
				if reason := o.inv.PolicyErrors[key]; reason != "" {
					mergePolicyError(combined.PolicyErrors, key, reason)
				} else if !o.valid || !o.applied {
					mergePolicyError(combined.PolicyErrors, key, "Pending")
				}
				for _, parent := range o.inv.Parents {
					if p.Spec.TargetRef.Kind == "HTTPRoute" && parent.Route.Namespace == p.Namespace && parent.Route.Name == p.Spec.TargetRef.Name && parent.RejectedReason != "" {
						mergePolicyError(combined.PolicyErrors, key, "TargetNotAccepted")
					}
				}
			}
		}
		if partitionsFile != "" {
			if err := reader.ReportPolicies(ctx, combined, true, true); err != nil {
				errs = append(errs, err)
			}
		}
		err := errors.Join(errs...)
		ready.Store(err == nil)
		if err != nil {
			failed.Add(1)
		}
		return err
	}

	if once {
		return reconcile(ctx)
	}
	if identity == "" {
		return fmt.Errorf("leader identity is required")
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200); fmt.Fprintln(w, "ok") })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		if (leading.Load() && !ready.Load()) || (!leading.Load() && !standby.Load()) {
			w.WriteHeader(503)
			return
		}
		if leading.Load() {
			fmt.Fprintln(w, "leader ready")
		} else {
			fmt.Fprintln(w, "standby ready")
		}
	})
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		if leading.Load() {
			fmt.Fprintln(w, "lightedge_controller_leader 1")
		} else {
			fmt.Fprintln(w, "lightedge_controller_leader 0")
		}
		fmt.Fprintf(w, "lightedge_reconciliations_total %d\nlightedge_reconciliation_failures_total %d\n", total.Load(), failed.Load())
	})
	server := &http.Server{Addr: health, Handler: mux, ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 16 << 10}
	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("health server: %v", err)
			stop()
		}
	}()
	defer server.Close()
	cc, err := coordination.NewForConfig(rc)
	if err != nil {
		return err
	}
	lock := &resourcelock.LeaseLock{LeaseMeta: meta.ObjectMeta{Namespace: namespace, Name: lease}, Client: cc, LockConfig: resourcelock.ResourceLockConfig{Identity: identity}}
	leaderelection.RunOrDie(ctx, leaderelection.LeaderElectionConfig{
		Lock: lock, LeaseDuration: 30 * time.Second, RenewDeadline: 20 * time.Second, RetryPeriod: 5 * time.Second, ReleaseOnCancel: false,
		Callbacks: leaderelection.LeaderCallbacks{
			OnStartedLeading: func(ctx context.Context) {
				leading.Store(true)
				standby.Store(false)
				log.Print("leader acquired")
				wait := interval
				for ctx.Err() == nil {
					if err := reconcile(ctx); err != nil {
						log.Printf("reconcile failed: %v", err)
						wait = min(wait*2, time.Minute)
					} else {
						wait = interval
					}
					timer := time.NewTimer(wait)
					select {
					case <-ctx.Done():
						timer.Stop()
						return
					case <-timer.C:
					}
				}
			},
			OnNewLeader: func(current string) {
				standby.Store(current != "" && current != identity)
			},
			OnStoppedLeading: func() { ready.Store(false); leading.Store(false); standby.Store(false); stop() },
		},
	})
	return nil
}
