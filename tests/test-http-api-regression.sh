#!/usr/bin/env bash
# End-to-end management HTTP regression. Runs exclusively against a fresh,
# disposable Docker container, never production state.
set -Eeuo pipefail
IMAGE="${1:?Usage: test-http-api-regression.sh <locally-built-image>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="liteedge-api-regression-$$"
TEMP="$(mktemp -d)"
RESP="$TEMP/response"
PASS='api-regression-test-password'
# Fixture-only template override. Site/route/server changes re-render admin.conf;
# removing the limiter from the *source* avoids transient 503s during coverage.
sed '/limit_req zone=liteedge_admin burst=/d' "$ROOT/nginx/admin.conf" > "$TEMP/admin-no-rate.conf"
count=0
cleanup() {
  if [[ "${KEEP_DEBUG_CONTAINER:-0}" == 1 ]]; then echo "DEBUG_CONTAINER=$NAME"; return; fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$TEMP"
}
trap cleanup EXIT
docker image inspect "$IMAGE" >/dev/null
args=(run -d --name "$NAME" -e ADMIN_USER=admin -e "ADMIN_PASSWORD=$PASS" -e LITEEDGE_RESTART_POLICY=no -p 127.0.0.1::9443
  -v "$TEMP/admin-no-rate.conf:/opt/liteedge/etc/nginx/admin.conf.template:ro")
if [[ "${LITEEDGE_TEST_MOUNT_SOURCE:-0}" == 1 ]]; then
  args+=(-v "$ROOT/cgi/admin.sh:/opt/liteedge/cgi/admin.sh:ro"
         -v "$ROOT/ui/admin.js:/opt/liteedge/ui/admin.js:ro"
         -v "$ROOT/bin/adminctl.sh:/opt/liteedge/bin/adminctl.sh:ro")
fi
args+=("$IMAGE")
docker "${args[@]}" >/dev/null
PORT="$(docker port "$NAME" 9443/tcp | awk -F: 'END {print $NF}')"
[[ "$PORT" =~ ^[0-9]+$ ]]
URL="https://127.0.0.1:$PORT"
ready=0
for _ in $(seq 1 45); do
  http="$(curl --noproxy '*' -ks --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' "$URL/" || true)"
  [[ "$http" == 401 ]] && { ready=1; break; }
  sleep 1
done
[[ "$ready" == 1 ]] || { docker logs "$NAME" | tail -50; echo 'Admin API did not become ready' >&2; exit 1; }


get() { curl --noproxy '*' -ks --connect-timeout 3 --max-time 15 -u "admin:$PASS" -o "$RESP" -w '%{http_code}' "$URL$1"; }
post() {
  local path="$1"; shift
  curl --noproxy '*' -ks --connect-timeout 3 --max-time 20 -u "admin:$PASS"     -X POST -o "$RESP" -w '%{http_code}' "$URL$path" "$@"
}
assert_code() {
  local wanted="$1" actual="$2" label="$3"
  [[ "$actual" == "$wanted" ]] || {
    echo "FAIL $label expected $wanted got $actual" >&2
    head -c 500 "$RESP" >&2
    exit 1
  }
  count=$((count+1))
}
assert_body() {
  grep -Fq -- "$1" "$RESP" || { echo "FAIL missing body text $1" >&2; head -c 500 "$RESP" >&2; exit 1; }
  count=$((count+1))
}
must_redirect() {
  local name="$1"; shift
  assert_code 303 "$(post "$name" "$@")" "POST $name"
}
# Security / auth / method contracts.
assert_code 401 "$(curl --noproxy '*' -ks -o "$RESP" -w '%{http_code}' "$URL/admin/logs")" 'Unauthenticated logs'
assert_code 401 "$(curl --noproxy '*' -ks -X POST -d 'host=x.test' -o "$RESP" -w '%{http_code}' "$URL/admin/site/save")" 'Unauthenticated mutation'
for path in / /admin/site?host=missing.test /admin/owasp /admin/server /admin/logs /admin/alerts /admin/collector; do
  assert_code 200 "$(get "$path")" "GET $path"
