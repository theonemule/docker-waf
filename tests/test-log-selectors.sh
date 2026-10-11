#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sites/alpha.test.routes" "$TMP/migration/sites" "$TMP/logs" "$TMP/bin"
cat > "$TMP/common.sh" <<'SH'
DATA_DIR="${DATA_DIR:?}"
SITE_DIR="$DATA_DIR/sites"
SERVER_SETTINGS_FILE="$DATA_DIR/server-settings.conf"
OBS_DIR="$DATA_DIR/observability"
die() { echo "$*" >&2; exit 1; }
kv_get() { sed -n "s/^$2=//p" "$1" | head -1; }
slug_for_host() { printf %s "$1" | tr '[:upper:]' '[:lower:]'; }
route_dir() { printf '%s/%s.routes' "$SITE_DIR" "$1"; }
SH
printf 'HOST=alpha.test\nALIASES=www.alpha.test alias.alpha.test\n' > "$TMP/sites/alpha.test.site"
printf 'HOST=beta.test\nALIASES=www.beta.test\n' > "$TMP/sites/beta.test.site"
printf 'MATCH=prefix\nPATH=/api/\n' > "$TMP/sites/alpha.test.routes/api.route"
cat > "$TMP/migration/sites/alpha.test.conf" <<'CONF'
server {
  location / { proxy_pass http://backend; }
  location = /healthz { return 200; }
}
CONF
cat > "$TMP/migration/sites/beta.test.conf" <<'CONF'
server {
  location / { proxy_pass http://backend; }
  location /api { proxy_pass http://backend; }
}
CONF
sed 's@source /opt/liteedge/bin/common.sh@source "$LOG_TEST_COMMON"@' "$ROOT/bin/alert-catalog.sh" > "$TMP/bin/alert-catalog.sh"
sed -e 's@source /opt/liteedge/bin/common.sh@source "$LOG_TEST_COMMON"@' -e 's@/opt/liteedge/bin/alert-catalog.sh@"$LOG_TEST_CATALOG"@g' "$ROOT/bin/obsctl.sh" > "$TMP/bin/obsctl.sh"
chmod +x "$TMP/bin"/*.sh
export DATA_DIR="$TMP" LOG_TEST_COMMON="$TMP/common.sh" LOG_TEST_CATALOG="$TMP/bin/alert-catalog.sh"
export EVENTS_FILE="$TMP/logs/events.jsonl" OBS_DIR="$TMP/observability"
cat > "$EVENTS_FILE" <<'JSONL'
{"type":"http","epoch":1790000000,"host":"alpha.test","route":"prefix:/api/","uri":"/api/a","port":"443","method":"GET","status":200}
{"type":"http","epoch":1790000001,"host":"www.alpha.test","route":"-","uri":"/api/b","port":"443","method":"POST","status":503}
{"type":"waf","epoch":1790000002,"host":"alias.alpha.test","route":"-","uri":"/healthz","port":"443","method":"GET","status":403,"action":"blocked","rule_id":"942100"}
{"type":"http","epoch":1790000003,"host":"beta.test","route":"-","uri":"/api/a","port":"80","method":"GET","status":502}
{"type":"http","epoch":1790000004,"host":"www.beta.test","route":"-","uri":"/api/b","port":"80","method":"POST","status":404}
{"type":"http","epoch":1790000005,"host":"unknown.test","route":"-","uri":"/api/a","port":"443","method":"GET","status":200}
JSONL
run() { "$TMP/bin/obsctl.sh" query all '' '' '' '' '' '' 100 0 "$1"; }
scopes='[{"host":"alpha.test","site":"alpha.test","routes":["prefix:/api/"]},{"host":"www.beta.test","site":"beta.test","routes":["prefix:/api"]}]'
[[ "$(run "$scopes" | wc -l)" == 2 ]]
[[ "$(run "$scopes" | jq -r '.host' | paste -sd, -)" == 'alpha.test,www.beta.test' ]]
scopes='[{"host":"www.alpha.test","site":"alpha.test","routes":["prefix:/api/"]},{"host":"beta.test","site":"beta.test","routes":["prefix:/api"]}]'
[[ "$(run "$scopes" | jq -r '.status' | paste -sd, -)" == '503,502' ]]
scopes='[{"host":"alias.alpha.test","site":"alpha.test","routes":["exact:/healthz"]}]'
[[ "$(run "$scopes" | jq -r '.rule_id')" == '942100' ]]
[[ "$(run '[]' | wc -l)" == 6 ]]
scopes='[{"host":"alpha.test","site":"alpha.test","routes":[]},{"host":"www.alpha.test","site":"alpha.test","routes":["prefix:/api/"]}]'
[[ "$(run "$scopes" | wc -l)" == 2 ]]
[[ "$("$TMP/bin/obsctl.sh" query http '' '' 443 POST 5xx '' 100 0 "$scopes" | jq -r '.host')" == 'www.alpha.test' ]]
# Old query/bookmark compatibility still works.
[[ "$("$TMP/bin/obsctl.sh" query http alpha.test prefix:/api/ '' '' '' '' 100 0 | wc -l)" == 1 ]]
for bad in '{bad' '"unknown"' '[{"host":"evil.test","site":"alpha.test","routes":[]}]' '[{"host":"alpha.test","site":"alpha.test","routes":["exact:/invalid"]}]' '[{"host":"alpha.test","site":"beta.test","routes":[]}]'; do
  if run "$bad" >/dev/null 2>&1; then echo "Accepted invalid scope: $bad" >&2; exit 1; fi
done
echo 'PASS: multi-host and alias log queries, native URI route matches, WAF filtering, legacy parameters and forged selection rejection'
