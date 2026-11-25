# Proposed phase: LightEdge Kubernetes Controller

Status: proposed architecture, not implemented. The repository currently calls
the appliance LiteEdge in API headers, paths and product internals; retain those
existing contracts. This phase adds a separate controller to the same project,
not a fork or replacement of the NGINX data plane.

## Decision

Implement one small Go controller using controller-runtime/client-go and the
upstream Gateway API Go types. Support standard networking.k8s.io/v1 Ingress
and gateway.networking.k8s.io/v1 GatewayClass, Gateway and HTTPRoute with
separate adapters converging on one internal desired-state model. Use a
domain-owned controller name such as blaize.net/lightedge-controller (proposed)
for both IngressClass.spec.controller and GatewayClass.spec.controllerName.
Use class name lightedge in examples; only handle explicitly selected classes
initially. Do not copy ingress-nginx's NGINX templating, config snippets or
annotation semantics wholesale. Reuse upstream Kubernetes libraries, tests,
and compatible licensed reconciliation patterns instead.

Controller watches Kubernetes resources, validates relationships, resolves
backends and certificates, translates supported features and calls the
LightEdge management API over authenticated HTTPS. LightEdge owns persistence,
NGINX generation, WAF policy enforcement, TLS, health checks, configuration
validation, reload, logs and OTLP. The appliance never needs Kubernetes
credentials. Both existing UI-managed sites and controller-managed sites are
visible through LightEdge, with source/ownership and applied status.

## Existing code and constraints

- cgi/api.sh exposes site/route inventory and dispatches mutation actions to
  cgi/admin.sh. docs/spa-api.md describes Basic Auth, X-LiteEdge-API: 1 and
  URL-encoded mutations. Existing API is not a batch reconciliation contract.
- bin/sitectl.sh snapshots site state and invokes bin/render-nginx.sh followed
  by reload per mutation. Preserve its validation and rollback semantics;
  refactor into a shared transaction path rather than scripting sequential
  individual API actions for production. Certificate and manual mutations
  must share the same writer serialization boundary.
- Existing routes have exact/prefix/regex, single targets and pools (up to 16
  HTTP endpoints), WAF CRS settings, request method allowlists, rewrites,
  static X-headers, rate and body limits, allowlists, timeout and HTTPS redirect
  settings. These are useful primitives but not equivalent to every Gateway
  API match/filter/weight requirement. Hostname is the current site key.
- An unrelated, uncommitted fault-isolation change is in progress; integrate
  with its final status/rollback contract only after that change is verified.
  A successful API response alone must not imply a quarantined site is active.

## Deployment and network reachability

1. External appliance (primary on-prem scenario): controller Deployment inside
   cluster uses a private appliance management URL, cluster-specific identity
   and CA. Public client traffic reaches appliance on 80/443. Route to
   explicitly reachable Service LoadBalancer addresses, NodePort on approved
   reachable nodes, or routed Service/Pod CIDRs if actually available. Do not
   send cluster DNS or ClusterIP to an external appliance by default. Prefer a
   stable reachable Service address rather than endpoint churn. NodePort
   requires configured node address selection, network/health and
   externalTrafficPolicy awareness. Do not provision cloud LBs by default.
2. In-cluster appliance: separately deployed LightEdge with persistent
   configuration storage and a public Service (LoadBalancer via existing
   cloud/bare-metal implementation, or NodePort). Controller reaches private
   management Service; appliance routes to cluster Service DNS/ClusterIP.
   Appliance is still sole configuration owner. Begin with one data-plane
   instance; HA replication is a later explicit design, not assumed.
3. Optional later multi-appliance targets/HA. A GatewayClass parametersRef
   (implementation-specific configuration) or controller target config maps
   Gateway to a preconfigured appliance, reachable addresses and allowed
   listeners. Initial static appliance supports HTTP/HTTPS on 80/443; reject
   unsupported ports/listener combinations and conflicting claims explicitly.
   Gateway API is not itself a Service LoadBalancer provisioner.

## Proposed API contract (not existing endpoints)

Add scoped machine credentials, separate from unrestricted admin Basic Auth,
with target/cluster authorization and hostname restrictions; verify TLS using
configured CA, support rotation, redact secret payloads, preserve browser CSRF
protections. No raw NGINX, arbitrary admin operations, shell or global WAF
configuration through controller credentials. Allow operator-approved WAF
profiles and upstream network ranges; enforce at API boundary.

