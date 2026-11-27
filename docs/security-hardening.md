# Management and firewall security hardening

Baseline: qualified commit 01a8df3136d350a947cfa0acc85f728dddf5934a.
This change is a targeted source review and regression-tested hardening pass,
not an independent penetration test or a guarantee of absence of vulnerabilities.

## Changes and compatibility

* Browser mutations, including retained legacy form endpoints, reject foreign
  origins and cross-site/same-site fetch metadata. API clients must send
  X-LiteEdge-API: 1. Legacy forms can instead supply a matching Origin.
  Malformed and repeated parameters (including query/body collisions) are
  rejected; URL-encoded forms are limited to 4 MiB and 256 fields.
* Provider CGI rejects invalid method, HTTPS, credential format, media type,
  size and JSON before the writer lock; standalone tokens are authenticated
  before and inside the lock. HA authenticates against synchronized state,
  deliberately preserving token rotation consistency.
* SPA and static assets inherit security headers and no-store, and have
  a separate per-client authentication rate limit (60/minute, burst 40).
* Generated HTTP/gRPC proxy routes replace incoming forwarding identity
  headers with gateway-derived values and remove RFC Forwarded. Legacy
  X-header configuration cannot override protected forwarding headers.
  Static roots cannot escape the permitted document directories via
  traversal or existing symlinks. Host length and numeric timeouts are bounded.
* Site, WAF, CRS, and plugin archives use one streaming extractor. Reject
  traversal, duplicate names, links, sparse and special files, excessive
  member counts or decompression, and oversized tar metadata. Full backup
  restore separately permits validated internal symlinks and retains
  manifest integrity checks and transactional rollback.
* Bootstrap administrator passwords are not passed as OpenSSL arguments or
  inherited by runtime child processes. Docker metadata still contains
  environment-supplied credentials; restrict access to the Docker daemon.
* Log CSV exports neutralize spreadsheet formula prefixes, including leading
  whitespace/control characters.

### Proxies and client identity

Default: trust no incoming client-IP claims. If LightEdge is behind an actual
trusted reverse proxy or load balancer that supplies X-Forwarded-For, explicitly
set LITEEDGE_TRUSTED_PROXY_CIDRS to its source address(es) or narrowly scoped
CIDRs (comma-separated). Compose passes this setting through. Helm uses
appliance.trustedProxyCIDRs (an array). Do not configure entire client networks.
All-address /0 entries, hostnames and invalid CIDRs are rejected.
NGINX recursive real-IP processing then selects the last untrusted hop, which
is used by allowlists, rate limits, logs and the generated backend headers.
The upstream proxy must sanitize its incoming client identity headers.
Directly imported, operator-authored NGINX directives remain privileged
configuration and can override the generated policy; review those separately.

### Remaining security work

* Legacy manually configured HTTPS upstreams do not universally verify
  certificates. Migrate them to explicit verified backend TLS; enabling
  verification indiscriminately would break self-signed/internal services.
* Provider DNS-suffix authorization does not constrain the eventual resolved
  addresses. Use scoped IP backends for untrusted providers and plan a
  resolution-time network policy.
* Controller cross-namespace TLS Secret reads are part of its current
  functionality. Consider namespace-scoped deployments and RBAC in a separate
  change. Appliance service account token mounting is disabled.
* HA uses signed revisions and rollback checks, but its shared storage,
  signing secret and administrators must remain trusted. Raw NGINX editing,
  custom ModSecurity rules and complete backup restoration are administrator
  privileges, not untrusted multi-tenant interfaces.
* Pin and verify runtime-downloaded rule/plugin provenance; bounded archive
  extraction does not authenticate the rules themselves. Add dependency,
  container, static analysis, and API fuzz/security testing to release
  qualification. Complete deeper review of controller reconciliation and
  resource exhaustion behavior.

## Verification in this pass

