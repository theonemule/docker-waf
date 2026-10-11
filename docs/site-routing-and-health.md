# Site routing and health operations

LiteEdge manages hostnames, routes, OWASP CRS policies, optional backend pools,
and active HTTP checks. Settings are in **Sites → Manage** and persist in
the appliance's `/data` volume.

## Temporarily disable and re-enable a site

The **Sites** list displays the status of each host.

- Click **Disable** on the site row, or **Manage → Disable site**. The
  site responds with HTTP **503 Service Unavailable**, including its routes.
  Hostnames, aliases, route settings, WAF policies, and certificates remain saved.
- Click **Enable** to restore the previous configuration.
- The page remains in context: toggling from the Sites overview returns to
  the overview, while toggling from Manage returns to the same site editor.
- **Delete** is a different action and removes saved site settings.
  Sites are enabled by default.

Command-line equivalents inside the appliance:

```bash
/opt/liteedge/bin/sitectl.sh disable app.example.com
/opt/liteedge/bin/sitectl.sh enable app.example.com
```

The site record stores `ENABLED=0` or `ENABLED=1`. Changes regenerate NGINX
configuration, validate it, and reload; failed validations or reloads roll back.
**Disabling affects ACME HTTP-01 challenge paths too.** Re-enable the
site before obtaining or renewing its Let's Encrypt certificate.

## Route configuration dialog

Open **Sites → Manage**, then **Configure** for an existing route or
**Add route**. The modal provides:

- Prefix, exact, or regex route matching, primary backend, timeout, WebSocket,
  and HTTP-to-HTTPS redirect.
- Per-route OWASP CRS on/off, PL1–PL4, installed plugins, and rule exclusions.
- Additional backends, load-balancing mode, and passive failure settings.
- Optional active HTTP probe, expected status, interval, thresholds, and cooldown.

Imported custom NGINX locations such as redirects or ACME handlers remain
editable through **Advanced NGINX**, not the standard proxy-route dialog.

## Multiple backends and load balancing

Open the route's **Configure** dialog and use the **Backend pool**
section. Each backend has its own URL input and **Remove** button. Click
**Add backend** to insert another input. You can add or remove endpoints
in any position; the pool requires at least one backend before saving.

For example, enter these as three separate rows:

```text
Backend 1   http://app1:8080       Remove
Backend 2   http://app2:8080       Remove
Backend 3   http://app3:8080       Remove

[Add backend]
```

Existing routes automatically populate these rows from their saved endpoints.
For backwards compatibility the first row is stored as `TARGET` and the
remaining rows as `BACKENDS`, but all endpoints are edited in exactly the
same way. Removing the first row promotes the next one when saved.

Pools accept up to **16** plain `http://` backends with matching optional
base paths. The legacy single-backend route can still use its supported
`https://` upstream URL. Managed upstream definitions are generated in
`/data/nginx/upstreams.conf`; edit the route through LiteEdge, **not**
the generated file.

| Mode | Behavior |
| --- | --- |
| Round robin (default) | Rotate across available pool backends. |
| Least connections | Choose the backend with the fewest active connections. |
| Client IP hash | Sticky assignment based on client IP; clients behind shared NAT may collide. |
| Affinity cookie | Consistent hash using the `liteedge_affinity` cookie, initialized on the first request. |

Affinity cookies use `Secure`, `HttpOnly`, `SameSite=Lax`, and `Path=/`.
Serve these routes via HTTPS. A failed or changed backend can still move a
client's session; this is not a session data store.

**Passive failed attempts** sets NGINX `max_fails` (default **3**, range
1–20). **Fail timeout** sets `fail_timeout` (default **30 seconds**,
range 1–3600). These use open-source NGINX's request-time failure handling,
not the active health checker. NGINX's default upstream failure/status
semantics apply; not every application error counts as an upstream failure.

## Active HTTP health probes

An opt-in Bash worker directly probes the primary and each additional
backend. Probes are independent from client traffic.

| Setting | Default | Description |
| --- | --- | --- |
| Enabled | Off | Probes only run when enabled for that route. |
| Path | `/health` | Absolute HTTP GET path on each backend's origin. |
| Expected status | `200` | Exact code or status class (for example `2xx`). |
| Interval | 30 seconds | Time between checks of each endpoint. |
| Timeout | 5 seconds | Connect and overall request timeout. |
| Failures before down | 3 | Consecutive failed checks before outage detection. |
| Successes to recover | 2 | Consecutive successful checks before recovery. |
| Notification cooldown | 300 seconds | Suppresses closely repeated down notifications. |

