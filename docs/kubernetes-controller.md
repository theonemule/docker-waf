# LightEdge Kubernetes controller 1.0

The separate Go controller translates Kubernetes resources to the scoped
LightEdge provider API. The appliance owns and renders all NGINX configuration;
the controller never mounts configuration directories or writes NGINX files.
The release pair is appliance v3.3.0 and controller v1.0.0. Until the stable artifacts are published, build compatible images from the same feature branch before using the chart.

## Quick start

Install the Gateway API v1.4.0 standard CRDs when Gateway support is enabled.
Use a trusted management certificate with a DNS SAN matching the provider URL.
Do not expose the management listener publicly.

For an external appliance, create a random bearer token (at least 32 random
bytes encoded as hex), store its SHA-256 hash in a restricted
`/data/providers/cluster-a.json` on the appliance, and retain the token in
a Kubernetes Secret. Example policy (replace the hash and scopes):

```json
{
  "token_sha256": "<SHA-256 of token without newline>",
  "host_suffixes": ["apps.example.com"],
  "backend_cidrs": ["10.96.0.0/12"],
  "min_waf_pl": 1
}
```

Use restrictive host suffixes and backend CIDRs. DNS backends are opt-in via
`backend_dns_suffixes`; only trust DNS zones under your control. The appliance
must be able to reach selected backend addresses. Use separate credentials and
non-overlapping host scopes for each cluster.

Create namespace and Secret using files so token contents are not embedded in
shell command arguments. The example assumes the token file contains the
original token and the CA file verifies the appliance certificate.

```sh
kubectl create namespace lightedge-system
kubectl -n lightedge-system create secret generic lightedge-provider \
  --from-file=token=./provider-token --from-file=ca.crt=./management-ca.crt
helm upgrade --install lightedge deploy/kubernetes/helm/lightedge \
  -n lightedge-system --set provider.url=https://edge.example.com:9443 \
  --set image.repository=lightedge-controller --set image.tag=kubernetes-dev \
  --set controller.backendMode=clusterip --set controller.enablePolicies=true
```

Build the controller with `docker build -t lightedge-controller:kubernetes-dev controller`;
make the image available to the cluster. For an embedded appliance set
`appliance.enabled=true`, `appliance.image=liteedge:kubernetes-dev` (or a
compatible registry image), and select appropriate storage and public Service
type. The provider Secret must additionally contain `provider.json`. Create
`lightedge-admin` (key `password`) and `lightedge-admin-tls` (Kubernetes TLS
Secret). The certificate SAN must match the management Service FQDN
`<release>-lightedge-appliance.<namespace>.svc` for the release name; inspect the rendered chart for the actual Service name. Keep
`ca.crt` in the provider Secret consistent with that certificate.
Chart 1.0.0 pins the matching appliance v3.3.0 and controller v1.0.0 registry tags; use explicit local candidate tags until the release is published.

Use `deploy/kubernetes/examples/` for example Ingress, Gateway/HTTPRoute and
LightEdgePolicy manifests; adjust host names, services and class names.
Set `controller.addresses` to real public appliance addresses for resource
status reporting. For external appliances, `nodeport` requires a reachable
nodeAddress and does not support externalTrafficPolicy Local; `loadbalancer`
uses an assigned Service address. The default `clusterip` requires Service
CIDR connectivity. The controller polls complete inventories periodically,
elects a leader using a Lease and retains the last accepted snapshot if
discovery or validation fails. Managed sites are read-only in the appliance UI.
Controller readiness distinguishes a standby observing a leader from the active
leader that has successfully reconciled. Helm allows one unavailable controller
during upgrades to avoid a lease/readiness deadlock; existing appliance traffic
continues using the last successful configuration.

## Upgrade an existing Kubernetes installation

Back up the appliance state and, if enabled, the shared HA configuration and
all associated PVCs. Keep the same Helm release name, namespace, provider
Secret, HMAC Secret, storage claims, listener mappings, and topology. Upgrade
external appliances with the pinned 3.3.0 upgrader before upgrading their
controller. For the embedded mode, Helm replaces the appliance init and main
containers with the same pinned image.

After v3.3.0 is published, download `lightedge-1.0.0.tgz` and
`chart.sha256` from that release and verify the chart. Reapply your saved
operator values and explicitly select the new image pair:

```sh
helm upgrade lightedge ./lightedge-1.0.0.tgz -n lightedge-system \
  --reuse-values --set image.tag=v1.0.0 \
  --set appliance.image=ghcr.io/theonemule/docker-waf:v3.3.0 \
  --wait --timeout 10m
```

