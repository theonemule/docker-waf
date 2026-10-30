#!/usr/bin/env bash
# Disposable end-to-end test of per-route HTTP methods, rewrites and X-headers.
set -Eeuo pipefail
IMAGE="$1"
NAME="liteedge-route-qa-$$"
TMP="$(mktemp -d)"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
docker run -d --name "$NAME" -e ADMIN_USER=admin -e ADMIN_PASSWORD=route-test \
  -e LITEEDGE_RESTART_POLICY=no -p 127.0.0.1::9443 -p 127.0.0.1::8080 "$IMAGE" >/dev/null
ADMINPORT="$(docker port "$NAME" 9443/tcp | awk -F: 'END{print $NF}')"
PROXYPORT="$(docker port "$NAME" 8080/tcp | awk -F: 'END{print $NF}')"
ADMIN="https://127.0.0.1:$ADMINPORT"
PROXY="http://127.0.0.1:$PROXYPORT"
cat >"$TMP/echo.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class Echo(BaseHTTPRequestHandler):
    def do_GET(self): self.respond()
    def do_POST(self): self.respond()
    def respond(self):
        data=json.dumps({'path':self.path,'method':self.command,'headers':dict(self.headers)}).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(data)))
        self.end_headers()
        self.wfile.write(data)
HTTPServer(('127.0.0.1',12001),Echo).serve_forever()
PY
docker cp "$TMP/echo.py" "$NAME":/tmp/echo.py
docker exec -d "$NAME" python3 /tmp/echo.py
for ((i=0;i<30;i++)); do
  code="$(curl --noproxy '*' -ks -u admin:route-test -o /dev/null -w '%{http_code}' "$ADMIN/api/v1/sites" || true)"
  [ "$code" = 200 ] && break
  sleep 1
done
[ "$code" = 200 ]
api() {
  curl --noproxy '*' -ksS -u admin:route-test -H 'X-LiteEdge-API: 1' \
    -o "$TMP/api" -w '%{http_code}' "$@" "$ADMIN/api/v1/actions/$ACTION"
}
check() { [ "$1" = "$2" ] || { echo "FAIL $3 expected $1 got $2"; cat "$TMP/api"; exit 1; }; }
ACTION=site/save
check 200 "$(api -d host=routes.test)" 'site'
ACTION=route/add
check 200 "$(api --data-urlencode host=routes.test --data-urlencode match=prefix \
  --data-urlencode path=/legacy/ --data-urlencode target=http://127.0.0.1:12001 \
  --data-urlencode waf=0 --data-urlencode force_https=0 --data-urlencode methods=GET,POST \
  --data-urlencode rewrite_enabled=1 --data-urlencode 'rewrite_pattern=^/legacy/(.*)$' \
  --data-urlencode 'rewrite_replacement=/v2/$1' \
  --data-urlencode $'x_headers=X-App-Route: feature-test\nX-Project-ID: alpha')" 'route'
curl --noproxy '*' -ksS -u admin:route-test "$ADMIN/api/v1/site?host=routes.test" >"$TMP/site"
jq -e '.site.routes[0] | .methods=="GET,POST" and .rewrite_enabled=="1" and .rewrite_replacement=="/v2/$1" and .x_headers=="X-App-Route: feature-test\nX-Project-ID: alpha"' "$TMP/site" >/dev/null
ID="$(jq -r '.site.routes[0].id' "$TMP/site")"
curl --noproxy '*' -sS -H 'Host: routes.test' "$PROXY/legacy/item?foo=bar" >"$TMP/result"
jq -e '.path=="/v2/item?foo=bar" and .headers["X-App-Route"]=="feature-test" and .headers["X-Project-ID"]=="alpha"' "$TMP/result" >/dev/null
check 405 "$(curl --noproxy '*' -sS -X DELETE -H 'Host: routes.test' -o /dev/null -w '%{http_code}' "$PROXY/legacy/item")" 'DELETE blocked'
check 405 "$(curl --noproxy '*' -sS -I -H 'Host: routes.test' -o /dev/null -w '%{http_code}' "$PROXY/legacy/item")" 'HEAD blocked'
check 200 "$(curl --noproxy '*' -sS -X POST -H 'Host: routes.test' -o /dev/null -w '%{http_code}' "$PROXY/legacy/item")" 'POST allowed'
check 400 "$(api --data-urlencode host=routes.test --data-urlencode path=/evil/ --data-urlencode target=http://127.0.0.1:12001 --data-urlencode rewrite_enabled=1 --data-urlencode 'rewrite_pattern=^/bad;return 200' --data-urlencode rewrite_replacement=/ok)" 'regex validation'
check 400 "$(api --data-urlencode host=routes.test --data-urlencode path=/evil/ --data-urlencode target=http://127.0.0.1:12001 --data-urlencode 'x_headers=X-Real-IP: forged')" 'header validation'
check 400 "$(api --data-urlencode host=routes.test --data-urlencode path=/evil/ --data-urlencode target=http://127.0.0.1:12001 --data-urlencode methods=GET,BAD)" 'method validation'
ACTION=route/save
check 200 "$(api --data-urlencode "id=$ID" --data-urlencode host=routes.test --data-urlencode match=prefix --data-urlencode path=/legacy/ --data-urlencode target=http://127.0.0.1:12001 --data-urlencode methods=GET --data-urlencode waf=0 --data-urlencode force_https=0 --data-urlencode rewrite_enabled=0)" 'disable rewrite'
sleep 1 # NGINX gracefully switches workers after a route reload.
curl --noproxy '*' -sS -H 'Host: routes.test' "$PROXY/legacy/item" >"$TMP/result"
jq -e '.path=="/legacy/item"' "$TMP/result" >/dev/null
check 405 "$(curl --noproxy '*' -sS -X POST -H 'Host: routes.test' -o /dev/null -w '%{http_code}' "$PROXY/legacy/item")" 'updated method restriction'
echo 'PASS route features: proxy rewrite, method filtering, headers, JSON round-trip, validation, toggles'
