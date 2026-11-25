#!/usr/bin/env bash
# Migrate real released 3.x appliance data into the candidate image. No live services.
set -Eeuo pipefail
candidate="${1:?candidate image required}"
previous="${2:?previous image required}"
suffix="$(openssl rand -hex 5)"
edge="le-upgrade-edge-$suffix"
app="le-upgrade-backend-$suffix"
net="le-upgrade-net-$suffix"
volume="le-upgrade-state-$suffix"
tmp="$(mktemp -d)"
cleanup(){
 rc=$?
 if ((rc));then docker logs "$edge" >&2 || true; docker exec "$edge" sh -c "find /data/sites -type f; cat /data/sites/upgrade.test.routes/*.route" >&2 || true;fi
 docker rm -f "$edge" "$app" >/dev/null 2>&1 || true
 docker volume rm "$volume" >/dev/null 2>&1 || true
 docker network rm "$net" >/dev/null 2>&1 || true
 rm -rf "$tmp"
 exit "$rc"
}
trap cleanup EXIT
docker network create "$net" >/dev/null
docker volume create "$volume" >/dev/null
cat >"$tmp/backend.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"upgrade-backend-ok")
HTTPServer(("0.0.0.0",8080),Handler).serve_forever()
PY
chmod 644 "$tmp/backend.py"
docker create --name "$app" --network "$net" --entrypoint python3 "$candidate" /tmp/backend.py >/dev/null
docker cp "$tmp/backend.py" "$app:/tmp/backend.py"
docker start "$app" >/dev/null
target="http://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$app"):8080"
password=fixture-upgrade-test-only
start(){
 docker run -d --name "$edge" --network "$net" -v "$volume:/data" -e ADMIN_PASSWORD="$password" -p 127.0.0.1::9443 -p 127.0.0.1::8080 "$1" >/dev/null
 admin="https://127.0.0.1:$(docker port "$edge" 9443/tcp | awk -F: 'END{print $NF}')"
 public="http://127.0.0.1:$(docker port "$edge" 8080/tcp | awk -F: 'END{print $NF}')"
 for i in $(seq 1 60);do
  if curl -ksf --max-time 3 -u "admin:$password" "$admin/api/v1/sites" >/dev/null;then return;fi
  [[ "$i" -lt 60 ]];sleep .5
 done
}
act(){ curl -ksSf --max-time 60 -u "admin:$password" -H 'X-LiteEdge-API: 1' "$@" | jq -e '.ok==true' >/dev/null; }
route(){ curl -ksSf --max-time 10 -u "admin:$password" "$admin/api/v1/site?host=upgrade.test" | jq -cS '.site.routes[] | select(.path=="/api") | {path,match,target,backends,waf,waf_pl,force_https,timeout,methods,rewrite_enabled,health_enabled,lb_mode}'; }
auth_cert(){ docker exec "$edge" sh -c 'sha256sum /data/auth/.htpasswd /data/certs/_admin/fullchain.pem /data/certs/_admin/privkey.pem'; }
probe(){ curl -sSf --max-time 3 -H 'Host: upgrade.test' "$public/api"; }
echo "Starting previous image $previous"
start "$previous"
act -d host=upgrade.test "$admin/api/v1/actions/site/save"
act --data-urlencode host=upgrade.test --data-urlencode path=/api --data-urlencode match=exact --data-urlencode "target=$target" -d waf=1 -d waf_pl=1 -d force_https=0 -d timeout=77 -d methods=GET,HEAD "$admin/api/v1/actions/route/add"
for i in $(seq 1 30);do if [[ "$(probe 2>/dev/null || true)" == upgrade-backend-ok ]];then break;fi;[[ "$i" -lt 30 ]];sleep .3;done
echo "Previous image serves configured route"
route > "$tmp/route.before"
test -s "$tmp/route.before"
auth_cert > "$tmp/auth.before"
docker exec "$edge" sh -c 'printf "retain-upgrade-log\n" >/data/logs/upgrade-fixture.log'
docker stop -t 2 "$edge" >/dev/null
docker rm "$edge" >/dev/null
# New startup rerenders and validates from existing authoritative state.
echo "Starting candidate $candidate with prior volume"
start "$candidate"
route > "$tmp/route.after"
cmp "$tmp/route.before" "$tmp/route.after"
auth_cert > "$tmp/auth.after"
cmp "$tmp/auth.before" "$tmp/auth.after"
docker exec "$edge" grep -qx retain-upgrade-log /data/logs/upgrade-fixture.log
test "$(probe)" = upgrade-backend-ok
test "$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -H 'Host: upgrade.test' "$public/api?q=%3Cscript%3Ealert(1)%3C/script%3E")" = 403
curl -ksSf -u "admin:$password" "$admin/api/v1/site-inventory" | jq -e '.sites|any(.host=="upgrade.test" and .route_count>=1)' >/dev/null
# Restarting a second time must be safe and preserve the route and credentials.
echo "Verifying candidate restart"
docker restart -t 2 "$edge" >/dev/null
# Ephemeral published ports may change when the Docker daemon restarts a container.
admin="https://127.0.0.1:$(docker port "$edge" 9443/tcp | awk -F: 'END{print $NF}')"
public="http://127.0.0.1:$(docker port "$edge" 8080/tcp | awk -F: 'END{print $NF}')"
for i in $(seq 1 60);do if curl -ksf --max-time 3 -u "admin:$password" "$admin/api/v1/site-inventory" >/dev/null;then break;fi;[[ "$i" -lt 60 ]];sleep .5;done
route >"$tmp/route.restart";cmp "$tmp/route.before" "$tmp/route.restart"
auth_cert >"$tmp/auth.restart";cmp "$tmp/auth.before" "$tmp/auth.restart"
test "$(probe)" = upgrade-backend-ok
echo "PASS $previous -> $candidate: persisted route, authentication, certificate, logs, real WAF/proxy traffic and restart"