Use your existing release name and namespace. Do not switch a Deployment
into HA StatefulSet mode or change storage topology as part of this version
upgrade. Confirm controller readiness, Gateway and route conditions, matching
HA revisions and real traffic; a successful Helm rollout alone is not enough.
Use `helm rollback` with the previous revision and restore the matching
persistent configuration backup if an incompatible state change occurred.
Do not assume zero-downtime upgrades.

## Support and limits

- Ingress: explicit class, concrete hostnames, exact and segment-aware prefix
  paths, Service backends, TLS Secrets. Missing or invalid Service references return HTTP 500 on the affected path. Single-label wildcard hosts, hostless rules and defaultBackend are opt-in (see below). ImplementationSpecific paths remain unsupported.
- Gateway API: GatewayClass, Gateway and HTTPRoute, HTTP/HTTPS termination,
  explicit DNS hosts, operator-authorized wildcard hosts and dedicated HTTP catch-all, exact/segment-prefix path matching, exact literal header
  matching and HTTP method matching, Service backend weights, listener
  attachment rules, namespace selectors, ReferenceGrant and basic status.
  RequestHeaderModifier and ResponseHeaderModifier support restricted X-header set/add/remove. Response operations cannot alter the appliance security headers. RequestRedirect supports hostname, scheme, port, status 301/302/303/307/308, full-path and prefix-path replacement. URLRewrite supports full-path/prefix-path replacement and upstream Host replacement. Queries are preserved; exact case-sensitive query matching accepts unreserved literals. Redirect and rewrite hostnames are restricted to operator-approved DNS suffixes. Arbitrary headers, regex/encoded query matching,
  full official conformance and additional optional features remain unverified. See the additional protocol support below. Hostname-less HTTPS is an explicit opt-in. Distinct Gateways can be assigned to independent operator-provisioned partitions. Invalid backend references retain their configured weight and return HTTP 500; denied listener attachments and invalid references report individual status conditions. More-specific reserved listeners return 404 rather than falling through to broad listeners. Overlapping Gateway host scopes on a shared appliance listener are rejected. Overlapping HTTPRoute host patterns within the same listener inherit broader matching rules into narrower vhosts, while listeners remain isolated. Invalid more-specific HTTPS listener reservations reject TLS handshakes rather than fall back to a wildcard certificate.
  Conditional routing evaluates original route-host specificity, path specificity, method, header count, query count,
  creation order and namespace/name; the selected native route still enforces
  WAF, allowlists and rate limits.
- LightEdgePolicy and Ingress annotations: WAF paranoia level, request rate,
  maximum body size, IP allowlists and health checks. The appliance enforces
  minimum WAF level; disabling WAF via provider is not allowed. Gateway and HTTPRoute policy
  Accepted status follows appliance confirmation; conflicting or invalid policies withdraw the affected route and report rejected policy/route conditions.
  An operator may define named profiles in the provider policy and set a default
  profile. Application owners can select only approved names (not arbitrary
  plugins, exclusions or directives).
- Provider API: bounded snapshots, version conflicts, ownership isolation,
  configuration lock, validated render/reload with private generation-specific acknowledgment and rollback; identical
  snapshots are no-ops. Manual sites remain outside controller ownership.
  Bulk site import is blocked while provider-managed sites exist. Remove
  managed sites through the owning provider rather than deleting its policy.
  Protect and back up /data including credentials and private keys.
- Multi-cluster: independent providers and class/controller identities can
  share an appliance with disjoint host scopes. A single controller can replicate
  the same snapshot to up to 16 explicitly configured appliances using
  independent TLS credentials and revisions. Healthy targets converge during
  a peer outage; the controller reports incomplete programming until every
  target confirms. This is not distributed atomic commit, VIP failover or
  data-plane HA.

## Approved security profiles

Optional provider policy fields:

```json
{
  "min_waf_pl": 1,
  "default_waf_profile": "strict",
  "waf_profiles": {
    "strict": {"min_waf_pl": 2}
  },
  "redirect_host_suffixes": ["apps.example.com"]
}
```

Profiles may contain operator-approved installed plugin names and numeric
disabled_rules; the appliance validates the minimum paranoia level and
never accepts raw rules from Kubernetes. Select with
`spec.waf.profile` on LightEdgePolicy or the Ingress annotation
`lightedge.blaize.net/waf-profile`. Omitted profile uses the operator default.
An unapproved profile or weaker paranoia level is attributed to the source policy/route where possible and the affected route is quarantined; unclassified failures still reject the snapshot. Gateway policies provide inherited defaults. Same-namespace HTTPRoute policies may override them subject to the mandatory provider floor. Cross-namespace routes cannot weaken inherited WAF level or rate limits, or replace inherited profile, maximum body size or IP allowlist. They may strengthen WAF/rate limits and override health settings.

## Wildcard and catch-all authorization

