#!/usr/bin/env bash
set -euo pipefail
image="$1";name="le-deadline-$(openssl rand -hex 4)";tmp="$(mktemp -d)"
cleanup(){ rc=$?;if ((rc));then cat "$tmp/response" 2>/dev/null||true;docker logs "$name" --tail 80||true;docker exec "$name" cat /data/logs/deadline-worker.log 2>/dev/null||true;fi;docker rm -fv "$name" >/dev/null 2>&1||true;rm -rf "$tmp";}
trap cleanup EXIT
password="$(openssl rand -hex 24)"
docker run -d --name "$name" -e ADMIN_PASSWORD="$password" -p 127.0.0.1::9443 -p 127.0.0.1::8080 "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
proxy="http://127.0.0.1:$(docker port "$name" 8080/tcp|cut -d: -f2)"
cat >"$tmp/backend.py" <<'PY'
import json,time,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
seen={}
lock=threading.Lock()
class H(BaseHTTPRequestHandler):
    def do_GET(self): self.handle_request()
    def do_POST(self): self.handle_request()
    def handle_request(self):
        with lock:
            count=seen.get(self.path,0)+1
            seen[self.path]=count
            with open("/tmp/deadline-attempts.jsonl","a") as f:
                f.write(json.dumps({"path":self.path,"method":self.command,"time":time.monotonic(),"count":count})+"\n")
        if "slow" in self.path or "attempt-timeout" in self.path and count==1:
            time.sleep(.7)
        if "trickle" in self.path:
            chunk=b"x"*(10000 if "large" in self.path else 10)
            self.send_response(200);self.send_header("Content-Length",str(len(chunk)*10));self.end_headers()
            try:
                for i in range(10):self.wfile.write(chunk);self.wfile.flush();time.sleep(.12)
            except OSError:pass
            return
        if "retry" in self.path and count==1 or "all-fail" in self.path or "post" in self.path:
            self.send_response(503);self.end_headers();return
        content=self.rfile.read(int(self.headers.get("Content-Length",0)))
        body=json.dumps({"path":self.path,"host":self.headers.get("Host"),"control":self.headers.get("X-LiteEdge-Deadline-Config"),"x-test":self.headers.get("X-Test"),"body":content.decode()}).encode()
        self.send_response(200);self.send_header("Content-Length",str(len(body)));self.send_header("X-LiteEdge-Deadline-Backend","spoofed");self.send_header("X-LiteEdge-Deadline-Attempts","999");self.end_headers()
        try:self.wfile.write(body)
        except OSError:pass
