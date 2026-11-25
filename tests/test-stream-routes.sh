#!/usr/bin/env bash
set -euo pipefail
image="$1";name="le-stream-$(openssl rand -hex 4)";tmp="$(mktemp -d)"
cleanup(){ rc=$?;if ((rc));then cat "$tmp/result" 2>/dev/null||true;docker logs "$name" --tail 60||true;docker exec "$name" cat /data/nginx/streams.conf 2>/dev/null||true;fi;docker rm -fv "$name" >/dev/null 2>&1||true;rm -rf "$tmp"; }
trap cleanup EXIT
docker run -d --name "$name" -e ADMIN_PASSWORD=stream-test -e LITEEDGE_EXTRA_TCP_PORTS=9000:19000 -e LITEEDGE_EXTRA_UDP_PORTS=9001:19001 -e LITEEDGE_EXTRA_TLS_PORTS=9444:19444 -p 127.0.0.1::9443 "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
for host in one two;do
 openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$host.example.test" -addext "subjectAltName=DNS:$host.example.test" -keyout "$tmp/$host.key" -out "$tmp/$host.crt" >/dev/null 2>&1
 for ext in key crt;do docker cp "$tmp/$host.$ext" "$name:/tmp/$host.$ext";docker exec -u 0 "$name" chown 10001:10001 "/tmp/$host.$ext";done
done
cat >"$tmp/backend.py" <<'PY'
import socket,socketserver,ssl,threading
class TCP(socketserver.BaseRequestHandler):
    def handle(self):
        data=self.request.recv(4096)
        self.request.sendall(str(self.server.server_address[1]).encode()+b":"+data)
class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        data,s=self.request
        s.sendto(b"udp:"+data,self.client_address)
def tcp(port,identity=None):
    srv=socketserver.ThreadingTCPServer(("127.0.0.1",port),TCP)
    if identity:
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain("/tmp/"+identity+".crt","/tmp/"+identity+".key")
        srv.socket=ctx.wrap_socket(srv.socket,server_side=True)
    srv.serve_forever()
for p,h in [(12001,None),(12003,"one"),(12004,"two")]:
    threading.Thread(target=tcp,args=(p,h),daemon=True).start()
socketserver.ThreadingUDPServer(("127.0.0.1",12002),UDP).serve_forever()
PY
docker cp "$tmp/backend.py" "$name:/tmp/backend.py";docker exec -d "$name" python3 /tmp/backend.py
for i in $(seq 1 100);do if curl -ksf -u admin:stream-test "$admin/api/v1/streams" >/dev/null;then break;fi;test "$i" -lt 100;sleep .25;done
api(){ curl -ksS -u admin:stream-test -H 'X-LiteEdge-API: 1' -o "$tmp/result" -w '%{http_code}' --data-urlencode "streams_json=$1" "$admin/api/v1/actions/stream/save"; }
routes='[{"protocol":"tcp","port":9000,"backends":[{"target":"tcp://127.0.0.1:12001","weight":1}]},{"protocol":"udp","port":9001,"backends":[{"target":"udp://127.0.0.1:12002","weight":1}]},{"protocol":"tls","port":9444,"hostname":"one.example.test","backends":[{"target":"tcp://127.0.0.1:12003","weight":1}]},{"protocol":"tls","port":9444,"hostname":"*.example.test","backends":[{"target":"tcp://127.0.0.1:12004","weight":1}]}]'
test "$(api "$routes")" = 200
docker exec -i "$name" python3 - <<'PY'
import socket,ssl
with socket.create_connection(("127.0.0.1",19000),3) as s:
 s.sendall(b"hello");assert s.recv(4096)==b"12001:hello"
with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
 s.settimeout(3);s.sendto(b"hello",("127.0.0.1",19001));assert s.recv(4096)==b"udp:hello"
for host,peer,port in [("one.example.test","one",12003),("two.example.test","two",12004)]:
 c=ssl.create_default_context(cafile="/tmp/"+peer+".crt")
 with c.wrap_socket(socket.create_connection(("127.0.0.1",19444),3),server_hostname=host) as s:
  s.sendall(b"hello");assert s.recv(4096)==str(port).encode()+b":hello"
for host in ["unrelated.example.org",None]:
 c=ssl._create_unverified_context()
 try:c.wrap_socket(socket.create_connection(("127.0.0.1",19444),3),server_hostname=host)
 except (OSError,ssl.SSLError):pass
 else:raise AssertionError("unexpected TLS handshake")
PY
test "$(api '[{"protocol":"tcp","port":9443,"backends":[{"target":"tcp://127.0.0.1:12001","weight":1}]}]')" = 400
test "$(api '[{"protocol":"udp","port":9001,"backends":[{"target":"tcp://127.0.0.1:12002","weight":1}]}]')" = 400
curl -ksSf -u admin:stream-test "$admin/api/v1/streams"|jq -e '.routes|length==4'
test "$(api '[]')" = 200
docker exec "$name" python3 -c 'import socket; s=socket.socket();s.settimeout(2);assert s.connect_ex(("127.0.0.1",19000))!=0'
echo 'PASS native TCP and UDP forwarding, TLS SNI passthrough with exact/wildcard and unknown-name rejection, admin roundtrip, validation and deletion'