Set `allow_wildcards: true` on the appliance-side provider policy to permit
`*.suffix` sites, only within the configured `host_suffixes`. Gateway wildcards match
subdomains, including multiple DNS labels, but not the bare suffix. The
appliance requires an exact wildcard SAN for wildcard TLS (client certificate
validation still follows ordinary TLS wildcard rules).

Set `allow_catch_all: true` only for a dedicated appliance/provider that
is intended to serve every unmatched HTTP hostname. This explicitly overrides
hostname suffix restrictions for the catch-all. It is rejected if any other
owner or manual site exists; other providers and manual sites cannot take
over its hostname scope. Catch-all HTTPS requires both provider `allow_catch_all_tls: true` and controller `gatewayCatchAllHTTPS: true` (`--gateway-catch-all-https`); the client still verifies certificate coverage of its requested name. SAN matching is exact or single-label wildcard, consistent with the Go controller; CN alone is not accepted. Distinct HTTP
and HTTPS listener reservations prevent an HTTP-only listener from shadowing
a wildcard HTTPS listener. Managed requests preserve the original Host
header and port.

For Ingress, enable `controller.ingressWildcard=true` (CLI
`--ingress-wildcard=true`) **and** provider `allow_wildcards: true`.
Ingress wildcards match exactly one DNS label, including when using an
appropriate wildcard TLS Secret. Enable `controller.ingressCatchAll=true`
(CLI `--ingress-catch-all=true`) **and** provider `allow_catch_all: true`
for a dedicated HTTP catch-all. A defaultBackend fills otherwise-unmatched
Ingress paths and unmatched HTTP hostnames. Gateway-owned vhosts remain
separate; the Ingress fallback does not fill unmatched paths in a Gateway
vhost. Conflicting catch-all roots and overlapping wildcard modes are
rejected rather than silently merged. Both controller options default off.

Invalid Service references are represented internally by a fixed local
HTTP 500 endpoint, not an arbitrary upstream. The configured backend weights
are preserved, and healthy Services continue receiving their share of traffic.
Missing or unauthorized references set HTTPRoute ResolvedRefs=False, while
a rejected parent has Accepted=False. Transport or inventory read errors
continue to preserve the last successful snapshot. Unsupported rule/filter or malformed TLS resources are rejected individually; the controller does not commit partially translated rules. Missing Ingress Services use the same fixed HTTP 500 endpoint. Other Ingress semantic errors withdraw the invalid Ingress and clear its published load-balancer status. Provider authorization and transactional validation remain final gates. POST preflight at the same provider state endpoint validates without writing and returns bounded site/route rejection coordinates. The controller quarantines attributable route failures at their original predicates with a local 500 backend, then validates and commits the remaining snapshot. Unclassified, transport, CAS and runtime failures are not pruned. Unauthorized or conflicting sites are omitted, rather than taking another owner’s hostname. An unreachable replica retains its last good revision.

## Shared-source appliance HA (preferred for one HA group)

LightEdge HA uses the existing native configuration files as its common
authority, not a database. A shared filesystem holds immutable signed
revisions; each appliance reads and renders them into its own runtime.
Use the single management Service/provider endpoint for the group.
See [Shared configuration HA](shared-configuration-ha.md) for membership,
HMAC trust, locking, storage requirements, Helm settings and limitations.

## Independent multi-appliance replication

Create an existing Kubernetes Secret containing targets.json and each
appliance's independent token and CA PEM. Example targets.json:

```json
[
  {"name":"primary","url":"https://edge-a.example.com:9443","provider_id":"cluster-a","token_file":"/credentials/token-a","ca_file":"/credentials/ca-a.crt"},
  {"name":"secondary","url":"https://edge-b.example.com:9443","provider_id":"cluster-a","token_file":"/credentials/token-b","ca_file":"/credentials/ca-b.crt"}
]
```

Set `provider.targetsSecret` to its name in Helm, or use
`--targets-file=/credentials/targets.json` directly. This is mutually exclusive
with the chart's bundled-appliance provisioning. Both appliances must be able
to reach the backend addresses and enforce compatible scopes and profiles.
An external health-aware load balancer or VIP is needed for client-facing
traffic failover; controller replication does not implement that function.

The independent-target regression uses two independent appliances, CA-verified management
connections, independent credentials and an external NGINX passive-failover
load balancer. It verifies initial replication, GET traffic during an appliance
outage, configuration updates on the surviving appliance, and the recovered
appliance catching up without reloading the unchanged peer:

```sh
docker build --target builder -t lightedge-controller:ci-builder controller
bash tests/test-multi-appliance-ha.sh liteedge:kubernetes-dev lightedge-controller:ci-builder
```

