#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sites/alpha.test.routes" "$TMP/sites/beta.test.routes" "$TMP/migration/sites" "$TMP/logs" "$TMP/bin"
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
printf 'MATCH=exact\nPATH=/private\n' > "$TMP/sites/beta.test.routes/private.route"
cat > "$TMP/migration/sites/alpha.test.conf" <<'SH'
server {
 location / { proxy_pass http://backend; }
 location = /healthz { return 200; }
}
SH
cat > "$TMP/migration/sites/beta.test.conf" <<'SH'
server {
 location / { proxy_pass http://backend; }
 location /admin { return 401; }
}
SH
sed 's@source /opt/liteedge/bin/common.sh@source "$ALERT_TEST_COMMON"@' "$ROOT/bin/alert-catalog.sh" > "$TMP/bin/alert-catalog.sh"
sed -e 's@source /opt/liteedge/bin/common.sh@source "$ALERT_TEST_COMMON"@' -e 's@/opt/liteedge/bin/alert-catalog.sh@"$ALERT_TEST_CATALOG"@g' "$ROOT/bin/obsctl.sh" > "$TMP/bin/obsctl.sh"
chmod +x "$TMP/bin/alert-catalog.sh" "$TMP/bin/obsctl.sh"
export DATA_DIR="$TMP" ALERT_TEST_COMMON="$TMP/common.sh" ALERT_TEST_CATALOG="$TMP/bin/alert-catalog.sh"
export EVENTS_FILE="$TMP/logs/events.jsonl" AUDIT_FILE="$TMP/logs/modsec_audit.json" OBS_DIR="$TMP/observability"
CATALOG="$("$ALERT_TEST_CATALOG")"
[[ "$(jq -r '.hosts | length' <<< "$CATALOG")" == 5 ]]
[[ "$(jq -r '[.routes[] | select(.site=="alpha.test") ] | length' <<< "$CATALOG")" == 3 ]]
jq -e '.hosts | any(.[]; .name=="alias.alpha.test" and .kind=="alias")' <<< "$CATALOG" >/dev/null
jq -e '.routes | any(.[]; .site=="beta.test" and .route=="prefix:/admin")' <<< "$CATALOG" >/dev/null
SAVE_SCOPES='[{"host":"alias.alpha.test","site":"alpha.test","routes":["prefix:/api/"]},{"host":"beta.test","site":"beta.test","routes":["exact:/private"]}]'
"$TMP/bin/obsctl.sh" alert-save multi-test 'Multi site filter' http '' '' '' 5xx any 1 60 30 webhook https://alerts.example.test/hook '' "$SAVE_SCOPES"
RULE="$(jq -c '.[0]' "$OBS_DIR/alerts.json")"
[[ "$(jq -r '.routes_limited' <<< "$RULE")" == true ]]
[[ "$(jq -r '.scopes | length' <<< "$RULE")" == 2 ]]
# Forged / unowned host aliases or routes must be rejected at the server boundary.
if "$TMP/bin/obsctl.sh" alert-save bad1 bogus http '' '' '' 5xx any 1 60 30 webhook https://alerts.example.test/hook '' '[{"host":"evil.test","site":"alpha.test","routes":[]}]' >/dev/null 2>&1; then echo 'Accepted a forged host' >&2; exit 1; fi
if "$TMP/bin/obsctl.sh" alert-save bad2 bogus http '' '' '' 5xx any 1 60 30 webhook https://alerts.example.test/hook '' '[{"host":"alias.alpha.test","site":"alpha.test","routes":["exact:/private"]}]' >/dev/null 2>&1; then echo 'Accepted a route owned by another host' >&2; exit 1; fi
if "$TMP/bin/obsctl.sh" alert-save bad3 bogus http '' '' '' 5xx any 1 60 30 webhook https://alerts.example.test/hook '' '{"host":"alpha.test"}' >/dev/null 2>&1; then echo 'Accepted malformed JSON selection' >&2; exit 1; fi

# Exercise the exact jq matcher used by the worker without network access.
PROGRAM="$(sed -n "/^ALERT_MATCH_JQ='/,/^'$/p" "$ROOT/bin/obs-worker.sh" | sed '1d;$d')"
for row in \
  'alias.alpha.test|/api/fail|prefix:/api/|true' \
  'alias.alpha.test|/elsewhere|-|false' \
  'www.alpha.test|/api/fail|prefix:/api/|false' \
  'beta.test|/private|exact:/private|true' \
  'beta.test|/public|-|false' \
  'alpha.test|/api/fail|prefix:/api/|false'; do
    IFS='|' read -r host uri route expected <<< "$row"
    EVENT="$(jq -n --arg host "$host" --arg uri "$uri" --arg route "$route" '{type:"http",host:$host,uri:$uri,route:$route,status:503,method:"GET",action:"-"}')"
    result="$(jq -rn --argjson rule "$RULE" --argjson event "$EVENT" "$PROGRAM \$event | matches_alert(\$rule)")"
    [[ "$result" == "$expected" ]] || { echo "Mismatch $row: $result" >&2; exit 1; }
  done
# Rules without route selections apply to any route on their selected host.
"$TMP/bin/obsctl.sh" alert-save host-only 'Host only' http '' '' '' 5xx any 1 60 30 webhook https://alerts.example.test/hook '' '[{"host":"www.beta.test","site":"beta.test","routes":[]}]'
RULE="$(jq -c '.[] | select(.id=="host-only")' "$OBS_DIR/alerts.json")"
EVENT='{"type":"http","host":"www.beta.test","uri":"/unlisted","route":"-","status":500,"method":"GET","action":"-"}'
[[ "$(jq -rn --argjson rule "$RULE" --argjson event "$EVENT" "$PROGRAM \$event | matches_alert(\$rule)")" == true ]]
echo 'PASS: alias inventory, native and managed route discovery, server validation, multi-host matching and route scoping'
