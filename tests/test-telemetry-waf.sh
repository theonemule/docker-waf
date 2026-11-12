#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Exercise the renderer's actual location-emission function in isolation,
# without changing any persistent WAF data or reloading NGINX.
source <(sed -n '/^emit_route_values() {/,/^}/p' "$ROOT/bin/render-nginx.sh")
normalize_allow_ips(){ printf '%s' "$1"; }
validate_route_rate(){ :; }
validate_route_body_size(){ :; }
validate_route_methods(){ :; }
validate_route_rewrite(){ :; }
emit_proxy_headers(){ echo '        proxy_http_version 1.1;'; }
ROUTE_METHODS=POST
ROUTE_REWRITE_ENABLED=0
ROUTE_REWRITE_PATTERN=''
ROUTE_REWRITE_REPLACEMENT=''
ROUTE_X_HEADERS_B64=''
actual="$(emit_route_values telemetry.blaize.net prefix /mcp/ http://10.0.1.183:4319 0 40 0 1 1 '' '' https 1 '' 180 m 64k mcp_test_zone)"
grep -Fq 'location ^~ /mcp/' <<<"$actual"
grep -Fq 'access_log /data/logs/events.jsonl liteedge_mcp_json;' <<<"$actual"
grep -Fq 'error_log /dev/null crit;' <<<"$actual"
grep -Fq 'limit_req_status 429;' <<<"$actual"
grep -Fq 'client_max_body_size 64k;' <<<"$actual"
grep -Fq 'return 405;' <<<"$actual"
ROUTE_METHODS='POST,OPTIONS'
faro="$(emit_route_values telemetry.blaize.net prefix /faro/paladin-chronicles/ http://10.0.1.183:4319 0 30 0 1 1 '' '' https 1 '' 0 m 256k faro_test_zone)"
! grep -q 'liteedge_mcp_json' <<<"$faro"
grep -Fq 'client_max_body_size 256k;' <<<"$faro"
grep -Fq '(POST|OPTIONS)' <<<"$faro"
echo 'PASS telemetry WAF route privacy, rate limits, method/body controls'
