# LiteEdge SPA and versioned API

Status: deployed SPA with authenticated, versioned API.

## Before and after

The original control plane used CGI-generated HTML for navigation and forms. Although JavaScript intercepted many operations, redirects to new HTML documents remained.

The refactor serves a single static HTML shell at the root URL and uses a dedicated browser client in ui/spa.js. Client navigation changes the fragment route while keeping the same Document instance. The main views are Sites, Site configuration, OWASP, Logs, Alerts and Server Settings. Data comes from structured HTTP API responses, not HTML fragments.

## API contract

The new JSON endpoints are protected read and management resources.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | /api/v1/site-inventory | Fresh hostname, aliases, owner, status, TLS mode and route count; no route file contents |
| GET | /api/v1/site-overview?host=example.com | One site's route summaries and basic TLS/security metadata; no full policies or generated NGINX |
| GET | /api/v1/route-detail?host=example.com&id=... | One route's full configuration and owner |
| GET | /api/v1/site-configuration?host=example.com | Advanced generated/effective configuration, conflict and delta; manual sites only |
| GET | /api/v1/installed-plugins | Installed plugin names and metadata only |
| GET | /api/v1/sites | Full site inventory (legacy contract retained) |
| GET | /api/v1/site?host=example.com | Routes, backends, WAF, TLS metadata and configuration |
| GET | /api/v1/server | Server and sanitized SMTP/export settings |
| GET | /api/v1/provider-admin | HTTPS-only administrator provider inventory (no token/hash) |
| GET | /api/v1/alerts | Alert rules and host/route catalog |
| GET | /api/v1/catalog | Host/alias/route selectors |
| GET | /api/v1/owasp | CRS status, plugin inventory and config, custom rules |
| GET | /api/v1/owasp/rules | CRS rule inventory |
| GET | /api/v1/owasp/crs/check | Check official CRS latest release metadata without downloading/installing |
| GET | /api/v1/logs?type=http&limit=100 | Filtered events |
| GET | /api/v1/logs?scopes_json=... | Filtered events for multiple inventory-validated hosts/aliases/routes |
| GET | /api/v1/logs/export?... | Binary CSV/JSONL download |
| GET | /api/v1/export?... | Binary site/configuration export |
| GET | /api/v1/owasp/export | Binary OWASP export |
| GET | /api/v1/backup/export | Full configuration backup excluding logs (gzip archive) |
| POST | /api/v1/backup/restore | Validated full restore with log preservation and rollback |
| POST | /api/v1/actions/{operation} | Existing validated management mutations |
| POST | /api/v1/import | Binary site configuration import |
| POST | /api/v1/owasp/import | Binary WAF configuration import |
| POST | /api/v1/owasp/crs/import | Binary CRS import |

Mutations accept URL-encoded key/value parameters (Content-Type application/x-www-form-urlencoded) and return JSON success or error with appropriate HTTP status instead of CGI redirects. Import endpoints accept application/octet-stream and return JSON. Archive downloads use JavaScript fetch and a Blob object; they do not navigate away from the application.

The backend still invokes the established Bash control scripts for validation, NGINX testing, application, and rollback. Presentation lives in static JavaScript and never parses CGI-generated markup.

The SPA uses the scoped endpoints for Sites, drill-down, route editing and the Advanced tab. Every request reads the current native files, with no cross-request caching. The legacy full-detail endpoints are unchanged for existing API clients. Site settings are organized into Routes, Hostnames, Certificates, Security and Advanced; Kubernetes-owned sites expose read-only route detail. New routes use a guided purpose/destination/protection/advanced/review wizard; existing routes can be edited in categorized mode or guided mode. Both paths submit the existing validated route mutation API.

## Authentication and security

NGINX requires HTTP Basic authentication for the SPA entry page, static assets, and every API call. It validates the administrator username and password on each request using the existing htpasswd store. The browser maintains its own Basic authentication credentials and automatically supplies Authorization on same-origin fetch requests (credentials same-origin). The UI does not read, persist, or transmit a JavaScript copy of the administrator password. The API does not return password hashes, SMTP passwords, or log-export tokens.

Mutating calls require the X-LiteEdge-API: 1 header and reject cross-site Fetch Metadata and foreign Origin headers. There is no permissive CORS policy. API responses use Cache-Control: no-store. Retained legacy POST form actions must also send the API header or an exact same-origin Origin header. Duplicate parameters and malformed encodings are rejected. Use HTTPS in production. See [security hardening](security-hardening.md) for limits, trusted proxy configuration and deployment considerations.

Changing the administrator password invalidates old cached Basic credentials; a subsequent browser API request prompts for new credentials. Do not embed passwords in URLs or application JavaScript.

## Navigation, imports, and compatibility