Production traffic failover requires a separately provisioned front end
with stable appliance addresses. The test front end is not a packaged HA
service. Passive failure detection and graceful draining of prior NGINX workers can expose
an old snapshot briefly during recovery; use active health/readiness checks
and gate re-admission on data-plane convergence where that matters.
Do not assume retries are safe for non-idempotent requests. Distributed
atomic snapshots, a managed VIP, and automated stale-target admission
remain outside the current implementation.


## Independent Gateway partitions

For overlapping hostnames on separate public addresses, provision distinct
appliances or shared-source HA groups, then create a Secret containing
`partitions.json` and their CA/token files. Example:

```json
[
  {"name":"default","default":true,"addresses":["192.0.2.10"],"targets":[{"name":"primary","url":"https://edge-a.example.com:9443","provider_id":"cluster-a","token_file":"/credentials/token-a","ca_file":"/credentials/ca-a.crt"}]},
  {"name":"payments","gateways":["payments/public"],"addresses":["192.0.2.20"],"targets":[{"name":"payments","url":"https://edge-b.example.com:9443","provider_id":"cluster-b","token_file":"/credentials/token-b","ca_file":"/credentials/ca-b.crt"}]}
]
```

Set `provider.partitionsSecret` or `--partitions-file=/credentials/partitions.json`.
This is exclusive of bundled appliance provisioning and targetsSecret.
Exactly one default handles Ingress and unassigned Gateways. Each named
Gateway is assigned once; addresses and appliance management origins must
be distinct across partitions. Each partition has independent reconciliation
and status; a failed partition does not prevent another from updating.
The controller does not create load balancers, provision appliances, move
existing ownership automatically or bind additional IPs on a single appliance.
The two-appliance kind regression exercises identical hostnames, independent
traffic, shared route attachments, outage recovery and deletion.

## Provider administration

In Server Settings > Kubernetes providers, an administrator can inspect
provider IDs, scopes, revisions and owned hosts, create credentials,
rotate tokens, or edit/delete a drained provider. Policy changes and
deletion are refused while any site is owned, including actual site
records independently of the revision inventory. Tokens are never returned.
Rotation changes the hash immediately, preserving existing routes; update
the corresponding controller Secret. The same locked native source is
published through shared-file HA. See [SPA API](spa-api.md).
For credential or authorization changes initiated outside the admin API,
follow the same drain and rotation rules.

## Verification

Run provider unit tests with `python3 tests/test-provider.py`, the real
appliance test with `bash tests/test-provider-integration.sh IMAGE`, and
controller tests with `cd controller && go test -mod=readonly ./...`.
The kind smoke test uses disposable images and a newly created cluster; it
does not use the current kubectl context. See the controller CI workflow.
Do not interpret smoke tests as Kubernetes Gateway API conformance.


### Upstream Gateway API conformance (experimental)

The unmodified official Gateway API v1.4.0 test binary has a separate image
and disposable-cluster harness:

```sh
docker build -t lightedge-conformance:v1.4.0 controller/conformance
bash tests/test-gateway-conformance-kind.sh liteedge:kubernetes-dev \
  lightedge-controller:kubernetes-dev lightedge-conformance:v1.4.0 \
  HTTPRouteSimpleSameNamespace
```

Omit the final test name to run the entire upstream GATEWAY-HTTP profile.
The harness creates and deletes its own kind cluster, installs the pinned
standard CRDs, and advertises the appliance's cluster Service IP as its
Gateway address. It does not access the user's current Kubernetes context.
The upstream HTTPRouteSimpleSameNamespace, HTTPRouteMatchingAcrossRoutes,
HTTPRouteInvalidReferenceGrant, HTTPRouteQueryParamMatching,
HTTPRouteResponseHeaderModifier and HTTPRouteHTTPSListener cases have passed in isolated development
kind clusters. The matching-across-routes and response-header cases each
verified eight request assertions; query matching verified 19. The
response-header case also exercises combined request/response modifiers. The HTTPS listener case verifies both explicit host routes, hostname-less TLS fallback and unknown-host HTTP 404, with client verification of the fixture certificate. Selected upstream tests are diagnostic only; full conformance
and a published report remain release gates. The listener-kind, hostname-intersection, single-mirror, multiple-mirror and percentage/fraction-mirror cases also passed a clean focused upstream run. The runner provisions eight independently addressed appliance partitions and assigns the pinned fixture Gateways to them. Full conformance remains unverified; Operator-provisioned additional HTTP and HTTPS listener ports are supported; GRPCRoute and operator-provisioned transport listeners are supported experimentally; their full conformance remains open. The fixture certificate containing a literal asterisk is not accepted for unrelated explicit HTTPS hostnames. Production certificate coverage checks are retained.

### Request mirroring