Local Python regression suites: 31 provider, 11 HA, 5 NGINX generation and
4 input security tests; installer/password/API contract checks.
Isolated container integration using the prior qualified runtime plus edited
source: 113 SPA/API assertions, 147 legacy HTTP API assertions, route
protections including forged and trusted proxy forwarding, full backup and
restore. These are not a new source-build or three-pass qualification.
Production release remains unchanged.

## Second iteration: egress, provenance, and qualification

Provider DNS authorization now requires BOTH an approved DNS suffix and a
permitted IPv4 CIDR. The appliance resolves once per distinct hostname per
snapshot (at most 16 names, two seconds per lookup), rejects the entire answer
set if any address falls outside policy, and pins one deterministic address.
Explicit IP pools remain the way to request multiple weighted endpoints.
Primary, mirror and per-peer TLS targets all use the pinned IP; TLS identities
remain the configured DNS SANs. Older persisted provider DNS routes return
503 and skip health probes and pool resolution until the controller resubmits
an authorized snapshot. Network-level egress policy is still recommended:
CIDRs must exclude infrastructure and management destinations; pinning does
not replace proper network segmentation.

Generated legacy HTTPS routes now verify the system CA bundle and backend
identity by default. Explicit per-route CA/identity remains preferred for
internal services. Temporary migration escape hatch:
LITEEDGE_ALLOW_UNVERIFIED_BACKEND_TLS=1 (Compose or native environment) or
appliance.allowUnverifiedBackendTLS=true (Helm). This does not weaken explicit
verified TLS routes. Imported administrator-authored raw NGINX snippets
remain privileged and must be reviewed independently. Explicit controller
CA files now replace, rather than extend, the public trust store.

Official CRS updates download the named minimal release asset and require
its GitHub-published SHA-256 digest before extraction or installation.
Plugin installations resolve a branch to a commit, fetch that commit's
archive, check its expected root and record commit and archive digest.
For independently approved plugins, mount a read-only allowlist and set
LITEEDGE_PLUGIN_DIGEST_FILE to it; each line contains repository, commit and
SHA-256 separated by single spaces. A missing or nonmatching entry rejects
installation. GitHub metadata and TLS alone are not independent publisher
signature verification; local administrator-supplied archives remain trusted
administrative input.

Set controller.secretNamespaces to the actual namespaces holding TLS
Secrets to remove cluster-wide Secret get permission. Empty retains the
previous cluster-wide permission for compatibility. The controller health
server now bounds read/write/header/idle resources. Admin NGINX limits
concurrent connections per client and versioned form uploads to 4 MiB.
Both shared and node-local configuration locks have bounded contention waits
and reject symlink/nonregular lock files. Local timeout defaults to 60s
(LITEEDGE_LOCAL_LOCK_TIMEOUT_SECONDS); shared timeout remains configurable.
Hard filesystem stalls and authorized long-running operations still require
operator resource limits and storage monitoring.

The canonical pipeline gates on Go source vulnerability checks and bounded
fuzzing, then scans tracked source and the exact two built images using a
SHA-256-pinned Trivy executable. Detected secrets and fixable HIGH/CRITICAL
findings block the build. Unfixed vulnerabilities remain in reports, not
silently discarded. Scan infrastructure failures fail closed. Reports remove secret match text and snippets and are retained seven days; manually compiled native dependencies also require
ongoing version/advisory review (package scans do not prove complete coverage).
The feature/security-hardening branch uses the existing three-pass wrapper;
no candidate release is published.

The initial Trivy scan detected fixable zlib and OpenSSL package advisories below the high/critical threshold. Both runtime Dockerfiles explicitly upgrade base packages from their supported signed Alpine repositories before installation.

Live migration regression: a real Docker DNS alias resolved into an authorized
IP, the provider persisted only the IP, the route forwarded HTTP successfully,
a simulated legacy DNS record returned 503, and a fresh reconciliation restored
traffic. A resolvable name in the approved DNS suffix but outside the permitted
IP scope was rejected without changing the active route. Shared HA tests also
passed on the updated runtime, including CAS, interrupted-writer recovery,
signed revision restoration and retention.
