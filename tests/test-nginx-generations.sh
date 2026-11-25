#!/usr/bin/env bash
# Disposable appliance only: mutable workspace corruption and external HUP
# must not expose a partially rendered configuration.
set -euo pipefail
image="$1";name="le-generation-$(openssl rand -hex 4)";tmp=$(mktemp -d)
cleanup(){ rc=$?;if ((rc));then docker logs "$name" --tail 80||true;cat "$tmp/response" 2>/dev/null||true;fi;docker rm -fv "$name" >/dev/null 2>&1||true;rm -rf "$tmp"; }
trap cleanup EXIT
docker run -d --name "$name" -e ADMIN_PASSWORD=generation-test -p 127.0.0.1::9443 -p 127.0.0.1::8080 "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
public="http://127.0.0.1:$(docker port "$name" 8080/tcp|cut -d: -f2)"
for i in $(seq 1 60);do if curl -ksf -u admin:generation-test "$admin/api/v1/sites" >/dev/null;then break;fi;test "$i" -lt 60;sleep .3;done
cat >"$tmp/backend.py" <<'PY'
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import threading
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body=str(self.server.server_port).encode()
        self.send_response(200);self.send_header("Content-Length",str(len(body)));self.end_headers();self.wfile.write(body)
threading.Thread(target=ThreadingHTTPServer(("127.0.0.1",12001),Handler).serve_forever,daemon=True).start()
ThreadingHTTPServer(("127.0.0.1",12002),Handler).serve_forever()
PY
docker cp "$tmp/backend.py" "$name:/tmp/backend.py";docker exec -d "$name" python3 /tmp/backend.py
api(){ local action="$1";shift;curl -ksS -u admin:generation-test -H 'X-LiteEdge-API: 1' -o "$tmp/response" -w '%{http_code}' "$@" "$admin/api/v1/actions/$action"; }
active(){ docker exec "$name" readlink /data/.liteedge-nginx-generations/active.conf; }
traffic(){ curl -fsS --max-time 3 -H 'Host: generation.example.test' "$public/"; }
test "$(api site/save -d host=generation.example.test)" = 200
test "$(api route/add -d host=generation.example.test -d path=/ -d target=http://127.0.0.1:12001 -d waf=1 -d force_https=0)" = 200
test "$(traffic)" = 12001
first=$(active)
docker exec "$name" sh -ec 'base=/data/.liteedge-nginx-generations; config="$base/$(readlink "$base/active.conf")"; grep -F "$base/" "$config"; ! grep -F "/data/nginx/" "$config"; ! grep -F "/tmp/liteedge-run/reload-ack.conf" "$config"'
# Simulate interrupted render by corrupting a mutable generated include.
docker exec "$name" sh -ec 'cp /data/nginx/upstreams.conf /tmp/upstreams.saved; printf "not_a_valid_nginx_directive;\n" >/data/nginx/upstreams.conf'
# Direct HUP of this disposable container's NGINX master sees active generation.
docker exec "$name" sh -ec 'kill -HUP "$(cat /tmp/liteedge-run/nginx.pid)"'
for i in $(seq 1 12);do test "$(traffic)" = 12001;sleep .15;done
test "$(active)" = "$first"
# Candidate fails syntax check before publication.
if docker exec "$name" python3 /opt/liteedge/bin/configlock.py python3 /opt/liteedge/bin/nginx_reload.py /opt/liteedge/sbin/nginx /data/nginx/nginx.conf;then
  echo 'Invalid candidate unexpectedly accepted' >&2;exit 1
fi
test "$(active)" = "$first";test "$(traffic)" = 12001
docker exec "$name" sh -ec 'mv /tmp/upstreams.saved /data/nginx/upstreams.conf'
id=$(curl -ksSf -u admin:generation-test "$admin/api/v1/site?host=generation.example.test"|jq -er '.site.routes[0].id')
# Read traffic through the atomic publication; neither version may produce errors.
( for i in $(seq 1 40);do case "$(traffic)" in 12001|12002) ;; *) exit 1;;esac;sleep .05;done ) & reader=$!
test "$(api route/save -d host=generation.example.test -d "id=$id" -d path=/ -d target=http://127.0.0.1:12002 -d waf=1 -d force_https=0)" = 200
wait "$reader"
second=$(active);test "$second" != "$first";test "$(traffic)" = 12002
# Generation snapshots are excluded from backup; restart regenerates from
# canonical source and cleans stale generations.
# Kubernetes fsGroup may broaden an owned local volume on remount.
docker exec "$name" chmod 2770 /data/.liteedge-nginx-generations
docker restart "$name" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
public="http://127.0.0.1:$(docker port "$name" 8080/tcp|cut -d: -f2)"
for i in $(seq 1 60);do
 if curl -ksf -u admin:generation-test "$admin/api/v1/sites" >/dev/null;then break;fi
 test "$i" -lt 60;sleep .3
done
docker exec -d "$name" python3 /tmp/backend.py
for i in $(seq 1 60);do
 if [[ "$(traffic 2>/dev/null||true)" == 12002 ]];then break;fi
 test "$i" -lt 60;sleep .3
done
test "$(active)" != "$second"
docker exec "$name" python3 -c 'import os;assert os.stat("/data/.liteedge-nginx-generations").st_mode & 0o7777 == 0o700'
docker exec "$name" sh -ec 'test "$(find /data/.liteedge-nginx-generations -mindepth 1 -maxdepth 1 -type d -name "gen-*" | wc -l)" -eq 1'
echo 'PASS generation validation, interrupted renderer isolation, external HUP, atomic traffic switch and restart recovery'
