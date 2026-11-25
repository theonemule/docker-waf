#!/usr/bin/env bash
set -euo pipefail
image="$1";name="le-tls-peers-$(openssl rand -hex 4)";tmp="$(mktemp -d)"
cleanup(){ rc=$?;if ((rc));then cat "$tmp/result" 2>/dev/null||true;docker logs "$name" --tail 70||true;fi;docker rm -fv "$name" >/dev/null 2>&1||true;rm -rf "$tmp"; }
trap cleanup EXIT
password="$(openssl rand -hex 24)"
for peer in one two;do
 openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$peer CA" -addext 'basicConstraints=critical,CA:TRUE' -keyout "$tmp/$peer-ca.key" -out "$tmp/$peer-ca.crt" >/dev/null 2>&1
 openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$peer.example.test" -keyout "$tmp/$peer.key" -out "$tmp/$peer.csr" >/dev/null 2>&1
 printf 'basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:%s.example.test\nextendedKeyUsage=serverAuth\n' "$peer" >"$tmp/ext"
 openssl x509 -req -in "$tmp/$peer.csr" -CA "$tmp/$peer-ca.crt" -CAkey "$tmp/$peer-ca.key" -CAcreateserial -days 2 -extfile "$tmp/ext" -out "$tmp/$peer.crt" >/dev/null 2>&1
done
docker run -d --name "$name" -e ADMIN_PASSWORD="$password" -p 127.0.0.1::9443 -p 127.0.0.1::8080 "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
proxy="http://127.0.0.1:$(docker port "$name" 8080/tcp|cut -d: -f2)"
cat >"$tmp/backend.py" <<'PY'
import ssl,sys,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body=str(self.server.server_port).encode()
        self.send_response(200);self.send_header("Content-Length",str(len(body)));self.end_headers();self.wfile.write(body)
def server(port,identity):
    s=ThreadingHTTPServer(("127.0.0.1",port),H)
    if identity:
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain("/tmp/"+identity+".crt","/tmp/"+identity+".key")
        def sni(sock,name,ctx):
            if name!=identity+".example.test":return ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME
        ctx.set_servername_callback(sni)
        s.socket=ctx.wrap_socket(s.socket,server_side=True)
    s.serve_forever()
threading.Thread(target=server,args=(12001,"one"),daemon=True).start()
threading.Thread(target=server,args=(12002,"two"),daemon=True).start()
server(12003,None)
PY
docker cp "$tmp/backend.py" "$name:/tmp/backend.py"
for peer in one two;do for ext in crt key;do docker cp "$tmp/$peer.$ext" "$name:/tmp/$peer.$ext";docker exec -u 0 "$name" chown 10001:10001 "/tmp/$peer.$ext";done;done
docker exec -d "$name" python3 /tmp/backend.py
for i in $(seq 1 100);do if curl -ksf -u "admin:$password" "$admin/api/v1/sites" >/dev/null 2>&1;then break;fi;test "$i" -lt 100;sleep .25;done
api(){ local action="$1";shift;curl -ksS -u "admin:$password" -H 'X-LiteEdge-API: 1' -o "$tmp/result" -w '%{http_code}' "$@" "$admin/api/v1/actions/$action"; }
get(){ curl -sS --max-time 5 -H 'Host: tls-peers.example.test' "$@"; }
test "$(api site/save -d host=tls-peers.example.test)" = 200
config="$(jq -nc --rawfile one "$tmp/one-ca.crt" --rawfile two "$tmp/two-ca.crt" '{backend_tls_peers:{"https://127.0.0.1:12001":{hostname:"one.example.test",ca_certificate:$one},"https://127.0.0.1:12002":{hostname:"two.example.test",ca_certificate:$two}}}')"
add(){ local path="$1" config="$2";shift 2;api route/add -d host=tls-peers.example.test -d match=prefix -d "path=$path" -d target=https://127.0.0.1:12001 -d backends=https://127.0.0.1:12002,http://127.0.0.1:12003 -d backend_weights=1,1,1 -d force_https=0 -d waf=1 --data-urlencode "features_json=$config" "$@"; }
test "$(add /mixed "$config" -d health_enabled=1)" = 200
# Every HTTPS endpoint has distinct CA trust and SNI. The plaintext backend
# is intentional and only receives its own share.
for i in $(seq 1 60);do get "$proxy/mixed/$i";echo;done >"$tmp/pool"
for port in 12001 12002 12003;do grep -qx "$port" "$tmp/pool";done
test "$(grep -Ec '^(12001|12002|12003)$' "$tmp/pool")" = 60
test "$(get -o /dev/null -w '%{http_code}' --get --data-urlencode 'q=<script>alert(1)</script>' "$proxy/mixed/blocked")" = 403
docker exec "$name" bash -ec '
for route in /data/sites/tls-peers.example.test.routes/*.route;do
 for target in https://127.0.0.1:12001 https://127.0.0.1:12002;do
   test "$(python3 /opt/liteedge/bin/backend-tls-probe.py "$route" "$target" /health 3)" = 200
 done
done'
# Swapping one trust anchor must cause only that peer to fail, never
# plaintext fallback or use of another peer's CA.
bad="$(jq -c '.backend_tls_peers["https://127.0.0.1:12002"].ca_certificate=.backend_tls_peers["https://127.0.0.1:12001"].ca_certificate' <<< "$config")"
test "$(add /bad "$bad")" = 200
good=0;failed=0
for i in $(seq 1 60);do
 code="$(get -o "$tmp/body" -w '%{http_code}' "$proxy/bad/$i")"
 case "$code" in 200) good=$((good+1));grep -Eq '^(12001|12003)$' "$tmp/body";;502) failed=$((failed+1));;*) exit 1;;esac
done
test "$good" -gt 0 && test "$failed" -gt 0
missing="$(jq -c 'del(.backend_tls_peers["https://127.0.0.1:12002"])' <<< "$config")"
test "$(add /missing "$missing")" = 400
unused="$(jq -c '.backend_tls_peers["https://127.0.0.1:12004"]=.backend_tls_peers["https://127.0.0.1:12002"]' <<< "$config")"
test "$(add /unused "$unused")" = 400
curl -ksSf -u "admin:$password" "$admin/api/v1/site?host=tls-peers.example.test" | jq -e 'any(.site.routes[];.path=="/mixed" and (.features.backend_tls_peers|length)==2)'
echo "PASS independent trust and SNI, mixed HTTP/HTTPS pool, scoped certificate failure ($failed/60), health probes, WAF and API round trip"
