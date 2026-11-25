# Shared WAF rules

The stock CRS route path uses a per-NGINX-configuration-cycle cache of
parsed rule objects rather than parsing the full CRS for every protected
location. This includes multiple HTTP and HTTPS listeners for a site and
Kubernetes-managed HTTP/gRPC routes. The cache is lazy: no protected
location means no compiled CRS. Raw TCP, UDP and TLS passthrough remain
in the stream module and never instantiate HTTP WAF rules.

## Render and activation

`render-nginx.sh` produces a common `waf-routes/_shared-crs.conf` and
small per-location `*.local.conf` files. Local files contain the route's
paranoia controls, site/profile exclusions and, for gRPC only, the
narrow application/grpc content-type exception. Each protected location
has its own ModSecurity RulesSet and transaction properties; it loads
the local file and explicitly merges the common rules using
`modsecurity_rules_file_shared`. The connector patch uses libModSecurity's
existing shared rule-object merge API. The cache belongs to NGINX's
HTTP configuration pool, not to a global daemon or persistent storage.
Each validation and reload gets a new cache, and existing workers retain
their old generation until retirement. Standard `modsecurity_rules_file`
and parent/child inheritance are not changed.

The renderer also generates the original complete route file so
existing raw/manual references continue to work. All files are inside
the already-snapshotted waf-routes tree. No changes to the immutable
snapshot, pointer publication, transaction journal, HA locking, shared
revision or reload acknowledgement protocols are required.

The existing paranoia control variable names are retained exactly for
behavioral compatibility. CRS 4 uses blocking/detection variables;
the spike also tested switching those names, but that changed PL2
response filtering and broke the existing provider error contract.
Correcting CRS 4 paranoia semantics requires a separately qualified
policy migration and is not part of this memory-only change.

## Compatibility path

Arbitrary plugin rule order, custom rule actions/updates, non-stock
CRS initialization, and manually edited or imported NGINX files may
depend on parsing the complete policy in its original order. These
continue using the original per-location full-rule path. An enabled
global custom rule causes all generated routes to take that path,
because it can interact with route controls. Other generated routes
can share while a selected plugin route uses a full policy. Disabling
a global custom rule restores sharing automatically. This is intentional
rather than silently dropping rules or changing plugin ordering.
Memory reduction will be lower on installations relying on these
compatibility cases. Further policy-aware pooling is separate work.

## Build and regression

The native NGINX connector is built from the existing pinned commit
with `build/patches/modsecurity-nginx-shared-rules.patch`; rebuild the
native archive and appliance image together. The new directive is
not available in an old native binary. The native package and Docker
builds reject an archive lacking the shared directive. The old
runtime's unpatched directives remain supported. The native build
manifest records the connector patch SHA256.

Run `bash tests/test-shared-waf-rules.sh IMAGE` to validate cache reuse,
route/site isolation, global custom fallback and removal, plugin order,
PL1–4 and WAF-off. The three-VM QEMU matrix also collects per-worker
MemAvailable, anonymous memory and per-NGINX-process PSS/private memory
samples every five seconds. The existing functional tests remain
unchanged. The controlled spike's prior 12-route benchmark reduced
NGINX PSS from 427 MiB to 53 MiB; exact results for the integrated
implementation must come from its own test run.

## Integrated qualification (2026-11-24)

The active feature worktree's integrated image passed the one-cache/
eleven-hit twelve-context test, five consecutive updates, route-local
exclusions, plugin and global custom-rule compatibility fallback,
WAF-disabled routing, and shared/legacy HTTP-status parity across all
four configured paranoia levels. The sampled combined NGINX PSS after
five updates was about 46 MiB versus 476 MiB in the earlier original
architecture benchmark. The regression enforces a conservative 192 MiB
PSS ceiling for this fixture.

Fresh QEMU/KVM qualification at one vCPU and 1536 MiB per worker
(2048 MiB control plane) passed all 39 positive phase/case combinations,
both negative checks and the matching signed revision on rejoin.
Minimum sampled available memory was 902/894 MiB; peak sampled NGINX
PSS was 105/93 MiB. Host and guest exit codes were zero. The unchanged
harness recorded two five-second timeouts while polling a route update
with one appliance absent. Do not claim zero-downtime reconfiguration.
At 1024 MiB per worker, all baseline protocols and invalid-route
recovery passed with minimum sampled available memory of 378/393 MiB,
but an immediate post-scale-down request timed out (exit 28).
The 1 GiB full regression remains unqualified; this was not another
observed memory exhaustion. The underlying readiness/failover timing
requires separate work.

All test environments were removed. Native release rebuilding and
hosted CI qualification remain pending. Existing configuration snapshot,
reload, provider transaction and HA implementation files were verified
byte-for-byte unchanged.
