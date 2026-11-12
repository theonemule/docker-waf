# Production telemetry.blaize.net WAF routes

Once `10.0.1.183:8080/healthz` returns HTTP 200, add two *specific*
prefix routes to the existing `telemetry.blaize.net` LightEdge site:

| Route | Upstream | Methods | WAF | Rate | Max body |
| --- | --- | --- | --- | --- | --- |
| `/faro/paladin-chronicles/` | `http://10.0.1.183:8080` | POST, OPTIONS | CRS on (PL1) | 360/min/IP | 256k |
| `/mcp/` | `http://10.0.1.183:8080` | POST | CRS off to avoid token-bearing audit logs; NGINX limits remain | 180/min/IP | 64k |

The separate HTTP proxy enforces additional limits and only forwards
the exact Faro source and MCP 64-character hexadecimal token routes.
**Do not expose a `/` catch-all that forwards to the collector admin UI.**
Keep the user-created site record, TLS certificate, unrelated routes and
websites unchanged.

A reviewed provisioning script is installed into the updated LiteEdge
container at `/opt/liteedge/bin/configure-telemetry-waf.sh`. On the WAF
Docker host, **after the collector HTTP sidecars are deployed and the
new LightEdge image with this change is running**, use:

```sh
docker exec liteedge /opt/liteedge/bin/configure-telemetry-waf.sh
```

It requires the existing site, checks the HTTP backend and automatic
MCP secret redaction, then upserts the two routes using LiteEdge's
transactional `sitectl.sh` to validate/reload NGINX. It refuses to
activate routes if either dependency is missing.

MCP paths carry private bearer credentials. The renderer automatically
selects `liteedge_mcp_json` for the `prefix /mcp/` route. That
existing NGINX log format preserves timing, method and response status
but replaces URI with `/mcp` and route label with `[redacted]`.
The MCP route also suppresses NGINX error URI logging. **Do not enable
ModSecurity audit logging on the MCP route**, and inspect any upstream
Cloudflare HTTP logs for full URL storage. Tokens must never be printed
to the browser website bundle.

The Faro endpoint is browser-facing and must accept CORS preflight
`OPTIONS` with exact origin `https://www.blaize.net` (and
`https://blaize.net` if the apex is also served). Its endpoint name
and public ID aren't credentials. The MCP endpoint is client-to-server
and has no CORS requirement (all browser Origin headers are rejected).

Smoke checks, **only after both components are deployed**:

```sh
curl -i -X OPTIONS https://telemetry.blaize.net/faro/paladin-chronicles/PUBLIC_ID \
 -H 'Origin: https://www.blaize.net' \
 -H 'Access-Control-Request-Method: POST' \
 -H 'Access-Control-Request-Headers: content-type'
curl -s -o /dev/null -w '%{http_code}\n' https://telemetry.blaize.net/v1/admin/endpoints
```

Expected: Faro preflight 204 with correct
`Access-Control-Allow-Origin`; admin 404. The MCP sidecar's guarded
deployment script tests tokenized JSON-RPC initialization without
printing the private token.

This script does **not** bypass the remote SSH/deployment gap. A local
source change or passing test is not evidence of a production route.
