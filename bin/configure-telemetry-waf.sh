#!/usr/bin/env bash
# Reconcile the existing LightEdge site with the native telemetry-lake Faro
# receiver. HTTPS terminates at LightEdge; upstream is plaintext LAN HTTP.
# Never creates a proxy, sidecar, or MCP service.
set -Eeuo pipefail
source /opt/liteedge/bin/common.sh

HOST=telemetry.blaize.net
BACKEND=http://10.0.1.183:4319
SITE_CTL=/opt/liteedge/bin/sitectl.sh

[[ -s "$(site_file "$HOST")" ]] || {
  echo "Site $HOST does not exist; refusing to overwrite its TLS/site config" >&2
  exit 1
}
curl -fsS --connect-timeout 2 --max-time 5 "$BACKEND/healthz" >/dev/null || {
  echo "Native telemetry-lake Faro input unavailable: $BACKEND" >&2
  exit 1
}
curl -fsS --connect-timeout 2 --max-time 5 "$BACKEND/" | grep -q '"service":"telemetry-lake"' || {
  echo "Backend does not identify as the native telemetry-lake collector" >&2
  exit 1
}

upsert() {
  local path="$1" methods="$2" body="$3" disabled="${4:-}"
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
    0 30 1 1 1 '' "$disabled"
    '' round_robin 3 30
    1 /healthz 200 30 5 3 2 300
    "$methods" 0 '' '' ''
    '' 0 m "$body"
  )
  # Exclude ModSecurity rule 931120 ONLY on the Faro route; its normal
  # browser performance attributes can contain URLs ending in ? (Cloudflare RUM).
  # All other CRS rules remain active.
  # The WAF's 0-burst rate limiter was rejecting the POST immediately
  # after an OPTIONS preflight. Native collector enforces its own 120/min.
  if [[ -n "$existing" ]]; then
    "$SITE_CTL" route-save "$existing" "${args[@]}"
  else
    "$SITE_CTL" route-add "${args[@]}"
  fi
}

upsert /faro/paladin-chronicles/ POST,OPTIONS 256k 931120
upsert / GET 4k

# Fail rather than silently claim completion if a route drifted.
for route in / /faro/paladin-chronicles/; do
  found=0
  for file in "$(route_dir "$HOST")"/*.route; do
    [[ -f "$file" ]] || continue
    if [[ "$(kv_get "$file" PATH)" == "$route" ]]; then
      [[ "$(kv_get "$file" TARGET)" == "$BACKEND" ]] || exit 1
      found=1
    fi
  done
  ((found == 1)) || exit 1
done
echo "Configured $HOST directly to native telemetry-lake at $BACKEND"
echo 'Public HTTPS is offloaded by LightEdge; CORS is handled by the collector.'