A provider must explicitly enable `allow_request_mirroring` and authorize each
mirror HTTP origin through its backend CIDR/DNS scope. The native route
`features.mirrors` list accepts up to four distinct destinations with
`target` and `basis_points` (0–10000). Omitted sampling defaults to full
traffic; zero disables a copy. Gateway HTTPRoute RequestMirror percent and
fraction fields translate to hundredths of a percent. Fractions are rounded
to this resolution, preserving nonzero and less-than-full values.

The primary response is authoritative; shadow failures do not replace it.
Mirroring occurs after access/WAF checks, includes the request body, and
applies the typed request-header transformations to primary and shadow.
Mirroring cannot currently be combined with redirects, host/path rewrites,
or legacy request transformations. Missing/denied Kubernetes mirror
references are omitted with ResolvedRefs=False while the primary remains
routable. This is request duplication, not failover; only use it with
authorized destinations and data appropriate for both backends.

The live native test is `tests/test-request-mirroring.sh IMAGE`. In the SPA
route editor use one HTTP origin per line, optionally followed by
` | percentage` (up to two decimal places).


### Additional HTTP and HTTPS listener ports

The standard logical listener keys are `http` (80) and `https` (443),
irrespective of the appliance's internal bind ports. Additional HTTP
listeners use keys such as `http:8080` and `http:8090`. Provision all
additional ports before allowing a Gateway to use them:

- Appliance environment: `LITEEDGE_EXTRA_HTTP_PORTS=8080:18080,8090:18090`.
  Map each public port to a distinct unprivileged local socket. All HA
  members must provision the same public listener keys.
- Embedded Helm appliance: `appliance.extraHTTPPorts` is a list of
  `{port: 8080, targetPort: 18080}` mappings. The public Service exposes
  those additional ports.
- Controller: set `controller.extraHTTPPorts: [8080, 8090]` (CLI
  `--extra-http-ports=8080,8090`), or set `extra_http_ports` on each
  independently provisioned partition in the partitions JSON.
- Provider authorization policy: include `"extra_http_ports":[8080,8090]`.
  The provider must also be authorized for the host and backend. Host
  ownership remains exclusive across all listener ports, not per port.

Unprovisioned, unauthorized, privileged bind, reserved and conflicting ports
are rejected. Native and provider routes use `features.schemes` to select
listener keys. Extra HTTP ports have independent route dispatch, default
404 handling and WAF enforcement. Redirects preserving HTTP preserve the
public listener port unless an explicit redirect port is specified. Drain
routes before removing a port mapping.

For HTTPS, use `LITEEDGE_EXTRA_HTTPS_PORTS=8443:18443`,
`appliance.extraHTTPSPorts: [{port: 8443, targetPort: 18443}]`,
`controller.extraHTTPSPorts: [8443]` (CLI `--extra-https-ports=8443`),
and provider/partition `extra_https_ports: [8443]`. Routes select
`https:8443`. Each managed HTTPS listener has its own certificate and
can reject handshakes independently. Native manual sites reuse their site
certificate on extra HTTPS listeners. HTTP and HTTPS mappings share a
combined 16-extra-port limit and cannot overlap. Unknown HTTPS SNI is
rejected unless an explicitly authorized catch-all listener applies.
The HTTPS port regression is `tests/test-https-listener-ports.sh IMAGE`.
The native test is `tests/test-listener-ports.sh IMAGE`; the pinned upstream
listener-port matching and redirect-port/scheme cases also passed.

### Bounded backend-pool retries

A route may specify `features.retry`, for example
`{"attempts":1,"codes":[502,503,504],"budget_ms":1500}`. Enable
`allow_backend_retries` explicitly in the provider authorization policy.
A positive retry count on the native NGINX fast path requires at least two distinct valid backends.
Attempts count additional tries (0–4), not total requests; zero disables
retries. Supported HTTP retry codes are 429, 500, 502, 503 and 504, in
addition to transport errors/timeouts. The budget is 0–60000 ms; zero
adds no budget limit. The budget limits starting subsequent attempts,
not the duration of the entire request. NGINX does not replay a sent
POST/PATCH/LOCK request. Missing retry configuration retains native defaults.

The controller translates the supported subset of HTTPRoute retry settings,
including millisecond backoff up to 60 seconds. Positive single-backend
retries are supported when a deadline or positive backoff selects the
appliance-local deadline worker. Invalid backend references still cannot
be retried. The fast path retains its NGINX behavior when no deadline or
backoff is configured. The live native test is
`tests/test-backend-retries.sh IMAGE`.

### Absolute request and backend deadlines

The native API accepts `features.deadlines` (provider route field
`deadlines`), e.g. `{"request_ms":2000,"backend_ms":250}`. The Gateway
API controller maps `rules.timeouts.request` and `backendRequest` to
integer milliseconds. Explicit positive durations are bounded to one
hour; zero selects that maximum, and omitted fields use 60 seconds in
the deadline worker. A positive backend deadline cannot exceed an
explicit positive request deadline. `retry.backoff_ms` (0–60000) maps
Gateway API `retry.backoff`. Providers must explicitly enable
`allow_request_deadlines` and, for positive retries, the existing
`allow_backend_retries` flag.