ThreadingHTTPServer(("127.0.0.1",12001),H).serve_forever()
PY
docker cp "$tmp/backend.py" "$name:/tmp/backend.py"
docker exec -d "$name" python3 /tmp/backend.py
for i in $(seq 1 100);do if curl -ksf -u "admin:$password" "$admin/api/v1/sites" >/dev/null 2>&1;then break;fi;test "$i" -lt 100;sleep .25;done
api(){ local action="$1";shift;curl -ksS -u "admin:$password" -H 'X-LiteEdge-API: 1' -o "$tmp/response" -w '%{http_code}' "$@" "$admin/api/v1/actions/$action"; }
get(){ curl -sS --max-time 5 -H 'Host: deadlines.example.test' "$@"; }
test "$(api site/save -d host=deadlines.example.test)" = 200
add(){ local path="$1" config="$2";shift 2;api route/add -d host=deadlines.example.test -d match=prefix -d "path=$path" -d target=http://127.0.0.1:12001 -d force_https=0 -d waf=1 --data-urlencode "features_json=$config" "$@"; }
test "$(add /short '{"deadlines":{"request_ms":300}}')" = 200
test "$(add /backend '{"deadlines":{"request_ms":1500,"backend_ms":250}}')" = 200
test "$(add /disabled '{"deadlines":{"request_ms":0,"backend_ms":0}}')" = 200
test "$(add /retry '{"deadlines":{"request_ms":1800,"backend_ms":250},"retry":{"attempts":1,"codes":[503],"backoff_ms":200}}')" = 200
test "$(add /budget '{"deadlines":{"request_ms":300},"retry":{"attempts":2,"codes":[503],"backoff_ms":500}}')" = 200
test "$(add /rewrite '{"deadlines":{"request_ms":2000},"rewrite":{"hostname":"rewritten.example.test","path":{"type":"prefix","value":"/new"}},"request_headers":[{"op":"set","name":"X-Test","value":"yes"}]}')" = 200
test "$(add /invalid '{"deadlines":{"request_ms":100,"backend_ms":200}}')" = 400
test "$(add /invalid-origin '{"deadlines":{"request_ms":1000}}' -d target=http://127.0.0.1:12001/base)" = 400
get -D "$tmp/headers" -H 'X-LiteEdge-Deadline-Config: malicious' "$proxy/short/fast?a=1%20x" | jq -e '.path=="/short/fast?a=1%20x" and .host=="deadlines.example.test" and .control==null'
! grep -qi "^X-LiteEdge-Deadline-" "$tmp/headers"
get "$proxy/rewrite/a?x=1" | jq -e '.path=="/new/a?x=1" and .host=="rewritten.example.test" and .["x-test"]=="yes"'
test "$(get -o /dev/null -w '%{http_code}' -H 'Upgrade: websocket' -H 'Connection: Upgrade' "$proxy/short/upgrade")" = 400
test "$(get -o /dev/null -w '%{http_code}' "$proxy/short/slow")" = 504
test "$(get -o /dev/null -w '%{http_code}' "$proxy/backend/slow")" = 504
test "$(get -o /dev/null -w '%{http_code}' "$proxy/disabled/slow")" = 200
# A response that continuously emits bytes still meets the absolute deadline.
test "$(get -o /dev/null -w '%{http_code}' "$proxy/backend/trickle")" = 504
# A large response can already have committed headers; it must be truncated
# rather than falsely completing successfully after its absolute deadline.
set +e
get -o "$tmp/trickle" "$proxy/backend/trickle-large"
rc=$?
set -e
test "$rc" != 0
test "$(wc -c <"$tmp/trickle")" -lt 100000
test "$(get -o /dev/null -w '%{http_code}' "$proxy/retry/once")" = 200
test "$(get -o /dev/null -w '%{http_code}' "$proxy/retry/attempt-timeout")" = 200
test "$(get -o /dev/null -w '%{http_code}' "$proxy/budget/all-fail")" = 504
test "$(get -o /dev/null -w '%{http_code}' --data 'value=1' "$proxy/retry/post")" = 503
docker exec "$name" cat /tmp/deadline-attempts.jsonl | jq -s -e '
([.[]|select(.path=="/retry/once")] | length==2 and (.[1].time-.[0].time)>=0.19)
and ([.[]|select(.path=="/retry/attempt-timeout")] | length==2 and (.[1].time-.[0].time)>=0.43)
and ([.[]|select(.path=="/budget/all-fail")] | length==1)
and ([.[]|select(.path=="/retry/post")] | length==1)'
test "$(get -o /dev/null -w '%{http_code}' --get --data-urlencode 'q=<script>alert(1)</script>' "$proxy/short/blocked")" = 403
docker exec "$name" cat /tmp/deadline-attempts.jsonl | jq -s -e 'all(.[];(.path|startswith("/short/blocked") or startswith("/short/upgrade")|not))'
curl -ksSf -u "admin:$password" "$admin/api/v1/site?host=deadlines.example.test" | jq -e 'any(.site.routes[];.path=="/retry" and .features.deadlines.backend_ms==250 and .features.retry.backoff_ms==200)'
docker exec "$name" cat /data/logs/events.jsonl | jq -s -e 'any(.[];.uri=="/retry/once" and .upstream_addr=="127.0.0.1:12001" and .backend_attempts=="2")'
echo 'PASS deadline, disabled timeout, continuous-body cancellation, retry backoff/budget, non-replayed POST, WAF, rewrite, control-header isolation and API round trip'
