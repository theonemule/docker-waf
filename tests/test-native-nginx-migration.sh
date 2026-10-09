#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/data/sites" "$TMP/data/migration/sites" "$TMP/bin" "$TMP/out"
printf 'HOST=demo.test\nALIASES=alias.demo.test\n' > "$TMP/data/sites/demo.test.site"
cat > "$TMP/data/migration/sites/demo.test.conf" <<'NGINX'
server {
    listen 8080;
    server_name demo.test alias.demo.test;
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 8443 ssl;
    server_name demo.test alias.demo.test;
    ssl_certificate /data/certs/demo.test/fullchain.pem;
    ssl_certificate_key /data/certs/demo.test/privkey.pem;
    limit_req zone=test_rate burst=10;
    location = /healthz {
        return 200 "ok\n";
    }
    location /api/ {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 300s;
    }
}
NGINX
python3 "$ROOT/scripts/import-native-nginx.py" --data "$TMP/data" > "$TMP/inventory.json"
[[ "$(jq -r '.route_count' "$TMP/inventory.json")" == 3 ]]
[[ "$(find "$TMP/data/sites/demo.test.routes" -name '*.route' -type f | wc -l)" == 3 ]]
cat > "$TMP/mock-common.sh" <<'COMMON'
DATA_DIR="${DATA_DIR:?}"
SITE_DIR="$DATA_DIR/sites"
die() { printf '%s\n' "$*" >&2; exit 1; }
kv_get() { sed -n "s/^$2=//p" "$1" | head -1; }
slug_for_host() { printf %s "$1"; }
route_dir() { printf '%s/%s.routes' "$SITE_DIR" "$1"; }
site_file() { printf '%s/%s.site' "$SITE_DIR" "$1"; }
validate_route_match() { [[ "$1" == prefix || "$1" == exact || "$1" == regex ]]; }
validate_route_path() { [[ "$1" == /* ]]; }
validate_upstream() { [[ "$1" == http://* || "$1" == https://* ]]; }
validate_timeout() { [[ "$1" =~ ^[0-9]+$ ]]; }
COMMON
sed 's@source /opt/liteedge/bin/common.sh@source "$TEST_MOCK_COMMON"@' "$ROOT/bin/render-imported.sh" > "$TMP/bin/render-imported.sh"
chmod +x "$TMP/bin/render-imported.sh"
export DATA_DIR="$TMP/data" TEST_MOCK_COMMON="$TMP/mock-common.sh"
output="$TMP/out/demo.conf"
"$TMP/bin/render-imported.sh" demo.test "$output"
[[ "$(grep -c 'location ' "$output")" == 3 ]]
[[ "$(grep -c 'proxy_pass http://127.0.0.1:8081;' "$output")" == 1 ]]
[[ "$(grep -c 'limit_req zone=test_rate' "$output")" == 1 ]]
[[ "$(grep -c 'location = /healthz' "$output")" == 1 ]]
[[ "$(grep -c 'set \$liteedge_route "prefix:/api/"' "$output")" == 1 ]]
# Rewrite the managed proxy route in place and verify regenerated output changes.
route_file="$(grep -l '^ACTION=proxy$' "$TMP/data/sites/demo.test.routes/"*.route)"
sed -i 's#^TARGET=http://127.0.0.1:8081#TARGET=http://127.0.0.1:8282#;s/^TIMEOUT=300$/TIMEOUT=345/;s/^WAF=0$/WAF=1/' "$route_file"
"$TMP/bin/render-imported.sh" demo.test "$output"
grep -q 'proxy_pass http://127.0.0.1:8282' "$output"
grep -q 'proxy_read_timeout 345s' "$output"
grep -q 'modsecurity on;' "$output"
# A custom response route can be removed without reappearing via a raw overlay.
custom_file="$(grep -l 'PATH=/healthz' "$TMP/data/sites/demo.test.routes/"*.route)"
rm -f "$custom_file"
"$TMP/bin/render-imported.sh" demo.test "$output"
! grep -q 'location = /healthz' "$output"
# New managed proxy routes get added to HTTP and HTTPS server blocks.
cat > "$TMP/data/sites/demo.test.routes/new.route" <<'ROUTE'
ID=aaaaaaaaaaaaaaaa
MATCH=prefix
PATH=/extra/
TARGET=http://127.0.0.1:9191
WEBSOCKET=0
TIMEOUT=60
WAF=0
FORCE_HTTPS=0
ROUTE
"$TMP/bin/render-imported.sh" demo.test "$output"
[[ "$(grep -c 'location ^~ /extra/' "$output")" == 2 ]]
# The original source remains unchanged and no duplicate locations are emitted.
[[ "$(grep -c 'location /api/' "$output")" == 1 ]]
echo 'PASS native migration: complete inventory, managed proxy updates, WAF, timeout, custom route deletion and route creation'