- GET /api/v1/providers/{providerId}/state: owned inventory, revision,
  configuration digest, applied/runtime status and capabilities.
- PUT /api/v1/providers/{providerId}/state: complete scoped desired snapshot,
  expected revision (conditional update), deterministic site and route
  identities, TLS references/material and validated policy parameters.
  Provider ID is bound to credential/cluster, not trusted from payload.
- Optional validate-only/dry-run using identical validation with no activation.
- Serialize all configuration writers, stage config and TLS securely,
  validate input and hostname/route collisions, render and test once, reload
  once only on semantic change, persist revision and applied result. A rejected
  update leaves prior accepted config intact; no silent WAF downgrade. Report
  per-object status and explicit failures; define whether site isolation
  rejects the batch or returns partial activation before implementation.
  Distinguish applied generation from desired generation. Retry on conflict
  and temporary API failure with bounded backoff. Guard request size and
  render time, and return actionable errors without credentials.
- Persist ownership by cluster ID, Gateway/Ingress UID and deterministic
  route key; aggregate multiple resources sharing a hostname within the same
  authorized owner. Initially reserve a hostname to one provider, and reject
  conflicts with manual sites and other providers, including aliases and
  wildcard overlap. No automatic takeover. Existing manual sites and
  certificate material must never be deleted by reconciliation. Managed
  routing edits are read-only in UI initially; approved local policy defaults
  are separate from controller desired fields.
- Deletion only from a successfully synced, authoritative snapshot for that
  provider; never treat an API/watch failure as an empty inventory. Retain last
  known good routes during controller outage. A deletion that removes a
  credential/owner requires explicit administrative cleanup. Handle recreated
  resources with new UIDs and retry after restarts. Keep certificate material
  restricted, never echo private keys to state API, events or logs.

## Standards adapters and implementation gaps

Ingress: explicit ingressClassName, HTTP host/path rules, default backend
(where support is verified), exact and segment-aware Prefix semantics, TLS
Secrets and status.loadBalancer.ingress for configured reachable addresses.
Reject unsupported ImplementationSpecific behavior or document precise
semantics. No default catch-all or class-less Ingress takeover implicitly.

Gateway: GatewayClass acceptance, Gateway listeners and HTTPRoute attachment
including parentRefs, sectionName, hostname intersection, allowedRoutes,
namespace selectors and ReferenceGrant for authorized cross-namespace refs.
Implement supported HTTPRoute Core features and correct precedence, including
weighted backendRefs, exact/prefix paths, hostname/wildcards, method/header/
query matching as required by selected version/profile, redirect and header
modification as required. Inventory Core versus Extended requirements from
the pinned upstream conformance suite, not a generic feature checklist.
Reject unsupported optional features with specification-appropriate status;
never silently replace weighted routing with round-robin or header match with
an allowlist. Existing route primitives need extensions for weight, match
precedence, header/query matching, header modifiers, segment-aware prefixes,
listener identity, and invalid backend behavior as applicable. TLS secret
rotation is idempotent; validate certificate/key and references. Start with
HTTP/HTTPS termination; GRPCRoute, TCPRoute, UDPRoute, TLS passthrough and
backend TLS policy were later capabilities, not promised by the initial phase. The subsequent experimental implementation now includes these route kinds, with dedicated transport ports, explicit authorization and native stream rendering; see kubernetes-controller.md for the actual supported subset.

Use observedGeneration and standard conditions including Accepted, Programmed
and ResolvedRefs where specified for each object; status follows confirmed
appliance outcome, not just queued requests. Respect Gateway status ownership
and route parent status isolation. Use upstream conformance tests against
real data-plane HTTP traffic, including negative matches, precedence and
invalid refs. Do not claim conformance until tests pass and report is produced.

## Unified route feature contract

The SPA management API and Kubernetes provider API share a typed route
normalizer and native route records. The provider adapter adds owner, scope,
certificate and minimum-WAF checks before writing. Manual routes expose the
same supported matches, weighted pools, request and response header
operations, redirects and structured rewrites in the SPA. Kubernetes-owned
routes expose their effective read model but cannot be edited from the SPA.
Ingress single-label wildcard sites are distinct from Gateway multi-label
wildcard sites; defaultBackend/hostless Ingress is explicitly opted in for
dedicated catch-all providers. Never accept raw NGINX from the controller.
All sources flow through the native rendering and shared-file HA transaction
boundary; no new database or runtime configuration authority is introduced.