Use a safe, read-only, unauthenticated application health endpoint. Avoid
credentials and unguessable tokens in probe paths. The worker saves probe
state under `/data/observability/health/`.

Only health transitions generate events:

| Transition | Event type | Action | Synthetic event status |
| --- | --- | --- | --- |
| Backend becomes unavailable | `health` | `down` | `503` |
| Backend recovers | `health` | `up` | `200` |

These `503`/`200` values describe health events, **not client requests**.
Events appear in **Logs → Event type → Health probes** and
`/data/logs/events.jsonl`. Worker diagnostics are in
`/data/logs/health-worker.log`. The events also contain the observed probe
status and backend address.

### Health-based alerts

For SMTP email delivery, first open **Server Settings → SMTP email for
alerts**, enter the SMTP hostname, STARTTLS port, sender email, optional
username and password, and save. Email settings are separate from Log Export
and stored persistently. The password remains blank in the UI after saving,
and leaving it blank during an update retains the saved credential.

In **Alerts**, create a rule with **Event type → Backend health** and
**Event action → Backend down**, **Count ≥ 1**, then choose any host/route
scope, rolling window, cooldown, and HTTPS webhook or SMTP email. Save it.
For recovery notifications, add a rule with **Event action → Recovered**.

Route probe cooldown and alert-delivery cooldown are separate controls.
For diagnosis without notifications, filter Logs on `health` events.

**Important limitation:** Active probes only **monitor and notify**.
They do **not** dynamically remove unhealthy backends from the NGINX
pool. NGINX's passive `max_fails`/`fail_timeout` mechanism excludes
endpoints after qualifying request-time failures. An outage may therefore
produce errors until passive failover occurs. This is not NGINX Plus
active health checking.

## Log Export in Server Settings

Use **Server Settings → Log Export** to configure RFC 5424 syslog or HTTPS event collection. It has its own Save button and does not modify SMTP email configuration. The previous `/admin/collector` address and its save endpoint remain compatible, redirecting to this section. **Server Settings** is last in the navigation menu.

## Log filtering and retained settings

Opening Logs does not query events automatically. Apply at least one filter
and click **Search logs**. Search text is empty by default. Host/alias and
route selections, plus other filters, persist in the current browser-tab
session. Explicit search URL parameters take precedence over stored values.
The server validates selected hosts and routes. Filtered HTTP, WAF, and
health events can be exported to CSV or JSONL.

## Privacy and sensitive MCP routes

Certain MCP endpoints include unguessable access tokens in their URL paths.
Enabling ordinary access logging for those locations can expose the path.
For sensitive NGINX locations, an **opt-in** `liteedge_mcp_json` format
records request metadata and response status but replaces the URI with
`/mcp` and the route label with `[redacted]`.

```nginx
# Inside a separately secured sensitive location:
access_log /data/logs/events.jsonl liteedge_mcp_json;
```

This format is **not automatically selected on every route**. A location
with `access_log off` continues to emit no access events until explicitly
configured. Host/status filtering works on redacted events; exact
route-pattern filtering may not match the redacted route label. Ordinary
WAF auditing and general access logging have separate redaction behavior.

## Operational checks

With the Docker container named `liteedge`:

```bash
docker exec liteedge /opt/liteedge/sbin/nginx -t -c /data/nginx/nginx.conf
docker exec liteedge /opt/liteedge/bin/obsctl.sh query health "" "" "" "" "" "" 20 0
docker exec liteedge /opt/liteedge/bin/health-worker.sh tick
```

The probe worker normally runs continuously from the entrypoint; manually
invoking `tick` is intended for diagnostics.

For development/CI:

```bash
bash tests/test-lb-health.sh
bash tests/test-native-nginx-migration.sh
bash tests/test-log-selectors.sh
bash tests/test-observability.sh
python3 tests/test-http-api-coverage.py
```

The suite checks pool validation, probe failure/recovery thresholds, managed
imported routes, log filtering, and management action coverage. HTTP
integration tests use a disposable Docker container, not live site data.
