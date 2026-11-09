#!/usr/bin/env bash
# OTLP/HTTP end-to-end worker and configuration regression coverage.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mock" "$TMP/logs"
cat > "$TMP/common.sh" <<'COMMON'
DATA_DIR="${DATA_DIR:?}"
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
export DATA_DIR="$TMP" LITEEDGE_TEST_COMMON="$TMP/common.sh"
export EVENTS_FILE="$TMP/logs/events.jsonl" AUDIT_FILE="$TMP/logs/modsec_audit.json"
export OBS_DIR="$TMP/observability" TEST_DELIVERY_LOG="$TMP/deliveries.txt"
NOW="$(date +%s)"
printf '{"type":"http","epoch":%s,"host":"app.test","method":"GET","uri":"/api/fail","status":503,"message":"backend unavailable","blocked":false}\n' "$NOW".123 > "$EVENTS_FILE"
: > "$AUDIT_FILE"
: > "$TEST_DELIVERY_LOG"
"$TMP/obsctl.sh" collector-save otlp '' 514 udp generic 'http://otel.internal:4318/v1/logs' '' 'liteedge.proxy'
[[ "$(jq -r '.service_name' "$OBS_DIR/collector.json")" == liteedge.proxy ]]
PATH="$TMP/mock:$PATH" "$ROOT/bin/obs-worker.sh" tick
grep -qF 'http://otel.internal:4318/v1/logs' "$TEST_DELIVERY_LOG"
payload="$(grep '^{"resourceLogs":' "$TEST_DELIVERY_LOG" | tail -n1)"
[[ -n "$payload" ]] || { echo 'No OTLP/HTTP JSON payload delivered' >&2; exit 1; }
jq -e --arg timestamp "$NOW"123000000 '
  .resourceLogs[0] as $logs
  | ($logs.resource.attributes | any(.[]; .key=="service.name" and .value.stringValue=="liteedge.proxy"))
    and ($logs.scopeLogs[0].scope.name=="liteedge.observability")
    and ($logs.scopeLogs[0].logRecords[0] as $log |
      $log.timeUnixNano==$timestamp and
      $log.severityNumber==17 and $log.severityText=="ERROR" and
      $log.body.stringValue=="backend unavailable" and
      any($log.attributes[]; .key=="liteedge.status" and .value.intValue=="503") and
      any($log.attributes[]; .key=="liteedge.blocked" and .value.boolValue==false) and
      any($log.attributes[]; .key=="liteedge.uri" and .value.stringValue=="/api/fail"))
' <<< "$payload" >/dev/null
# A destination change must never leak the token of the previous exporter.
"$TMP/obsctl.sh" collector-save https '' 514 udp splunk 'https://splunk.internal/services/collector' 'splunk-secret'
"$TMP/obsctl.sh" collector-save otlp '' 514 udp generic 'http://otel.internal:4318/v1/logs' '' 'liteedge'
[[ "$(jq -r '.token' "$OBS_DIR/collector.json")" == "" ]]
if "$TMP/obsctl.sh" collector-save otlp '' 514 udp generic 'http://otel.internal:4318/v1/logs' 'insecure-secret' >/dev/null 2>&1; then
  echo 'Accepted an OTLP token over plaintext HTTP' >&2; exit 1
fi
for bad_url in 'https://otel.internal:4318/v1/metrics' 'http://otel.internal:65536/v1/logs' 'ftp://otel.internal/v1/logs'; do
  if "$TMP/obsctl.sh" collector-save otlp '' 514 udp generic "$bad_url" '' >/dev/null 2>&1; then
    echo "Accepted invalid OTLP endpoint: $bad_url" >&2; exit 1
  fi
done
if "$TMP/obsctl.sh" collector-save otlp '' 514 udp generic 'https://otel.internal/v1/logs' '' 'bad service/name' >/dev/null 2>&1; then
  echo 'Accepted invalid service name' >&2; exit 1
fi
# OTLP Bearer token is write-only to the UI and sent only over HTTPS.
"$TMP/obsctl.sh" collector-save otlp '' 514 udp generic 'https://otel.internal/v1/logs' 'otlp-secret' 'api.edge'
! "$TMP/obsctl.sh" collector | grep -q 'otlp-secret'
printf '0\n' > "$OBS_DIR/events.offset"
: > "$TEST_DELIVERY_LOG"
PATH="$TMP/mock:$PATH" "$ROOT/bin/obs-worker.sh" tick
grep -qF 'Authorization: Bearer otlp-secret' "$TEST_DELIVERY_LOG"
grep -qF 'https://otel.internal/v1/logs' "$TEST_DELIVERY_LOG"
# OTLP HTTP 200 partial success is not delivery success if records were rejected.
mkdir -p "$TMP/rejected"
cat > "$TMP/rejected/curl" <<'REJECT_CURL'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"partialSuccess":{"rejectedLogRecords":"1","errorMessage":"queue full"}}'
REJECT_CURL
chmod +x "$TMP/rejected/curl"
printf '0\n' > "$OBS_DIR/events.offset"
if PATH="$TMP/rejected:$PATH" "$ROOT/bin/obs-worker.sh" tick >/dev/null 2>&1; then
  echo 'Worker accepted OTLP partial rejection' >&2; exit 1
fi
[[ "$(cat "$OBS_DIR/events.offset")" == 0 ]]
# Failed remote delivery must leave the cursor retryable.
mkdir -p "$TMP/failing"
printf '#!/usr/bin/env bash\nexit 22\n' > "$TMP/failing/curl"
chmod +x "$TMP/failing/curl"
printf '0\n' > "$OBS_DIR/events.offset"
if PATH="$TMP/failing:$PATH" "$ROOT/bin/obs-worker.sh" tick >/dev/null 2>&1; then
  echo 'Worker unexpectedly accepted a failed collector delivery' >&2; exit 1
fi
[[ "$(cat "$OBS_DIR/events.offset")" == 0 ]]
PATH="$TMP/mock:$PATH" "$ROOT/bin/obs-worker.sh" tick
[[ "$(cat "$OBS_DIR/events.offset")" -gt 0 ]]
echo 'PASS OTLP/HTTP JSON export: payload, typed fields, TLS token policy, retry cursor, validation'