The SPA uses fragment routes at /#/sites, /#/site/HOST, /#/owasp, /#/logs, /#/alerts, and /#/server. Normal navigation and saving form state uses fetch and updates the existing DOM. It does not submit native forms, reload the document, or call window.location.assign.

Former management-page GET URLs redirect to the corresponding SPA view. Legacy /admin/* form actions are retained for integration compatibility, but no SPA operation invokes them. The previous HTML interface is available only in disposable regression containers when LITEEDGE_ALLOW_LEGACY_UI=1 is set.

The Logs SPA has searchable checkbox-based multi-select controls for hosts and
aliases, followed by dependent route selections. The selected scopes serialize
into `scopes_json` for both API searches and CSV/JSONL exports. Selections
survive SPA navigation without document reloads; queries remain explicit and
unfiltered queries are rejected. Opening the OWASP page asynchronously GETs
`/api/v1/owasp/crs/check` and updates the current/latest versions in place,
without installing CRS. Manual **Check updates** runs the same GET.

A site may have a 1–16 endpoint backend pool. The SPA edits each URL in its own independently addable/removable row, serializing to the existing target and backends fields when saving.

## Verification and release

Run tests against a locally built image (not the live appliance):

    node tests/test-spa-static.js
    node tests/test-spa-log-filters.js
    bash tests/test-spa-api.sh liteedge:spa-api-qa
    bash tests/test-http-api-regression.sh liteedge:spa-api-qa
    shellcheck -x cgi/*.sh bin/*.sh entrypoint.sh

The new API integration test verifies authentication, JSON contracts, authorization failures, CSRF protections, mutations, secret redaction, binary uploads, API downloads, and legacy compatibility. Existing 147 management endpoint regression assertions still run in their legacy opt-in container.

A Chrome browser test confirmed six SPA views, JSON resource retrieval, and the backend editor interactions without document reloads. The test observed a single document request during navigation.

The live deployment uses the SPA/API. Full configuration backup and restore
is available in **Server Settings** and documented in [full backup and restore](full-backup-restore.md).

## Experimental provider API

GET and PUT /api/v1/providers/{id}/state are available only over management
HTTPS with a provider-scoped Bearer token (not an administrator credential).
GET returns revision, digest and owned hosts. PUT accepts a complete
snapshot containing revision and sites, e.g.:

```json
{"revision":0,"sites":[{"host":"web.apps.example.com","routes":[{"match":"prefix","path":"/","target":"http://10.96.0.20:8080","waf_pl":2}]}]}
```

Routes may instead specify weighted backends (target and weight), schemes,
rate_count, max_body, allow_ips, health, waf_profile, request_headers, response_headers,
header_matches, query_matches, method, precedence, rewrite and redirect. Optional site tls contains the
certificate and private key. Unknown fields are rejected. The submitted
revision must match the current revision; 409 indicates conflict. Omission
removes only sites owned by the authenticated provider. An empty sites
array clears that provider's inventory. Authentication, hostname/backend
scope, TLS, WAF baseline and native NGINX validation are enforced by the
appliance. The API does not expose raw NGINX configuration or private keys.
See [Kubernetes setup](kubernetes-controller.md).

Header matches use exact, case-sensitive literal values and case-insensitive
header names. Header modifications are limited to safe, unprotected X-headers.
A redirect (hostname, scheme, port, status_code, optional path modifier) replaces backends; its
hostname must match an operator-approved suffix. Path replacement may be full or prefix; query strings are preserved. A rewrite can replace the upstream Host and/or path, subject to the same scoped hostname checks. Query matches are case-sensitive, literal unreserved names and values. Native WAF and IP restrictions are evaluated before the redirect.

The site hostname may be a wildcard under an authorized suffix, or `*` for
a dedicated HTTP catch-all provider. The operator must explicitly enable
these capabilities; overlapping other owners are rejected. Optional site
`listeners` declares HTTP/HTTPS listener scope; an empty route list with
explicit listeners reserves a hostname and returns 404. Weighted backends
may use the fixed sentinel `invalid` to return HTTP 500 for an invalid
reference without sending a request to an untrusted network destination.
The fixed `unavailable` sentinel returns local HTTP 503 for a valid
Service with no usable endpoints. Neither sentinel is a network origin.

Managed route snapshots may include a bounded integer `host_priority` (0–1253)
representing the original HTTPRoute hostname specificity. Conditional dispatch
checks this before path/method/header precedence; broader rules are eligible
only after controller listener-scope validation. A site with
`tls_reject: true` must reserve HTTPS without any HTTPS route or certificate;
it installs a native SSL handshake rejection vhost. This prevents a broken
more-specific listener from inheriting a wildcard listener's certificate.
Additional HTTPS ports use `https:<port>` listener keys. A managed site
provides `tls_listeners` keyed by these extra HTTPS listener keys, each
with a certificate/private-key object or null for handshake rejection.
The site read API exposes per-listener certificate status; private keys
are never returned. Manual sites reuse the site certificate.


## Advanced route contract

The native route editor and provider snapshot share the typed route
validator in `bin/route_features.py`. For manual routes, submit the JSON
object as URL-encoded `features_json` on route/add or route/save, with
comma-separated positive `backend_weights` in backend order. The site
read API returns the normalized object as `route.features` and numeric
weights as `route.weights`; these are visible for managed routes but
only manual routes are editable here.

```json
{
  "schemes": ["http", "https"],
  "method": "GET",
  "header_matches": [{"name": "X-Mode", "value": "canary"}],
  "query_matches": [{"name": "version", "value": "two"}],
  "request_headers": [{"op": "set", "name": "X-Upstream", "value": "v2"}],
  "response_headers": [
    {"op": "set", "name": "X-Release", "value": "v2"},
    {"op": "add", "name": "X-Trace", "value": "edge"},
    {"op": "remove", "name": "X-Internal"}
  ],
  "rewrite": {"path": {"type": "prefix", "value": "/v2"}}
}
```

Response operations are restricted to safe X-headers. Set and remove hide
the upstream field; add preserves upstream values and appends a new field.
The appliance's security headers (including HSTS on HTTPS) are preserved.
Protected identity, security and X-Powered-By fields cannot be modified.
The optional site flag `wildcard_single` is a provider-managed hostname
mode for Ingress, not a manual route feature. It is exposed read-only on
the site management API and SPA. Provider authorization still controls
wildcard/catch-all ownership and backend destinations.


## Provider management and validation

The HTTPS-only machine endpoint `/api/v1/providers/{id}/state` supports
GET revision/inventory, POST non-mutating preflight of a proposed snapshot,
and PUT revision-checked transactional apply. Rejection coordinates
`rejection.site_index`, optional `route_index`, `field` and stable
`reason` refer only to the submitted snapshot. Authentication, CAS,
transport and runtime errors are not attributed to individual routes.
The controller can preserve rejected predicates with a local HTTP 500
quarantine, visible as `provider_quarantined` in the managed route model.
The native journal is fsynced before publication; a reload is acknowledged by a worker serving the exact new generation marker on a private node-local Unix socket before the transaction completes. Gracefully draining workers can finish existing requests. Unchanged snapshots
repair detected owned-source or effective-config drift. Provider-managed
sites cannot inherit manual NGINX overrides.

The separate Basic-authenticated HTTPS admin API does not accept provider
Bearer tokens. URL-encoded POST actions require the same CSRF header:

| Action | Fields | Behavior |
| --- | --- | --- |
| provider/save | provider_id, policy_json, provider_token (new only) | Create or update authorization of drained provider |
| provider/rotate | provider_id, provider_token | Replace token; retain sites and revision |
| provider/delete | provider_id | Delete only drained provider; preserve revision tombstone |

Use Server Settings > Kubernetes providers, generate/copy the token into a
secure controller Secret, then save. The inventory exposes only sanitized
authorization policy, ID, revision, owned hosts and credential presence.
Neither plaintext tokens nor hashes are returned. Existing providers with
active sites cannot change scopes or be deleted until drained. All
mutations share the native configuration lock and HA publication.

### Request mirroring

Proxy route features accept `mirrors`: up to four distinct HTTP origins,
each represented by `{"target":"http://shadow:8080","basis_points":2500}`
(25% sampling). A URL string is shorthand for 100%. Use 0 to disable a
destination. Native management and provider snapshots use the same
normalization; provider routes require explicit mirroring permission and
backend scope. Mirrors preserve the request body and typed header
transformations, but never override the primary response. Mirroring is
incompatible with redirects and host/path rewrites.


### Additional listeners and bounded retries

The route editor accepts comma-separated listener keys and serializes them
as `features.schemes` (for example, `["http","http:8080"]`). Additional
ports must already be provisioned by the appliance operator; provider-owned
routes additionally require the public port in `extra_http_ports` policy.
Reserved ports cannot be assigned. The site read model includes provisioned
listener keys in use by its routes.

The route retry editor serializes `features.retry` as an object with
`attempts` (0–4 additional attempts), `codes` (429/500/502/503/504),
and `budget_ms` (0–60000). A missing object preserves the default behavior;
zero attempts disables retry. Fast-path positive counts require multiple distinct
valid backends; deadline-aware routes support retries to a single backend.
Optional `backoff_ms` (0–60000) selects the private deadline worker. Provider routes require `allow_backend_retries`.
The budget limits starting further attempts, not total request duration.
A sent POST/PATCH/LOCK request is not replayed. The native SPA and provider
use the same validation and rendering path.


### Verified HTTPS backends

The route editor accepts a backend DNS identity and PEM CA bundle in
`features.backend_tls`:

```json
{"hostname":"backend.example.test","ca_certificate":"-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n"}
```

Supply HTTPS origins with explicit ports for the primary and all weighted
peers. Each peer uses the same DNS identity for SNI and verification and
the same explicit trust bundle (one to eight distinct CA certificates,
up to 32 KiB). An untrusted certificate or hostname mismatch causes an
upstream TLS failure; the appliance never retries over plaintext.
Provider routes additionally require `allow_backend_tls` and their normal
backend authorization scopes. The provider route object uses the
top-level `backend_tls` field; the native API nests it in `features`.
For distinct identities or a mixed HTTP/HTTPS pool, use
`features.backend_tls_peers` (provider field `backend_tls_peers`) instead
of uniform `backend_tls`, keyed by each exact HTTPS origin. Each value
contains the peer-specific hostname and CA certificate. Every HTTPS peer
must be covered; unused trust entries and conflicting uniform trust are
rejected. Redirects and mirroring cannot be combined with verified TLS. Active health checks use the same explicit CA and SNI identity. Existing manual single-backend HTTPS routes
are not automatically converted to verified TLS.


### Absolute deadlines and backoff

Set `features.deadlines` (top-level provider route field `deadlines`):
`{"request_ms":2000,"backend_ms":250}`. Fields are optional, in integer
milliseconds, bounded 0–3600000; zero selects the one-hour maximum and
blank uses the worker default of 60 seconds. Explicit positive backend
timeout cannot exceed explicit positive request timeout. Providers require
`allow_request_deadlines`. Positive retry attempts still require
`allow_backend_retries`; `backoff_ms` defines the minimum interval between
attempts. The worker counts retry delays toward the total request budget,
and only retries bodyless GET, HEAD and OPTIONS. Deadline and per-peer
TLS routes require explicit origins and weighted round-robin pool mode;
they do not support WebSockets or mirroring. They return 504 before
headers where possible and terminate already-started incomplete streams.
The SPA shows the timing policy, and native access records expose the
selected origin as `upstream_addr` and the attempt count as
`backend_attempts` without exposing internal headers to clients.


## gRPC and layer-4 transport routes

Choose gRPC in the HTTP route editor or set `features.grpc=true` with
`method=POST` in the native route feature object (the provider route
uses the top-level `grpc` field). HTTP origins are forwarded via
gRPC over HTTP/2; HTTPS origins require the uniform verified backend
TLS identity. HTTP-only route transforms, retries, deadlines, mirrors,
query predicates and individual backend trust entries are rejected in
this mode. WAF remains enabled on provider routes.

The management HTTPS API exposes `GET /api/v1/streams` for transport
inventory (including owner and provisioned listener mapping).
`POST /api/v1/actions/stream/save` accepts the URL-encoded field
`streams_json`, a complete replacement JSON array of native routes.
The authenticated Server Settings transport editor uses this API.
Provider-owned rows are read-only. This action shares the existing
configuration lock, validation, reload and rollback transaction;
it does not modify provider ownership. Empty array deletes native routes.

Example native array, using explicitly provisioned public ports:

```json
[
  {"protocol":"tcp","port":9000,"backends":[{"target":"tcp://10.0.0.10:9000","weight":1}]},
  {"protocol":"udp","port":9001,"backends":[{"target":"udp://10.0.0.10:9001","weight":1}]},
  {"protocol":"tls","port":9444,"hostname":"app.example.com","backends":[{"target":"tcp://10.0.0.10:443","weight":1}]}
]
```

Provider snapshots accept an optional top-level `streams` array with
the same schema, in addition to required revision and sites fields.
It replaces that provider's owned transport routes; omission or [] clears
them. Preflight returns a zero-based `stream_index` rejection coordinate.
Provider permission requires allow_stream plus protocol-specific stream_ports,
scoped IPv4 backends, and authorized SNI hostnames. A port cannot be owned
by two providers or shared with native routes. Transport ownership is
included in provider revision state and shared HA configuration.
TLS passes through without termination. No layer-4 protocol is inspected
by the HTTP WAF. Refer to kubernetes-controller.md for listener setup and
supported limits.


### Explicit frontend certificate interoperability

Provider administration supports `allow_client_validated_frontend`
(default false). This allows the provider to supply an explicit
currently valid certificate/key pair without requiring the DNS SAN
to cover the managed frontend hostname. DNS ownership restrictions
and all backend TLS trust checks still apply. Normal clients continue
to authenticate the served certificate and will reject a mismatch.
Use the separate controller opt-in for Gateway resources. Strict SAN
checking is the default and is recommended in production.