done
assert_code 200 "$(get /admin/not-an-endpoint)" 'Unknown endpoint response'
assert_body 'Page not found'
assert_code 200 "$(get '/admin/server')" 'Password settings available'
assert_body 'Administrator password'
assert_body 'action="/admin/password/change"'
# First test the actual backend: a wrong current credential leaves the old
# Basic Auth credential operational; a valid change immediately rejects it.
assert_code 200 "$(post /admin/password/change -d 'current_password=invalid-value' -d 'new_password=example-updated-credential' -d 'confirm_password=example-updated-credential')" 'Reject wrong current password'
assert_body 'Current password is incorrect'
assert_code 200 "$(get '/admin/server')" 'Old credential still valid after failure'
assert_code 200 "$(post /admin/password/change -d "current_password=$PASS" -d 'new_password=example-updated-credential' -d 'confirm_password=example-updated-credential')" 'Change admin password'
assert_body 'Administrator password updated'
assert_code 401 "$(get '/admin/server')" 'Old Basic Auth credential rejected'
PASS='example-updated-credential'
assert_code 200 "$(get '/admin/server')" 'New Basic Auth credential accepted'
# Restart with the same persistent volume to prove credentials do not revert.
docker restart "$NAME" >/dev/null
# Refresh the ephemeral published port after restart.
PORT="$(docker port "$NAME" 9443/tcp | awk -F: 'END {print $NF}')"
URL="https://127.0.0.1:$PORT"
for _ in $(seq 1 30); do
  actual="$(get /admin/server || true)"
  [[ "$actual" == 200 ]] && break
  sleep 1
done
assert_code 200 "$actual" 'New admin credential persists across restart'
assert_code 401 "$(curl --noproxy '*' -ks --connect-timeout 3 -o "$RESP" -w '%{http_code}' -u 'admin:api-regression-test-password' "$URL/admin/server")" 'Old credential stays invalid after restart'

# Initial Logs navigation MUST NOT parse malformed event data.
docker exec -i "$NAME" sh -c 'cat > /data/logs/events.jsonl' <<'INVALID'
this is intentionally not json
INVALID
assert_code 200 "$(get /admin/logs)" 'Logs initial no-query'
assert_body 'No log search has run'
if grep -Fq '<th>Time</th>' "$RESP"; then echo 'Initial query rendered results' >&2; exit 1; fi
count=$((count+1))
assert_code 200 "$(get '/admin/logs?apply=1')" 'Blank filter guard'
assert_body 'Choose at least one filter'
assert_code 200 "$(get '/admin/logs/export?format=csv')" 'Export requires filters'
assert_body 'Choose and apply at least one log filter'
assert_code 200 "$(get '/admin/logs?apply=1&type=http')" 'Explicit query error path'
assert_body 'Request failed'
# Valid event + filtered request. Do not permit initial event loads.
docker exec -i "$NAME" sh -c 'cat > /data/logs/events.jsonl' <<'EVENTS'
{"type":"http","timestamp":"2026-10-09T10:01:01Z","epoch":1791532861,"host":"example.test","route":"prefix:/api","port":"443","method":"GET","status":200,"ip":"127.0.0.1","uri":"/api/ok","request_id":"test-1"}
{"type":"waf","timestamp":"2026-10-09T10:01:02Z","epoch":1791532862,"host":"example.test","route":"prefix:/api","port":"443","method":"POST","status":403,"ip":"127.0.0.1","uri":"/api/attack","action":"blocked","rule_id":"942100"}
EVENTS
assert_code 200 "$(get /admin/logs)" 'No query after events created'
assert_body 'No log search has run'
if grep -Fq 'test-1' "$RESP"; then echo 'Initial query read event data' >&2; exit 1; fi
assert_code 200 "$(get '/admin/logs?apply=1&type=http&host=example.test')" 'Filtered HTTP log query'
assert_body 'Showing 1 matching log entries'
assert_body 'test-1'
assert_code 200 "$(get '/admin/logs?apply=1&type=waf&status=403')" 'Filtered WAF log query'
assert_body '942100'
assert_code 200 "$(get '/admin/logs?apply=1&host=unknown.test')" 'Empty search'
assert_body 'No log entries matched'
assert_code 200 "$(get '/admin/logs?apply=1&status=invalid')" 'Invalid status validation'
assert_body 'Invalid status filter'
assert_code 200 "$(get '/admin/logs/export?apply=1&type=http&format=jsonl')" 'Filtered JSONL export'
assert_body '"request_id":"test-1"'
assert_code 200 "$(get '/admin/logs/export?apply=1&type=waf&format=csv')" 'Filtered CSV export'
assert_body '942100'
assert_code 200 "$(get '/admin/logs/export?apply=1&type=http&format=xml')" 'Invalid export format'
assert_body 'Unsupported export format'