NGINX remains the public listener and performs routing, WAF, IP/rate/body
controls and transformations before forwarding to a mode-0600 Unix socket
in the private runtime directory. The renderer supplies the immutable
route configuration in a reserved header, overwriting any client value;
the worker strips it before contacting an authorized backend. Ordinary
routes do not use the worker. The worker starts the request budget after
NGINX has buffered the client request body. It bounds each backend
exchange with a cancellable context, and retry delays are included in
the total request budget. Small known-length responses (up to 64 KiB)
are buffered to return 504 before sending headers if the backend expires.
For large or streaming responses, a timeout after headers have been sent
terminates the incomplete stream; HTTP cannot replace an already-sent
status. Slow client delivery after NGINX has received the response is
still subject to native NGINX send-timeout behavior, not this budget.

Deadline-worker retries are limited to bodyless GET, HEAD and OPTIONS.
They use bounded weighted random selection and prefer a different
endpoint when available. The worker allows 256 concurrent exchanges;
excess requests get 503. It uses separate backend connections, no
WebSocket upgrades, no mirroring, no legacy URL rewrites or forced HTTPS,
no alternate native pool algorithms, and only explicit origin URLs.
The worker resolves DNS using the appliance OS resolver, not the NGINX
`LITEEDGE_RESOLVER` override. The ordinary proxy path is unchanged. The worker is independently
supervised and exits when the appliance parent terminates. Its private
response metadata restores the selected backend and attempt count in
the NGINX access log, and is hidden from clients.

Validation: `tests/test-request-deadlines.sh IMAGE`, worker Go unit tests,
and the upstream HTTPRouteTimeoutRequest and HTTPRouteTimeoutBackendRequest
cases (both passed, including zero timeout). This does not certify the
whole optional retry feature or long-stream/client-delivery semantics.

Attachment counts and programming status are distinct: a permitted parent
attachment is counted even when the listener or route cannot be programmed.
Unconfigured GatewayClasses naming this controller are explicitly rejected
rather than silently adopted. Use a distinct controller identity for an
independently managed installation with a different class. Primary and
mirror backend reference resolution is independent of listener programming.
Completed partition results are reported
without waiting for every other appliance to finish reconciliation.


### Verified backend TLS (Gateway API v1)

Enable `allow_backend_tls: true` in the appliance's provider authorization
policy, in addition to its existing backend CIDR/DNS scopes. TLS-required
backends must use HTTPS origins with explicit ports. Configure a native
route with `features.backend_tls`, or a provider route with the top-level
`backend_tls` object containing `hostname` and `ca_certificate` (PEM).
NGINX uses TLS 1.2/1.3, sends the configured DNS hostname as SNI and verifies
the peer's certificate and hostname against the supplied CA bundle.

The controller reads Gateway API v1 BackendTLSPolicy resources, targeting
a Service or a named Service port. A port-specific policy overrides a
whole-Service default. The oldest policy in a scope wins, with lexical
name as the tie-breaker. The accepted policy must reference one same-
namespace core ConfigMap containing `ca.crt` (up to eight distinct CA
certificates, at most 32 KiB). The controller reports Accepted and
ResolvedRefs per Gateway ancestor and observes policy generation and
ConfigMap changes. Missing or invalid CA references fail the affected
route rule closed with a local HTTP 500; a failed upstream TLS handshake
normally returns HTTP 502. A valid policy never falls back to plaintext
when verification fails. CA rotation uses the native transactional
configuration path and generated trust-bundle drift is repaired.

Uniform verified TLS pools retain the native NGINX fast path. Mixed
HTTP/HTTPS pools and distinct TLS identities use the private worker, with
`backend_tls_peers` keyed by exact HTTPS origin; each value contains
`hostname` and `ca_certificate`. No HTTPS peer may be missing its
explicit trust, no unused trust entry is accepted, and uniform and
per-peer modes are mutually exclusive. Per-peer trust JSON is bounded to
40 KB combined; individual CA bundles remain bounded to 32 KiB. Plaintext
peers are intentional, separately authorized HTTP origins. A failed
handshake returns 502 for that peer, never a plaintext downgrade.
If policy discovery or selection is invalid or two Service references
resolve to the same socket with incompatible TLS identities, the affected
rule fails closed rather than merging ambiguous trust. Empty TLS pools
reserve the match with 503. Verified TLS mirroring, additional SAN types,
system trust and mTLS are not supported. Active HTTPS health probes use
the same explicit CA and SNI identity for each endpoint.
The controller falls back to v1alpha3 discovery only when v1 is absent,
never on authorization or transient API errors. Earlier schemas are unsupported. Existing manual single-backend HTTPS
routes retain their previous behavior unless verified backend TLS is
explicitly configured. Policy ancestor reporting is currently bounded to
the API's 16-entry limit. The controller calculates class-wide allocations
across partitions, preserves existing foreign entries and fails excess
attachments closed. Concurrent changes by independent controllers still
require operational qualification.

