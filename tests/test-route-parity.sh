#!/usr/bin/env bash
set -euo pipefail
image="$1"; name="le-route-parity-$(openssl rand -hex 4)"; tmp="$(mktemp -d)"
cleanup(){ rc=$?; if ((rc)); then cat "$tmp/response" 2>/dev/null || true; docker logs "$name" --tail 60 || true; fi; docker rm -fv "$name" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
docker run -d --name "$name" -e ADMIN_PASSWORD=parity-test -p 127.0.0.1::9443 -p 127.0.0.1::8080 "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
proxy="http://127.0.0.1:$(docker port "$name" 8080/tcp|cut -d: -f2)"
cat > "$tmp/backend.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body=json.dumps(dict(path=self.path,headers={k.lower():v for k,v in self.headers.items()},port=self.server.server_port)).encode()
        self.send_response(200);self.send_header("X-Response-Set","old");self.send_header("X-Response-Add","original");self.send_header("X-Response-Remove","remove-me");self.send_header("Content-Length",str(len(body)));self.end_headers();self.wfile.write(body)
ThreadingHTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY
docker cp "$tmp/backend.py" "$name:/tmp/backend.py"
docker exec -d "$name" python3 /tmp/backend.py 12001
docker exec -d "$name" python3 /tmp/backend.py 12002
for i in $(seq 1 50); do if curl -ksf -u admin:parity-test "$admin/api/v1/sites" >/dev/null; then break; fi; test "$i" -lt 50; sleep .2; done
api(){ local action="$1";shift;curl -ksS -u admin:parity-test -H 'X-LiteEdge-API: 1' -o "$tmp/response" -w '%{http_code}' "$@" "$admin/api/v1/actions/$action"; }
site(){ curl -ksSf -u admin:parity-test "$admin/api/v1/site?host=parity.example.test"; }
traffic(){ curl -fsS -H 'Host: parity.example.test' "$@"; }
add(){ local path="$1" features="$2";shift 2;test "$(api route/add -d host=parity.example.test -d "path=$path" -d match=prefix -d waf=1 -d force_https=0 --data-urlencode "features_json=$features" "$@")" = 200; }
test "$(api site/save -d host=parity.example.test)" = 200
add / '{}' -d target=http://127.0.0.1:12001
f='{"method":"GET","header_matches":[{"name":"X-Mode","value":"canary"}],"query_matches":[{"name":"version","value":"two"}],"request_headers":[{"op":"set","name":"X-Set","value":"selected"},{"op":"add","name":"X-Mix","value":"added"},{"op":"remove","name":"X-Remove"}],"response_headers":[{"op":"set","name":"X-Response-Set","value":"new"},{"op":"add","name":"X-Response-Add","value":"appended"},{"op":"remove","name":"X-Response-Remove"}],"rewrite":{"hostname":"backend.example.test","path":{"type":"prefix","value":"/v2"}},"schemes":["http"],"precedence":10}'
add /app "$f" -d target=http://127.0.0.1:12002
add /old '{"redirect":{"hostname":"new.example.test","scheme":"https","status_code":302,"path":{"type":"prefix","value":"/new"}},"schemes":["http"]}'
add /weighted '{"request_headers":[{"op":"set","name":"X-Weighted","value":"yes"}]}' -d target=http://127.0.0.1:12001 -d backends=http://127.0.0.1:12002 -d backend_weights=3,1
site > "$tmp/site"
jq -e 'any(.site.routes[]; .path=="/app" and .features.query_matches[0].value=="two" and .features.method=="GET" and .features.rewrite.path.value=="/v2" and .features.schemes==["http"]) and any(.site.routes[]; .path=="/weighted" and .weights==[3,1]) and any(.site.routes[]; .path=="/old" and .features.redirect.path.value=="/new" and .target=="")' "$tmp/site" >/dev/null
for i in $(seq 1 30); do
 if traffic -H 'X-Mode: canary' -H 'X-Mix: original' -H 'X-Remove: delete' "$proxy/app/item?version=two&other=1" 2>/dev/null | jq -e '.port==12002 and .path=="/v2/item?version=two&other=1" and .headers.host=="backend.example.test" and .headers["x-set"]=="selected" and .headers["x-mix"]=="original,added" and (.headers|has("x-remove")|not)' >/dev/null; then break; fi
 test "$i" -lt 30; sleep .25
done
traffic -D "$tmp/response-headers" -o /dev/null -H 'X-Mode: canary' "$proxy/app/item?version=two"
tr -d '\r' < "$tmp/response-headers" > "$tmp/headers"
grep -qi '^x-response-set: new$' "$tmp/headers"
! grep -qi '^x-response-set: old$' "$tmp/headers"
grep -qi '^x-response-add: original$' "$tmp/headers"
grep -qi '^x-response-add: appended$' "$tmp/headers"
! grep -qi '^x-response-remove:' "$tmp/headers"
grep -qi '^x-content-type-options: nosniff$' "$tmp/headers"
grep -qi '^x-frame-options: SAMEORIGIN$' "$tmp/headers"
jq -e 'any(.site.routes[]; .path=="/app" and (.features.response_headers|length)==3)' "$tmp/site" >/dev/null
test "$(api route/add -d host=parity.example.test -d path=/bad -d target=http://127.0.0.1:12001 --data-urlencode 'features_json={"response_headers":[{"op":"remove","name":"X-Frame-Options"}]}')" = 400
traffic -H 'X-Mode: canary' "$proxy/app/item?version=one" | jq -e '.port==12001' >/dev/null
traffic -H 'X-Mode: canary' "$proxy/app/item?Version=two" | jq -e '.port==12001' >/dev/null
traffic -H 'X-Mode: canary' "$proxy/application?version=two" | jq -e '.port==12001' >/dev/null
curl -sS -D "$tmp/redirect" -o /dev/null -H 'Host: parity.example.test' "$proxy/old/item?x=1"
grep -q 'HTTP/1.1 302' "$tmp/redirect"
grep -qi '^location: https://new.example.test/new/item?x=1' "$tmp/redirect"
test "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: parity.example.test' --get --data-urlencode 'q=<script>alert(1)</script>' "$proxy/old/item")" = 403
# A successful save confirms NGINX accepted the reload signal, not that
# every old worker has drained. Wait for the new route before measuring.
for i in $(seq 1 30);do
  if traffic "$proxy/weighted" | jq -e '.headers["x-weighted"]=="yes"' >/dev/null;then break;fi
  test "$i" -lt 30;sleep .25
done
counts=$(for i in $(seq 1 40);do traffic "$proxy/weighted" | jq -er 'select(.headers["x-weighted"]=="yes")|.port';done | sort | uniq -c)
echo "$counts";echo "$counts" | awk '$2==12002 && $1>=7 && $1<=15{ok=1}END{exit !ok}'
id=$(jq -r '.site.routes[]|select(.path=="/app")|.id' "$tmp/site")
# Same object round-trips through admin save with a modified predicate.
new=$(jq -c '.site.routes[]|select(.path=="/app")|.features|.query_matches[0].value="three"' "$tmp/site")
test "$(api route/save -d host=parity.example.test -d "id=$id" -d path=/app -d match=prefix -d waf=1 -d force_https=0 -d target=http://127.0.0.1:12002 --data-urlencode "features_json=$new")" = 200
for i in $(seq 1 30);do if traffic -H 'X-Mode: canary' "$proxy/app/item?version=three" | jq -e '.port==12002' >/dev/null;then break;fi;test "$i" -lt 30;sleep .25;done
traffic -H 'X-Mode: canary' "$proxy/app/item?version=two" | jq -e '.port==12001' >/dev/null
test "$(api route/add -d host=parity.example.test -d path=/bad -d target=http://127.0.0.1:12001 --data-urlencode 'features_json={"request_headers":[{"op":"set","name":"X-Forwarded-For","value":"forged"}]}')" = 400
test "$(api route/add -d host=parity.example.test -d path=/bad -d target=http://127.0.0.1:12001 -d backend_weights=1,2)" = 400
echo 'PASS native advanced feature create/read/update, predicates, header mutations, rewrite, redirect, WAF, weighted pool and validation'