## Native LightEdge policy

Proposed lightedge.blaize.net/v1alpha1 LightEdgePolicy CRD, targeting a
Gateway or HTTPRoute using typed targetRef, with explicit policy precedence,
scope and conflict rules. Support Ingress annotations under a LightEdge-owned
domain for compatibility, not arbitrary snippets. Make WAF enabled by default
for managed applications, with admin-controlled CRS profile, paranoia level,
approved exclusions, CIDRs, rate limiting, body size, timeout and health
monitoring. Security operators control allowed policies and disabling WAF;
application owners cannot bypass mandatory baselines. Invalid policy reports
a condition and does not weaken enforcement. Keep native policies separate
from Gateway API standard fields.

## Proposed repository layout

    controller/
      cmd/lightedge-controller/
      internal/kube/       # watches, class filtering, status, leader election
      internal/ingress/    # adapter
      internal/gateway/    # adapter
      internal/model/      # desired state, ownership and canonical digest
      internal/provider/   # LightEdge API client
      internal/policy/     # native policies and validation
      go.mod
      Dockerfile
    deploy/kubernetes/    # Helm chart, examples, RBAC, tests
    tests/                # appliance API integration/regression tests

Keep controller separately versioned/buildable from appliance release.
Helm deployment uses least-privilege ServiceAccount and RBAC (watch selected
namespaces where practical, restrict Secrets to authorized namespaces; status
patches, leases/events); Gateway API CRDs installed separately from upstream,
version pinned. Credentials mounted from Secret, CA verification required.
Non-root container, readiness/liveness, leader election, rate-limited queue,
debounced full snapshots, metrics and structured logs. Do not rely on local
persistent controller files for reconciliation.

## Implementation sequence and gates

1. Appliance provider API: ownership persistence, scoped credentials,
   serialized transaction, dry-run, idempotence and runtime status. Verify
   collisions, authorization, stale revision, deletion, concurrent admin
   mutations, rollback and secret redaction in disposable appliance tests.
2. Shared controller + baseline Ingress: exact/Prefix, Service routing,
   TLS Secrets, create/update/delete, status and retries. Test controller with
   mock API and kind cluster + real appliance; external and in-cluster
   backend modes. Confirm no reload on unchanged state.
3. Gateway API: static GatewayClass/Gateway and HTTPRoute, implement missing
   Core semantics, ReferenceGrant, allowedRoutes and invalid reference
   behavior; run pinned Gateway API conformance profile and publish results
   only when passing. Test simultaneous Ingress and Gateway classes,
   conflict handling and multiple namespaces.
4. LightEdgePolicy and approved Ingress annotations, policy precedence, WAF
   protections and real blocked/allowed traffic tests.
5. Helm chart, controller image, CI, example Ingress and Gateway manifests,
   operational guides and migration/rollback. Confirm controller outage
   preserves traffic, pod rescheduling/restart is idempotent, cert rotation,
   unavailable API and bad site do not affect unrelated manual sites.
   Add external appliance integration with actual reachable backend topology.
6. Optional follow-up: multi-target/HA, extended Gateway features, additional
   route kinds, compatibility annotation migration tool.

First executable milestone: API-managed isolated test hostname from Ingress
with TLS and WAF; apply/update/delete through Kubernetes only, verify actual
traffic and that unrelated manually managed site survives. Gateway API is
the primary standards target for the full phase, not an optional afterthought.


## Implemented partition and rejection isolation

Explicit operator-assigned Gateway partitions isolate addresses and
snapshots across independent appliances or native shared-file HA groups.
The controller performs non-mutating provider validation, identifies
attributable rule failures by snapshot coordinates, replaces affected
forwarding with a fixed local error while preserving predicates and
priority, and commits only a validated snapshot. Runtime errors and
unattributed failures retain the last-good configuration. Provider
configuration and token rotation share the native configuration lock,
signed source publication and monotonic revision history. Gateway-level
policy inheritance is constrained across namespace trust boundaries.
Automatic appliance provisioning and complete upstream conformance
remain separate release work.
