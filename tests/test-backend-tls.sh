#!/usr/bin/env bash
set -euo pipefail
image="$1"; name="le-backend-tls-$(openssl rand -hex 4)"; tmp="$(mktemp -d)"
cleanup(){ rc=$?;if ((rc));then cat "$tmp/response" 2>/dev/null||true;docker logs "$name" --tail 60||true;fi;docker rm -fv "$name" >/dev/null 2>&1||true;rm -rf "$tmp";}
trap cleanup EXIT
password="$(openssl rand -hex 24)"
for ca in trusted other;do openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$ca CA" -addext 'basicConstraints=critical,CA:TRUE' -keyout "$tmp/$ca.key" -out "$tmp/$ca.crt" >/dev/null 2>&1;done
for peer in one two wrong;do
  dns=backend.example.test;[[ "$peer" != wrong ]]||dns=wrong.example.test
  openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$dns" -keyout "$tmp/$peer.key" -out "$tmp/$peer.csr" >/dev/null 2>&1
  printf 'basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$dns" >"$tmp/ext"
  openssl x509 -req -in "$tmp/$peer.csr" -CA "$tmp/trusted.crt" -CAkey "$tmp/trusted.key" -CAcreateserial -days 2 -extfile "$tmp/ext" -out "$tmp/$peer.crt" >/dev/null 2>&1
done
docker run -d --name "$name" -e ADMIN_PASSWORD="$password" -p 127.0.0.1::9443 -p 127.0.0.1::8080 "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
proxy="http://127.0.0.1:$(docker port "$name" 8080/tcp|cut -d: -f2)"
cat >"$tmp/backend.py" <<'PY'
import ssl,sys
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body=str(self.server.server_port).encode()
        self.send_response(200);self.send_header("Content-Length",str(len(body)));self.end_headers();self.wfile.write(body)
server=ThreadingHTTPServer(("127.0.0.1",int(sys.argv[1])),H)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(sys.argv[2],sys.argv[3])
def sni(sock,name,ctx):
    if name!="backend.example.test":return ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME
ctx.set_servername_callback(sni)
server.socket=ctx.wrap_socket(server.socket,server_side=True)
server.serve_forever()
PY
docker cp "$tmp/backend.py" "$name:/tmp/backend.py"
for spec in one:12001 two:12002 wrong:12003;do
  peer="${spec%:*}";port="${spec#*:}"
  for ext in crt key;do docker cp "$tmp/$peer.$ext" "$name:/tmp/$peer.$ext";docker exec -u 0 "$name" chown 10001:10001 "/tmp/$peer.$ext";done
  docker exec -d "$name" python3 /tmp/backend.py "$port" "/tmp/$peer.crt" "/tmp/$peer.key"