Validation: `tests/test-backend-tls.sh IMAGE`,
`tests/test-backend-tls-peers.sh IMAGE` and
`tests/test-gateway-backend-tls-kind.sh IMAGE CONTROLLER_IMAGE`.
The pinned v1.4.0 upstream BackendTLSPolicy, InvalidCACertificateRef,
InvalidKind and ObservedGenerationBump cases pass. The upstream conflict
case uses an unserved v1alpha3 fixture with the pinned v1 CRDs; the native
Kubernetes lifecycle regression covers v1 conflict selection instead.
The focused HTTPRouteHeaderMatching, HTTPRouteMatching, HTTPRoutePathMatchOrder,
HTTPRouteRedirectHostAndStatus, HTTPRouteServiceTypes and HTTPRouteWeight cases
also pass on the phase36 development images. Full core conformance remains
pending: the GatewayModifyListeners fixture
uses a certificate without a SAN covering its configured hostname.
Do not weaken production certificate verification to accommodate it.


### Headless Services and EndpointSlices

In clusterip mode, a headless Service resolves its named or unnamed
Service port through namespace-local IPv4 EndpointSlices. Ready,
non-terminating endpoints with valid TCP ports are deduplicated and
sorted. Endpoints with stale Service ownership are ignored. Ordinary
ClusterIP Services continue through the Service virtual IP. Operators
must explicitly include the reachable Pod network in provider backend
CIDR scopes; this does not expand authorization automatically.

Each Service's configured route weight is distributed across its ready
endpoints, preserving service-level ratios where representable. A valid
Service with no usable endpoints returns local HTTP 503, without falling
through to a broader route. A missing or invalid Service reference
returns HTTP 500. API discovery errors preserve the previous snapshot.
The current pool limit is 16 distinct targets per route; oversized
pools are rejected rather than truncated. Direct headless resolution
in nodeport/loadbalancer mode, IPv6 endpoints, and multi-endpoint
headless mirrors are not supported.


## Additional protocols: GRPCRoute, TCPRoute, UDPRoute, TLSRoute

Install the pinned v1.4.0 experimental Gateway API CRDs for TCPRoute,
UDPRoute and TLSRoute (v1alpha2). GRPCRoute is v1. Use the stream-enabled
appliance build and matching controller. The following Helm values enable
gRPC and provision dedicated transport ports in embedded mode:

```yaml
controller:
  enableGRPC: true
  extraTCPPorts: [9000]
  extraUDPPorts: [9001]
  extraTLSPorts: [9444]
appliance:
  enabled: true
  extraTCPPorts:
    - {port: 9000, targetPort: 19000}
  extraUDPPorts:
    - {port: 9001, targetPort: 19001}
  extraTLSPorts:
    - {port: 9444, targetPort: 19444}
```

For external appliances, set the corresponding environment variables
`LITEEDGE_EXTRA_TCP_PORTS=9000:19000`,
`LITEEDGE_EXTRA_UDP_PORTS=9001:19001`, and
`LITEEDGE_EXTRA_TLS_PORTS=9444:19444`, and publish the corresponding
container ports (including /udp for UDP). Match controller flags
`--enable-grpc=true`, `--extra-tcp-ports=9000`,
`--extra-udp-ports=9001`, and `--extra-tls-ports=9444`.
Independent partitions specify their own transport port sets in
`stream_ports`. Update all appliances in a partition before enabling the
features. Transport sockets have exclusive Gateway/provider ownership.

Extend the scoped provider policy with explicit authorization:

```json
{
  "allow_grpc": true,
  "allow_stream": true,
  "stream_ports": {"tcp":[9000],"udp":[9001],"tls":[9444]},
  "host_suffixes":["apps.example.com"],
  "backend_cidrs":["10.96.0.0/12"],
  "allow_wildcards":true
}
```

The example omits the existing required credential hash. Limit host
and backend scopes to the operator's actual networks. SNI catch-all
requires the separate allow_catch_all_tls authorization.

GRPCRoute supports HTTP/2 cleartext and HTTPS frontend termination, exact
service/method and literal metadata matching, weighted backend selection,
restricted X-header modifiers, and per-parent status. The native HTTP WAF
remains enabled; the gRPC content-type exception does not turn the WAF off.
This does not establish semantic inspection of protobuf payloads or full
bidirectional-streaming compatibility. gRPC-specific health probes,
method-only or regex matches, mirroring, persistence, HTTP-only retry/
deadline/rewrites, and conflicting HTTPRoute/GRPCRoute hostname claims
are not supported. Native gRPC accepts a uniform verified TLS upstream;
the Kubernetes gRPC translator rejects backend references with
BackendTLSPolicy until verified gRPC policy integration is complete.

