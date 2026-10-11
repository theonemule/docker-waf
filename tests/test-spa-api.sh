#!/usr/bin/env bash
set -Eeuo pipefail
IMAGE="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
NAME="liteedge-spa-api-test-$$"
PASS=spa-api-test-only-password
RESP="$TEMP/body"
HEADERS="$TEMP/headers"
COUNT=0
cleanup(){ docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$TEMP"; }
trap cleanup EXIT
sed '/limit_req zone=liteedge_admin burst=/d' "$ROOT/nginx/admin.conf" > "$TEMP/admin.conf"
docker run -d --name "$NAME" -e ADMIN_USER=admin -e "ADMIN_PASSWORD=$PASS" -e LITEEDGE_RESTART_POLICY=no \
  -p 127.0.0.1::9443 -v "$TEMP/admin.conf:/opt/liteedge/etc/nginx/admin.conf.template:ro" "$IMAGE" >/dev/null
PORT="$(docker port "$NAME" 9443/tcp | awk -F: 'END{print $NF}')"
BASE="https://127.0.0.1:$PORT"
for i in $(seq 1 35); do
  code="$(curl --noproxy '*' -ks -o /dev/null -w '%{http_code}' "$BASE/" || true)"
  [[ "$code" == 401 ]] && break
  sleep 1
done
[[ "$code" == 401 ]] || { docker logs "$NAME"; exit 1; }
request(){ curl --noproxy '*' -ks --max-time 35 -D "$HEADERS" -o "$RESP" -w '%{http_code}' "$@"; }
expect(){
  if [[ "$1" != "$2" ]]; then
    echo "FAIL: $3 expected $1 got $2" >&2
    head -c 600 "$RESP" >&2; exit 1
  fi
  COUNT=$((COUNT+1))
}
json(){ jq -e "$1" "$RESP" >/dev/null || { echo "FAIL JSON: $1"; head -c 450 "$RESP"; exit 1; }; COUNT=$((COUNT+1)); }
expect 401 "$(request "$BASE/")" 'SPA shell requires Basic'
expect 401 "$(request "$BASE/assets/spa.js")" 'SPA JS requires Basic'
expect 401 "$(request "$BASE/api/v1/sites")" 'JSON read requires Basic'
expect 401 "$(request -X POST -H 'X-LiteEdge-API: 1' -d host=x.test "$BASE/api/v1/actions/site/save")" 'JSON write requires Basic'
expect 200 "$(request -u "admin:$PASS" "$BASE/")" 'SPA root'
grep -Fq 'src="/assets/spa.js"' "$RESP"
! grep -q '<form' "$RESP"
expect 200 "$(request -u "admin:$PASS" "$BASE/assets/spa.js")" 'SPA JS'
grep -Fq 'credentials:"same-origin"' "$RESP"
! grep -Eq 'location[.]reload[[:space:]]*[(]|location[.]assign[[:space:]]*[(]|window[.]location[.]href[[:space:]]*=' "$RESP"
for part in sites server alerts owasp catalog 'logs?type=http' owasp/rules; do
  expect 200 "$(request -u "admin:$PASS" "$BASE/api/v1/$part")" "API $part"
  grep -Fiq 'Content-Type: application/json' "$HEADERS"
  grep -Fiq 'Cache-Control: no-store' "$HEADERS"
  json 'type=="object"'
done
expect 400 "$(request -u "admin:$PASS" "$BASE/api/v1/logs")" 'Unfiltered log queries are rejected'
json '.ok==false'
expect 200 "$(request -u "admin:$PASS" "$BASE/api/v1/logs?type=http")" 'Filtered logs return JSON'
json '.ok==true and (.events|type)=="array"'
expect 405 "$(request -u "admin:$PASS" -X POST "$BASE/api/v1/sites")" 'GET-only JSON resource'
json '.ok==false'
expect 404 "$(request -u "admin:$PASS" "$BASE/api/v1/unknown")" 'Missing resource'
expect 403 "$(request -u "admin:$PASS" -X POST -d host=test.example "$BASE/api/v1/actions/site/save")" 'CSRF header required'
expect 403 "$(request -u "admin:$PASS" -X POST -H 'X-LiteEdge-API: 1' -H 'Origin: https://evil.example' -d host=test.example "$BASE/api/v1/actions/site/save")" 'Cross-origin blocked'
expect 403 "$(request -u "admin:$PASS" -X POST -H 'X-LiteEdge-API: 1' -H 'Sec-Fetch-Site: cross-site' -d host=test.example "$BASE/api/v1/actions/site/save")" 'Cross-site blocked'
expect 200 "$(request -u "admin:$PASS" -X POST -H 'X-LiteEdge-API: 1' -d host=test.example "$BASE/api/v1/actions/site/save")" 'API site create'
json '.ok==true'
! grep -Fiq 'Location:' "$HEADERS"
expect 200 "$(request -u "admin:$PASS" "$BASE/api/v1/sites")" 'Site list'
json '.sites | any(.host=="test.example")'
expect 200 "$(request -u "admin:$PASS" -X POST -H 'X-LiteEdge-API: 1' -d host=test.example -d match=prefix -d path=/api/ -d target=http://127.0.0.1:12001 -d backends=http://127.0.0.1:12002 "$BASE/api/v1/actions/route/add")" 'API route creation'
expect 200 "$(request -u "admin:$PASS" "$BASE/api/v1/site?host=test.example")" 'Site detail'
json '.site.routes[0].target=="http://127.0.0.1:12001" and .site.routes[0].backends=="http://127.0.0.1:12002"'
expect 400 "$(request -u "admin:$PASS" -X POST -H 'X-LiteEdge-API: 1' -d host=bad/site "$BASE/api/v1/actions/site/save")" 'Invalid input JSON error'
json '.ok==false and (.error|length>0)'
expect 200 "$(request -u "admin:$PASS" -X POST -H 'X-LiteEdge-API: 1' -d smtp_host=smtp.test.example -d smtp_port=587 -d mail_from=alerts@example.org -d smtp_user=notifier -d smtp_password=fixture-secret "$BASE/api/v1/actions/server/smtp/save")" 'SMTP API save'
expect 200 "$(request -u "admin:$PASS" "$BASE/api/v1/server")" 'Server state'
json '.collector.smtp_host=="smtp.test.example"'
! grep -Fq 'fixture-secret' "$RESP"
# Uploads are API actions too: invalid bodies return JSON and HTTP errors,
# not the old legacy text/html response. Valid exports can be imported.
expect 413 "$(request -u "admin:$PASS" -X POST -H 'X-LiteEdge-API: 1' -H 'Content-Type: application/octet-stream' --data-binary '' "$BASE/api/v1/import")" 'Empty archive rejected as JSON'
json '.ok==false and (.error|length>0)'
expect 403 "$(request -u "admin:$PASS" -X POST -H 'Content-Type: application/octet-stream' --data-binary '' "$BASE/api/v1/import")" 'Archive import requires CSRF header'
expect 200 "$(request -u "admin:$PASS" "$BASE/api/v1/export?scope=site&host=test.example&certificates=0")" 'Binary bundle export API'
cp "$RESP" "$TEMP/saved-site.tar.gz"
[[ "$(file -b --mime-type "$TEMP/saved-site.tar.gz" 2>/dev/null || true)" == application/gzip ]] || gzip -t "$TEMP/saved-site.tar.gz"
expect 200 "$(request -u "admin:$PASS" -X POST -H 'X-LiteEdge-API: 1' -H 'Content-Type: application/octet-stream' --data-binary "@$TEMP/saved-site.tar.gz" "$BASE/api/v1/import?scope=site&host=test.example")" 'Bundle import JSON API'
json '.ok==true'
# Upload endpoints are JSON APIs, including validation failures (not text responses).
for endpoint in import owasp/import owasp/crs/import; do
  expect 413 "$(request -u "admin:$PASS" -X POST -H 'X-LiteEdge-API: 1' -H 'Content-Type: application/octet-stream' "$BASE/api/v1/$endpoint")" "Empty $endpoint upload rejected"
  grep -Fiq 'Content-Type: application/json' "$HEADERS"
  json '.ok==false and (.error|length>0)'
done
# An actual exported site can round-trip through the API, without a postback.
curl --noproxy '*' -ks -u "admin:$PASS" -o "$TEMP/export.tar.gz" "$BASE/api/v1/export?scope=site&host=test.example&certificates=0"
tar -tzf "$TEMP/export.tar.gz" >/dev/null
expect 200 "$(request -u "admin:$PASS" -X POST -H 'X-LiteEdge-API: 1' -H 'Content-Type: application/octet-stream' --data-binary @"$TEMP/export.tar.gz" "$BASE/api/v1/import?scope=site&host=test.example")" 'Binary archive API roundtrip'
json '.ok==true'
expect 303 "$(request -u "admin:$PASS" "$BASE/admin/")" 'Legacy bookmark returns to SPA'
grep -Fiq 'Location: /#/sites' "$HEADERS"
expect 303 "$(request -u "admin:$PASS" "$BASE/admin/server")" 'Old Server Settings bookmark redirects to SPA'
grep -Fiq 'Location: /#/server' "$HEADERS"
echo "PASS SPA API: $COUNT assertions; Basic auth, JSON, CSRF, no HTML redirect, pool model, private secrets, legacy compatibility"