done
for i in $(seq 1 100);do if curl -ksf -u "admin:$password" "$admin/api/v1/sites" >/dev/null 2>&1;then break;fi;test "$i" -lt 100;sleep .25;done
api(){ local action="$1";shift;curl -ksS -u "admin:$password" -H 'X-LiteEdge-API: 1' -o "$tmp/response" -w '%{http_code}' "$@" "$admin/api/v1/actions/$action"; }
get(){ curl -sS -H 'Host: backend-tls.example.test' "$@";}
test "$(api site/save -d host=backend-tls.example.test)" = 200
feature(){ jq -nc --arg host "$1" --rawfile ca "$2" '{backend_tls:{hostname:$host,ca_certificate:$ca}}'; }
trusted="$(feature backend.example.test "$tmp/trusted.crt")"
untrusted="$(feature backend.example.test "$tmp/other.crt")"
add(){ local path="$1" target="$2" f="$3";shift 3;api route/add -d host=backend-tls.example.test -d "path=$path" -d match=prefix -d "target=$target" -d force_https=0 -d waf=1 --data-urlencode "features_json=$f" "$@"; }
test "$(add /good https://127.0.0.1:12001 "$trusted")" = 200
test "$(add /pool https://127.0.0.1:12001 "$trusted" -d backends=https://127.0.0.1:12002)" = 200
test "$(add /bad-ca https://127.0.0.1:12001 "$untrusted")" = 200
test "$(add /bad-name https://127.0.0.1:12003 "$trusted")" = 200
# The deadline worker must use the same explicit trust and SNI as NGINX.
with_deadline(){ jq -c '.+{deadlines:{request_ms:1000,backend_ms:500}}' <<< "$1"; }
test "$(add /deadline-good https://127.0.0.1:12001 "$(with_deadline "$trusted")")" = 200
test "$(add /deadline-ca https://127.0.0.1:12001 "$(with_deadline "$untrusted")")" = 200
test "$(add /deadline-name https://127.0.0.1:12003 "$(with_deadline "$trusted")")" = 200
test "$(get "$proxy/deadline-good")" = 12001
test "$(get -o /dev/null -w '%{http_code}' "$proxy/deadline-ca")" = 502
test "$(get -o /dev/null -w '%{http_code}' "$proxy/deadline-name")" = 502
echo 'PASS deadline-aware verified TLS and certificate rejection'
test "$(get "$proxy/good")" = 12001
for i in $(seq 1 12);do get "$proxy/pool";echo;done >"$tmp/pool"
grep -qx 12001 "$tmp/pool";grep -qx 12002 "$tmp/pool"
test "$(get -o /dev/null -w '%{http_code}' "$proxy/bad-ca")" = 502
test "$(get -o /dev/null -w '%{http_code}' "$proxy/bad-name")" = 502
test "$(get -o /dev/null -w '%{http_code}' --get --data-urlencode 'q=<script>alert(1)</script>' "$proxy/good")" = 403
test "$(add /plain http://127.0.0.1:12001 "$trusted")" = 400
test "$(add /mixed https://127.0.0.1:12001 "$trusted" -d backends=http://127.0.0.1:12002)" = 400
test "$(add /probe https://127.0.0.1:12001 "$trusted" -d health_enabled=1 -d health_fall=1 -d health_rise=1 -d health_interval=2 -d health_timeout=1)" = 200
test "$(add /probe-ca https://127.0.0.1:12002 "$untrusted" -d health_enabled=1 -d health_fall=1 -d health_rise=1 -d health_interval=2 -d health_timeout=1)" = 200
test "$(add /probe-name https://127.0.0.1:12003 "$trusted" -d health_enabled=1 -d health_fall=1 -d health_rise=1 -d health_interval=2 -d health_timeout=1)" = 200
# Run the real probe helper against the persisted native route records.
docker exec "$name" bash -ec '
for route in /data/sites/backend-tls.example.test.routes/*.route; do
  path=$(sed -n "s/^PATH=//p" "$route")
  target=$(sed -n "s/^TARGET=//p" "$route")
  case "$path" in
    /probe) test "$(python3 /opt/liteedge/bin/backend-tls-probe.py "$route" "$target" /health 3)" = 200 ;;
    /probe-ca|/probe-name) if python3 /opt/liteedge/bin/backend-tls-probe.py "$route" "$target" /health 3; then exit 1; fi ;;
  esac
done'
# Verify the real health worker records the certificate failures, not just
# the standalone probe's exit code. Use a separate observation directory
# to avoid racing the appliance's periodic health worker.
docker exec "$name" bash -ec '
export OBS_DIR=/tmp/verified-tls-health-test
export EVENTS_FILE=/tmp/verified-tls-health-events.jsonl
/opt/liteedge/bin/health-worker.sh tick
for route in /data/sites/backend-tls.example.test.routes/*.route; do
  path=$(sed -n "s/^PATH=//p" "$route")
  target=$(sed -n "s/^TARGET=//p" "$route")
  id=$(sed -n "s/^ID=//p" "$route")
  key=$(printf "%s|%s|%s" backend-tls.example.test "$id" "$target"|sha256sum|cut -c1-32)
  case "$path" in
    /probe) jq -e ".state==\"up\" and .successes>=1" "$OBS_DIR/health/$key.json" ;;
    /probe-ca|/probe-name) jq -e ".state==\"down\" and .failures>=1" "$OBS_DIR/health/$key.json" ;;
  esac
done
jq -s -e "length==2 and all(.[];.type==\"health\" and .action==\"down\" and .probe_status==\"000\")" "$EVENTS_FILE"
'
echo 'PASS verified health probe trust, SNI and health-worker state transitions'  
curl -ksSf -u "admin:$password" "$admin/api/v1/site?host=backend-tls.example.test" | jq -e 'any(.site.routes[];.path=="/good" and .features.backend_tls.hostname=="backend.example.test" and (.features.backend_tls.ca_certificate|startswith("-----BEGIN CERTIFICATE-----")))'
echo 'PASS verified HTTPS, required SNI, weighted TLS pool, wrong CA/identity rejected, WAF, plaintext/mixed rejection, API round trip'