TCPRoute and UDPRoute select weighted Service backends with matching
transport protocols. TLSRoute uses a TLS listener with mode Passthrough;
the appliance reads ClientHello SNI and forwards encrypted bytes unchanged.
Backend servers own certificates and TLS termination. Unknown or missing
SNI is rejected unless an explicitly authorized nonempty-SNI catch-all
matches. Specific SNI names win over broader wildcards. Conflicting
or invalid TLS listener configuration withdraws the affected shared socket
rather than falling through to a broad hostname. A rejected provider
transport route withdraws its entire port while preserving other ports
and HTTP routes. Cross-namespace backend references require kind-specific
ReferenceGrant permissions.

The initial transport implementation reserves standard ports 80, 443
and the admin port 9443 for existing HTTP/HTTPS/admin use, and does not
share numeric ports across protocols. Use separate operator-provisioned
ports; mixed termination/passthrough on the same port is not supported.
Machine provider transport backends are scoped IPv4 addresses; native
administrators may also use DNS names. Layer-4 traffic does not enter
ModSecurity and cannot enforce HTTP-specific LightEdgePolicy controls;
such attachments are rejected. Connection timeout is 5s, TCP/TLS idle
timeout 10m, UDP idle timeout 30s. Transport access records are written
to /data/logs/streams.jsonl and rotated; integration into HTTP analytics
and alerts is not yet provided.

Validation: tests/test-grpc.sh and tests/test-stream-routes.sh run real
native forwarding; tests/test-extra-routes-kind.sh exercises all four
Kubernetes kinds, cross-namespace permission grant/revocation and
backend protocol mismatch. Four unmodified upstream v1.4.0 gRPC cases
(GRPCExactMethodMatching, GRPCRouteHeaderMatching,
GRPCRouteListenerHostnameMatching, GRPCRouteWeight) passed. These are
focused cases, not a published conformance report.


## Frontend certificate policy and core conformance

The default controller/provider policy requires DNS SAN coverage for each
configured frontend listener and intersected route hostname. Gateway API
also permits controllers to serve an explicitly referenced frontend
certificate without checking its DNS SAN coverage at configuration time;
clients still perform normal TLS server authentication. For this
interoperability mode, set both:

```yaml
controller:
  gatewayClientValidatedFrontend: true
```

and `"allow_client_validated_frontend": true` in the appliance
provider's authorization policy. The controller CLI flag is
`--gateway-client-validated-frontend=true`. A certificate hostname
mismatch is recorded in the listener condition
`lightedge.blaize.net/FrontendCertificateHostnameMismatch`. The
certificate must still be currently valid, parse correctly, and match
its private key; Secret reference authorization, hostname ownership,
SNI routing, WAF enforcement and upstream CA/hostname verification
are unchanged. This is not a client trust bypass. Clients that
authenticate a mismatched certificate will reject the connection.
Ingress remains strict in the controller. Prefer strict mode for
production unless the operator explicitly requires interoperability.

The upstream v1.4.0 GatewayModifyListeners fixture references a
certificate that does not cover secure.test.com. Strict mode rejects
it as intended. The unfiltered core profiles are qualified with the
operator-selected client-validated frontend mode, not a modified fixture
or a test-name exception. Run the unmodified tests as follows:

```sh
CONFORMANCE_CLIENT_VALIDATED_FRONTEND=true CONFORMANCE_VERSION=development \
  CONFORMANCE_REPORT=/tmp/http.yaml bash tests/test-gateway-conformance-kind.sh \
  liteedge:dev lightedge-controller:dev lightedge-conformance:v1.4.0
CONFORMANCE_CLIENT_VALIDATED_FRONTEND=true CONFORMANCE_VERSION=development \
  CONFORMANCE_GRPC=true CONFORMANCE_PROFILE=GATEWAY-GRPC \
  CONFORMANCE_FEATURES=Gateway,GRPCRoute,ReferenceGrant \
  CONFORMANCE_REPORT=/tmp/grpc.yaml bash tests/test-gateway-conformance-kind.sh \
  liteedge:dev lightedge-controller:dev lightedge-conformance:v1.4.0
```

The phase51 development runs passed all 33 HTTP core cases and all 13
gRPC core cases, with zero failed or skipped core tests. The complete
release gate checks the upstream report's profile, version, mode and
statistics. Optional extended features and experimental TCP/UDP/TLS
profiles are not certified by these two core reports.
