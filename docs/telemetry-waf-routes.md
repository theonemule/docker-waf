# Live LightEdge routing for native Faro telemetry

**Production:** `telemetry.blaize.net` terminates public HTTPS at LightEdge,
then forwards directly via private HTTP to the existing
`telemetry-lake` Docker container on `10.0.1.183:4319`.

There is **no sidecar, converter, separate Faro proxy or bridge**.

| WAF route | Native upstream | Methods | WAF rules | Max body |
| --- | --- | --- | --- | --- |
| `/faro/paladin-chronicles/` | `http://10.0.1.183:4319` | POST, OPTIONS | ModSecurity enabled | 256k |
| `/` | `http://10.0.1.183:4319` | GET | ModSecurity enabled | 4k |

The upstream is Faro-only, so requests to private administration, query,
bearer-authenticated ingestion and OTLP paths return 404 even if they reach
the direct LAN port. Keep the site and TLS certificate unchanged.

The initial WAF rate limiter (without burst) rejected a normal CORS
`OPTIONS` followed immediately by `POST`. The two routes therefore
use `RATE_COUNT=0` for now; the **native collector itself** enforces
a 120-POST/minute/IP rate limit, a 256 KiB body limit, an exact public
source and identifier, and a maximum of 1,000 records per request.

## Reconciliation after upgrading LightEdge

After verifying the existing `telemetry-lake` collector responds:

```sh
curl -fsS http://10.0.1.183:4319/healthz
docker exec liteedge /opt/liteedge/bin/configure-telemetry-waf.sh
```

The provisioning script validates that the backend identifies itself as
`telemetry-lake` before making changes, and uses LiteEdge's transactional
`sitectl.sh` to upsert only the two required routes. It does not
configure or enable any MCP URL. A future tokenized read-only MCP
endpoint is a separate feature and requires a separate security review.

## Browser CORS

The native collector allows **only**:
`https://blaize.net` and `https://www.blaize.net`.

A valid preflight has an HTTP 204 response with the matching
`Access-Control-Allow-Origin` and explicit methods and headers.
A valid Faro `POST` returns 202. Invalid origins are rejected with 403,
wrong public identifiers return 404, and administrative endpoints on
this public hostname remain unavailable.

```sh
curl -i -X OPTIONS \
  https://telemetry.blaize.net/faro/paladin-chronicles/PUBLIC_ID \
  -H 'Origin: https://www.blaize.net' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type'
```

Never revert the WAF upstream to the old `18084` bridge or
`8080` compatibility proxy. Both have been retired. The live collector
and WAF routes are `10.0.1.183:4319`.