# Real CRUD against disposable persistent state.
must_redirect /admin/site/save -d 'host=example.test' -d 'aliases=alias.example.test'
docker exec "$NAME" sh -c 'test -s /data/sites/example.test.site'
must_redirect /admin/route/add -d 'host=example.test' -d 'match=prefix' -d 'path=/api/' -d 'target=http://127.0.0.1:12345' -d 'timeout=60'
docker exec "$NAME" sh -c 'grep -Rl "^PATH=/api/$" /data/sites/example.test.routes/*.route >/dev/null'
route_id="$(docker exec "$NAME" sh -c 'for f in /data/sites/example.test.routes/*.route; do basename "$f" .route; done' | head -n1)"
[[ "$route_id" =~ ^[a-f0-9]{16}$ ]]
must_redirect /admin/route/save -d "id=$route_id" -d 'host=example.test' -d 'match=prefix' -d 'path=/api/' -d 'target=http://127.0.0.1:23456' -d 'timeout=70'
docker exec "$NAME" sh -c 'grep -Rl "^TARGET=http://127.0.0.1:23456$" /data/sites/example.test.routes/*.route >/dev/null'
assert_code 200 "$(post /admin/route/add -d 'host=example.test' -d 'path=/bad/' -d 'target=file:///etc/passwd')" 'Reject unsafe upstream'
assert_body 'Request failed'
assert_code 200 "$(post /admin/site/save -d 'host=invalid/host')" 'Reject invalid hostname'
assert_body 'Request failed'
must_redirect /admin/cert/email/save -d 'host=example.test' -d 'email=admin@example.org'
docker exec "$NAME" sh -c "grep -Fxq admin@example.org /data/certs/example.test/acme-email"
assert_code 200 "$(post /admin/cert/email/save -d 'host=example.test' -d 'email=broken')" 'Reject invalid ACME email'
assert_body 'Request failed'
must_redirect /admin/alerts/save -d 'id=test-api-alert' -d 'name=API alarm' -d 'type=waf' -d 'status=403' -d 'action=blocked' -d 'threshold=2' -d 'window=60' -d 'cooldown=300' -d 'channel=webhook' -d 'target=https://alerts.example.org/notify' -d 'scopes_json=[]'
docker exec "$NAME" jq -e '.[] | select(.id=="test-api-alert")' /data/observability/alerts.json >/dev/null
must_redirect /admin/alerts/delete -d 'id=test-api-alert'
docker exec "$NAME" jq -e 'length==0' /data/observability/alerts.json >/dev/null
must_redirect /admin/collector/save -d 'mode=off' -d 'protocol=udp' -d 'port=514' -d 'provider=generic'
docker exec "$NAME" jq -e '.mode=="off"' /data/observability/collector.json >/dev/null
assert_code 200 "$(post /admin/collector/save -d 'mode=https' -d 'url=http://insecure.example.org/')" 'Reject insecure collector'
assert_body 'Request failed'
must_redirect /admin/server/save -d 'worker_connections=1024' -d 'keepalive_timeout=65' -d 'header_timeout=15' -d 'body_timeout=15' -d 'send_timeout=30' -d 'route_timeout=60'
assert_code 200 "$(post /admin/server/save -d 'worker_connections=1')" 'Reject unsafe NGINX settings'
assert_body 'Request failed'
must_redirect /admin/route/delete -d 'host=example.test' -d "id=$route_id"
must_redirect /admin/site/delete -d 'host=example.test'



