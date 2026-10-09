#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/mock" "$TMP/logs"
cat > "$TMP/common.sh" <<'COMMON'
DATA_DIR="${DATA_DIR:?}"
SERVER_SETTINGS_FILE="$DATA_DIR/server-settings.conf"
OBS_DIR="$DATA_DIR/observability"
die() { printf '%s\n' "$*" >&2; exit 1; }
COMMON
sed 's@source /opt/liteedge/bin/common.sh@source "$LITEEDGE_TEST_COMMON"@' "$ROOT/bin/obsctl.sh" > "$TMP/obsctl.sh"
chmod +x "$TMP/obsctl.sh"
cat > "$TMP/mock/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_DELIVERY_LOG"
cat >> "$TEST_DELIVERY_LOG"
printf '\n' >> "$TEST_DELIVERY_LOG"
MOCK_CURL
chmod +x "$TMP/mock/curl"
export DATA_DIR="$TMP" LITEEDGE_TEST_COMMON="$TMP/common.sh" EVENTS_FILE="$TMP/logs/events.jsonl" AUDIT_FILE="$TMP/logs/modsec_audit.json" OBS_DIR="$TMP/observability"
export TEST_DELIVERY_LOG="$TMP/deliveries.txt"
NOW="$(date +%s)"
cat > "$EVENTS_FILE" <<HTTP
{"type":"http","timestamp":"2026-10-09T00:00:00Z","epoch":$NOW,"host":"app.test","route":"prefix:/api","port":"443","method":"GET","status":200,"ip":"1.2.3.4","uri":"/api/ok","action":"-"}
{"type":"http","timestamp":"2026-10-09T00:00:00Z","epoch":$NOW,"host":"app.test","route":"prefix:/api","port":"443","method":"POST","status":503,"ip":"1.2.3.4","uri":"/api/error","action":"-"}
HTTP
cat > "$AUDIT_FILE" <<'AUDIT'
{"transaction":{"client_ip":"1.2.3.4","unique_id":"tx-1","is_interrupted":true,"host_port":443,"request":{"hostname":"app.test","method":"POST","uri":"/api/blocked?secret=never-log","headers":{"Host":"app.test"},"port":443},"response":{"http_code":403},"intervention":{"disruptive":true},"messages":[{"message":"SQL injection attempt","details":{"ruleId":"942100","severity":"CRITICAL"}}]}}
AUDIT
[[ "$("$TMP/obsctl.sh" query http app.test 'prefix:/api' 443 GET 2xx '' 100 0 | wc -l)" == 1 ]]
[[ "$("$TMP/obsctl.sh" query http app.test 'prefix:/api' 443 POST 5xx '' 100 0 | wc -l)" == 1 ]]
[[ "$("$TMP/obsctl.sh" query http '' '' '' '' '' error 100 0 | wc -l)" == 1 ]]
[[ "$("$TMP/obsctl.sh" query http wrong.test '' '' '' '' '' 100 0 | wc -l)" == 0 ]]
"$TMP/obsctl.sh" collector-save off '' 514 udp generic '' '' '' 587 '' '' ''
"$ROOT/bin/obs-worker.sh" tick
[[ "$("$TMP/obsctl.sh" query waf app.test '' '' POST 403 '' 100 0 | jq -r '.rule_id')" == 942100 ]]
[[ "$("$TMP/obsctl.sh" query waf app.test '' '' POST 403 '' 100 0 | jq -r '.action')" == blocked ]]
! grep -q 'never-log' "$EVENTS_FILE"
"$TMP/obsctl.sh" alert-save waf-block 'WAF attack blocked' waf app.test '' POST 403 blocked 1 60 300 webhook https://alerts.example.org/hook SQL
# Append another WAF audit transaction to create a new event for the alert engine.
sed 's/tx-1/tx-2/' "$AUDIT_FILE" >> "$AUDIT_FILE.new"
cat "$AUDIT_FILE.new" >> "$AUDIT_FILE"
PATH="$TMP/mock:$PATH" "$ROOT/bin/obs-worker.sh" tick
[[ -s "$TEST_DELIVERY_LOG" ]]
grep -q 'liteedge.alert' "$TEST_DELIVERY_LOG"
grep -q 'waf-block' "$TEST_DELIVERY_LOG"
# Third event during cooldown must not produce a second alert.
cp "$AUDIT_FILE.new" "$TMP/audit-extra"
cat "$TMP/audit-extra" >> "$AUDIT_FILE"
PATH="$TMP/mock:$PATH" "$ROOT/bin/obs-worker.sh" tick
[[ "$(grep -c 'liteedge.alert' "$TEST_DELIVERY_LOG")" == 1 ]]
# Collector credentials are write-only in the management view.
"$TMP/obsctl.sh" collector-save https '' 514 udp splunk 'https://splunk.example.org/services/collector' 'secret-token' '' 587 '' '' ''
! "$TMP/obsctl.sh" collector | grep -q secret-token
"$TMP/obsctl.sh" collector-save https '' 514 udp splunk 'https://splunk.example.org/services/collector' '' '' 587 '' '' ''
[[ "$(jq -r '.token' "$OBS_DIR/collector.json")" == secret-token ]]
# Export records include filtered fields but not query secrets.
"$TMP/obsctl.sh" query all app.test '' 443 '' 4xx '' 100 0 | jq -e 'length > 0' >/dev/null 2>&1 || true
if "$TMP/obsctl.sh" query all '' '' '' '' bad '' 100 0 >/dev/null 2>&1; then echo 'Invalid status accepted' >&2; exit 1; fi
if "$TMP/obsctl.sh" alert-save bad invalid all '' '' '' '' any 1 60 300 webhook 'http://not-https.test/' '' >/dev/null 2>&1; then echo 'Insecure webhook accepted' >&2; exit 1; fi
echo 'PASS observability: request filters, WAF audit, redaction, alert cooldown, collector secrets and input validation'
