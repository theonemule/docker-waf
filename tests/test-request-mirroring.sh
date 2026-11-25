#!/usr/bin/env bash
# Real NGINX, WAF and native management API with disposable local backends.
set -euo pipefail
image="$1"; name="le-mirror-$(openssl rand -hex 4)"; tmp="$(mktemp -d)"
cleanup(){ rc=$?;if ((rc));then cat "$tmp/result" 2>/dev/null||true;docker logs "$name" --tail 30||true;fi;docker rm -fv "$name" >/dev/null 2>&1||true;rm -rf "$tmp"; }
trap cleanup EXIT
password="$(openssl rand -hex 24)"
docker run -d --name "$name" -e ADMIN_PASSWORD="$password" -p 127.0.0.1::9443 -p 127.0.0.1::8080 "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
proxy="http://127.0.0.1:$(docker port "$name" 8080/tcp|cut -d: -f2)"
cat >"$tmp/backend.py" <<'PY'
import json,sys
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.handle_request()
    def do_POST(self):
        self.handle_request()
    def handle_request(self):
        payload=self.rfile.read(int(self.headers.get("Content-Length","0"))).decode()
        entry=dict(method=self.command,path=self.path,body=payload,marker=self.headers.get("X-Test-Marker"),port=self.server.server_port)
        with open("/tmp/mirror-"+str(self.server.server_port)+".jsonl","a") as f:f.write(json.dumps(entry)+"\n")
        result=json.dumps(entry).encode()
        self.send_response(200 if self.server.server_port==12001 else 503);self.send_header("Content-Length",str(len(result)));self.end_headers();self.wfile.write(result)
ThreadingHTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY
docker cp "$tmp/backend.py" "$name:/tmp/backend.py"
for port in 12001 12002 12003;do docker exec -d "$name" python3 /tmp/backend.py "$port";done
for i in $(seq 1 60);do if curl -ksSf -u "admin:$password" "$admin/api/v1/sites" >/dev/null 2>&1;then break;fi;test "$i" -lt 60;sleep .25;done
api(){ local action="$1";shift;curl -ksS -u "admin:$password" -H 'X-LiteEdge-API: 1' -o "$tmp/result" -w '%{http_code}' "$@" "$admin/api/v1/actions/$action"; }
traffic(){ curl -sS -H 'Host: mirror.example.test' "$@"; }
test "$(api site/save -d host=mirror.example.test)" = 200
test "$(api route/add -d host=mirror.example.test -d path=/shadow -d match=prefix -d target=http://127.0.0.1:12001 -d waf=1 -d force_https=0 --data-urlencode 'features_json={"mirrors":["http://127.0.0.1:12002","http://127.0.0.1:12003"]}')" = 200
curl -ksSf -u "admin:$password" "$admin/api/v1/site?host=mirror.example.test" >"$tmp/site"
jq -e 'any(.site.routes[];.path=="/shadow" and .features.mirrors==[{target:"http://127.0.0.1:12002",basis_points:10000},{target:"http://127.0.0.1:12003",basis_points:10000}])' "$tmp/site"
id=$(jq -r '.site.routes[]|select(.path=="/shadow")|.id' "$tmp/site")
traffic -f -H 'X-Test-Marker: mirror-test' -H 'Content-Type: application/x-www-form-urlencoded' --data 'value=ordinary' "$proxy/shadow/item?name=example" | jq -e '.port==12001 and .method=="POST" and .path=="/shadow/item?name=example" and .body=="value=ordinary"'
for port in 12002 12003;do
  for i in $(seq 1 40);do
    if docker exec "$name" cat "/tmp/mirror-$port.jsonl" 2>/dev/null|jq -e 'select(.marker=="mirror-test" and .method=="POST" and .path=="/shadow/item?name=example" and .body=="value=ordinary")' >/dev/null;then break;fi
    test "$i" -lt 40;sleep .25
  done
done
# Only the normal public route can trigger the shadow locations.
code="$(traffic -o /dev/null -w '%{http_code}' "$proxy/.liteedge-internal/mirror/$id/0")"
echo "Direct mirror location: $code"; test "$code" = 404
# WAF rule using a standard existing test fixture must stop mirroring too.
code="$(traffic -o /dev/null -w '%{http_code}' -H 'Content-Type: text/plain' -H 'X-Test-Marker: blocked' --data 'value=blocked-content-type' "$proxy/shadow/item")"
echo "WAF denied request: $code"; test "$code" = 403
sleep .5
for port in 12002 12003;do
  test "$(docker exec "$name" cat "/tmp/mirror-$port.jsonl"|wc -l)" = 1
done
test "$(api route/add -d host=mirror.example.test -d path=/invalid -d target=http://127.0.0.1:12001 -d force_https=0 --data-urlencode 'features_json={"mirrors":["http://127.0.0.1:12002"],"rewrite":{"hostname":"other.example.test"}}')" = 400
echo 'PASS native mirror body/method/URI, multiple shadows, ignored shadow errors, WAF denial, internal location and transform validation'
test "$(api route/add -d host=mirror.example.test -d path=/sample -d match=prefix -d target=http://127.0.0.1:12001 -d waf=1 -d force_https=0 --data-urlencode 'features_json={"mirrors":[{"target":"http://127.0.0.1:12002","basis_points":3000},{"target":"http://127.0.0.1:12003","basis_points":0}],"request_headers":[{"op":"set","name":"X-Test-Marker","value":"sampled"}]}')" = 200
for i in $(seq 1 40);do
  if traffic -f "$proxy/sample/ready" 2>/dev/null | jq -e '.port==12001 and .marker=="sampled"' >/dev/null;then break;fi
  test "$i" -lt 40;sleep .25
done
for i in $(seq 1 100);do
  traffic -f "$proxy/sample/$i" | jq -e '.port==12001 and .marker=="sampled"' >/dev/null
done
sleep .5
count=$(docker exec "$name" cat /tmp/mirror-12002.jsonl | jq -s '[.[]|select(.marker=="sampled" and .path!="/sample/ready")]|length')
echo "Sampled requests: $count/100"; test "$count" -ge 12; test "$count" -le 48
test "$(docker exec "$name" cat /tmp/mirror-12003.jsonl | jq -s '[.[]|select(.marker=="sampled")]|length')" = 0
echo 'PASS 30 percent sampling, zero percent disabled, identical transformed header'

