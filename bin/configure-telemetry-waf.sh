#!/usr/bin/env bash
# Run INSIDE the updated LightEdge container after HTTP collector :8080 is live.
# Leaves existing site/certificate/root route untouched; upserts two scoped routes.
set -Eeuo pipefail
source /opt/liteedge/bin/common.sh
HOST=telemetry.blaize.net
BACKEND=http://10.0.1.183:8080
SITE_CTL=/opt/liteedge/bin/sitectl.sh
[[ -s "$(site_file "$HOST")" ]] || {
  echo "Site $HOST does not exist. Create the site/TLS entry first." >&2
  exit 1
}
grep -q 'liteedge_mcp_json' /opt/liteedge/etc/nginx/nginx.conf 2>/dev/null || {
  echo 'Safe MCP access log format not installed. Upgrade LightEdge first.' >&2
  exit 1
}
grep -Fq 'access_log /data/logs/events.jsonl liteedge_mcp_json;' /opt/liteedge/bin/render-nginx.sh || {
  echo 'Automatic token redaction is missing; refusing to expose MCP route.' >&2
  exit 1
}
curl -fsS --connect-timeout 2 --max-time 5 "$BACKEND/healthz" >/dev/null || {
  echo "Backend $BACKEND is not yet reachable. Install HTTP/MCP sidecars first." >&2
  exit 1
}

upsert() {
  local path="$1" methods="$2" waf="$3" rate="$4" body="$5"
  local existing='' file
  for file in "$(route_dir "$HOST")"/*.route; do
    [[ -f "$file" ]] || continue
    if [[ "$(kv_get "$file" MATCH)" == prefix && "$(kv_get "$file" PATH)" == "$path" ]]; then
      existing="$(kv_get "$file" ID)"
      break
    fi
  done
  local -a args=(
    "$HOST" prefix "$path" "$BACKEND"
    0 40 "$waf" 1 1 '' ''
    '' round_robin 3 30
    1 /healthz 200 30 5 3 2 300
    "$methods" 0 '' '' ''
    '' "$rate" m "$body"
  )
  if [[ -n "$existing" ]]; then
    "$SITE_CTL" route-save "$existing" "${args[@]}"
  else
    "$SITE_CTL" route-add "${args[@]}"
  fi
}
# JSON-RPC POST route: disable ModSecurity audit logs, but enforce NGINX
# rate/method/body protections. The renderer emits token-redacted JSON log.
upsert /mcp/ POST 0 180 64k
# Browser SDK CORS is returned by upstream Faro receiver, not invented here.
# Rate limit 360/min/IP and cap body independently of upstream policy.
upsert /faro/paladin-chronicles/ POST,OPTIONS 1 360 256k

# Validate generated config and route metadata; sitectl applies/reloads safely.
# Do not display any MCP URL token, including in error output.
"$SITE_CTL" list | grep -qx "$HOST"
echo "Configured $HOST: /mcp/ and /faro/paladin-chronicles/ -> $BACKEND"
echo 'MCP WAF access logs redact the secret URL. HTTPS is offloaded by LightEdge.'