# Raw import/export routes are exercised with the real backend before the
# isolated dispatcher mocks replace any control commands.
for endpoint in /admin/export /admin/owasp/export; do
  assert_code 200 "$(get "$endpoint")" "Export $endpoint GET"
done
for endpoint in /admin/import /admin/owasp/import /admin/owasp/crs/import; do
  assert_code 405 "$(get "$endpoint")" "Raw $endpoint requires POST"
done

# Exhaustive CGI route dispatch contract in a second phase. Mock each backend
# *inside this disposable container only*: no network updates, certificate
# issuance or external plugin writes occur during the dispatcher matrix.
cat > "$TEMP/mock-command" <<'MOCK'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$1" >> /data/regression-dispatch.log
exit 0
MOCK
chmod +x "$TEMP/mock-command"
for backend in sitectl.sh certctl.sh wafctl.sh crsctl.sh wafregistry.sh obsctl.sh serverctl.sh; do
  docker cp "$TEMP/mock-command" "$NAME:/opt/liteedge/bin/$backend"
done
# Every POST management action must reach the correct named backend command
# and return a redirect. Includes network-affecting handlers under mocks.
routes=(
 '/admin/site/save:sitectl.sh' '/admin/site/delete:sitectl.sh'
 '/admin/route/add:sitectl.sh' '/admin/route/save:sitectl.sh'
 '/admin/route/delete:sitectl.sh' '/admin/cert/selfsigned:certctl.sh'
 '/admin/cert/email/save:certctl.sh' '/admin/cert/letsencrypt:certctl.sh'
 '/admin/cert/import:certctl.sh'
 '/admin/waf/disable:sitectl.sh' '/admin/waf/enable:sitectl.sh'
 '/admin/owasp/pl:wafctl.sh' '/admin/owasp/crs/check:crsctl.sh'
 '/admin/owasp/crs/update:crsctl.sh' '/admin/owasp/crs/reset:crsctl.sh'
 '/admin/owasp/catalog/refresh:wafregistry.sh'
 '/admin/owasp/plugin/install:wafregistry.sh'
 '/admin/owasp/plugin/remove:wafregistry.sh'
 '/admin/owasp/plugin/config-save:wafregistry.sh'
 '/admin/owasp/rule/disable:wafctl.sh' '/admin/owasp/rule/enable:wafctl.sh'
 '/admin/owasp/custom/save:wafctl.sh'
 '/admin/owasp/custom/disable:wafctl.sh' '/admin/owasp/custom/enable:wafctl.sh'
 '/admin/owasp/custom/delete:wafctl.sh'
 '/admin/alerts/save:obsctl.sh' '/admin/alerts/delete:obsctl.sh'
 '/admin/collector/save:obsctl.sh' '/admin/server/save:serverctl.sh' '/admin/password/change:adminctl.sh'
 '/admin/config/save:sitectl.sh' '/admin/config/reset:sitectl.sh'
)
for pair in "${routes[@]}"; do
  endpoint="${pair%%:*}" backend="${pair##*:}"
  # The password handler is tested through a real HTTP call above. It is a
  # read-only bind-mount in source-overlay runs, so it is never overwritten.
  if [[ "$endpoint" == /admin/password/change ]]; then
    continue
  fi
  n_before="$(docker exec "$NAME" sh -c 'wc -l </data/regression-dispatch.log' 2>/dev/null || echo 0)"
  must_redirect "$endpoint" -d 'host=example.test' -d 'id=test-id' -d 'rule_id=942100' -d 'pl=1' -d 'email=admin@example.org' -d 'plugin=example' -d 'file=plugin.conf'
  n_after="$(docker exec "$NAME" sh -c 'wc -l </data/regression-dispatch.log')"
  [[ "$n_after" -gt "$n_before" ]] || { echo "FAIL dispatcher did not reach $endpoint" >&2; exit 1; }
  docker exec "$NAME" sh -c 'tail -n 1 /data/regression-dispatch.log' | grep -Fq "$backend "
done
echo "PASS HTTP API full regression: $count assertions, ${#routes[@]} POST dispatcher endpoints, auth, CRUD, validation, logs, exports and WAF"
