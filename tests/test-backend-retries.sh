#!/usr/bin/env bash
set -euo pipefail
image="$1"; name="le-retry-$(openssl rand -hex 4)"; tmp="$(mktemp -d)"
cleanup(){ rc=$?;if ((rc));then cat "$tmp/response" 2>/dev/null||true;docker logs "$name" --tail 50||true;fi;docker rm -fv "$name" >/dev/null 2>&1||true;rm -rf "$tmp";}
trap cleanup EXIT
password="$(openssl rand -hex 24)"
docker run -d --name "$name" -e ADMIN_PASSWORD="$password" -p 127.0.0.1::9443 -p 127.0.0.1::8080 "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
proxy="http://127.0.0.1:$(docker port "$name" 8080/tcp|cut -d: -f2)"
cat >"$tmp/backend.py" <<'PY'
import json,sys
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):self.serve()
    def do_POST(self):self.serve()
    def serve(self):
        data=self.rfile.read(int(self.headers.get("Content-Length","0")))
        p=self.server.server_port
        status=503 if p==12001 or self.path.startswith("/all-fail") else 200
        with open("/tmp/retry-"+str(p)+".jsonl","a") as f:
            f.write(json.dumps(dict(method=self.command,path=self.path,status=status,body=data.decode()))+"\n")
        body=str(p).encode();self.send_response(status);self.send_header("Content-Length",str(len(body)));self.end_headers();self.wfile.write(body)
ThreadingHTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY
docker cp "$tmp/backend.py" "$name:/tmp/backend.py"
for port in 12001 12002;do docker exec -d "$name" python3 /tmp/backend.py "$port";done
for i in $(seq 1 80);do if curl -ksf -u "admin:$password" "$admin/api/v1/sites" >/dev/null 2>&1;then break;fi;test "$i" -lt 80;sleep .25;done
api(){ local action="$1";shift;curl -ksS -u "admin:$password" -H 'X-LiteEdge-API: 1' -o "$tmp/response" -w '%{http_code}' "$@" "$admin/api/v1/actions/$action"; }
get(){ curl -sS -H 'Host: retry.example.test' "$@"; }
test "$(api site/save -d host=retry.example.test)" = 200
for path in retry disabled all-fail;do
  policy='{"retry":{"attempts":1,"codes":[503],"budget_ms":5000}}'
  if [[ "$path" == disabled ]];then policy='{"retry":{"attempts":0}}';fi
  test "$(api route/add -d host=retry.example.test -d "path=/$path" -d match=prefix -d target=http://127.0.0.1:12001 -d backends=http://127.0.0.1:12002 -d backend_weights=1,1 -d max_fails=20 -d force_https=0 -d waf=1 --data-urlencode "features_json=$policy")" = 200
done
curl -ksSf -u "admin:$password" "$admin/api/v1/site?host=retry.example.test" | jq -e 'any(.site.routes[];.path=="/retry" and .features.retry.attempts==1 and .features.retry.codes==[503] and .features.retry.budget_ms==5000)'
# Every GET to the retry route must succeed, including requests first sent
# to the deliberately failing backend. Disabled policy must expose some 503s.
for i in $(seq 1 8);do test "$(get -o "$tmp/body" -w '%{http_code}' "$proxy/retry/$i")" = 200;test "$(cat "$tmp/body")" = 12002;done
failures=0
for i in $(seq 1 8);do
  status="$(get -o /dev/null -w '%{http_code}' "$proxy/disabled/$i")"
  [[ "$status" == 503 ]] && ((failures+=1))
done
test "$failures" -gt 0
# Both peers fail, so exactly two requests (initial plus one retry).
test "$(get -o /dev/null -w '%{http_code}' "$proxy/all-fail/once")" = 503
for port in 12001 12002;do
  test "$(docker exec "$name" cat "/tmp/retry-$port.jsonl"|jq -s '[.[]|select(.path=="/all-fail/once")]|length')" = 1
done
# A non-idempotent POST sent to the failed peer is not replayed.
post_failures=0
for i in $(seq 1 12);do
  status="$(get -o /dev/null -w '%{http_code}' --data 'value=test' "$proxy/retry/post-$i")"
  if [[ "$status" == 503 ]];then
    ((post_failures+=1))
    test "$(docker exec "$name" cat /tmp/retry-12002.jsonl|jq -s --arg p "/retry/post-$i" '[.[]|select(.path==$p)]|length')" = 0
  else
    test "$status" = 200
  fi
done
test "$post_failures" -gt 0
test "$(docker exec "$name" cat /tmp/retry-12001.jsonl|jq -s '[.[]|select(.method=="GET" and (.path|startswith("/retry/")))]|length')" -gt 0
test "$(api route/add -d host=retry.example.test -d path=/invalid -d target=http://127.0.0.1:12001 -d force_https=0 --data-urlencode 'features_json={"retry":{"attempts":1}}')" = 400
echo "PASS retry status selection, one-retry limit, opt-out, non-replayed POST ($post_failures failures), API round trip, single backend rejection"
