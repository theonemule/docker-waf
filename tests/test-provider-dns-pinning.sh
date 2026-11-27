#!/usr/bin/env bash
# Live proof that provider DNS authorization cannot leave dynamic traffic-plane DNS.
set -euo pipefail
image="$1"; suffix="$(openssl rand -hex 5)"
net="le-dns-test-$suffix"; edge="le-dns-edge-$suffix"; app="le-dns-app-$suffix"
tmp="$(mktemp -d)"
cleanup(){
  rc=$?
  if ((rc));then docker logs "$edge" --tail 30 >&2 || true;fi
  docker rm -fv "$edge" "$app" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
docker network create "$net" >/dev/null
dns=app.backends.example.test
docker run -d --name "$app" --network "$net" --network-alias "$dns" --entrypoint python3 "$image" -m http.server 8080 --bind 0.0.0.0 >/dev/null
ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$app")"
token="$(openssl rand -hex 32)"; password="$(openssl rand -hex 24)"
docker run -d --name "$edge" --network "$net" --network-alias forbidden.backends.example.test -p 127.0.0.1::9443 -p 127.0.0.1::8080 -e ADMIN_PASSWORD="$password" "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$edge" 9443/tcp|cut -d: -f2)"
public="http://127.0.0.1:$(docker port "$edge" 8080/tcp|cut -d: -f2)"
for i in $(seq 1 40);do
  if curl -ksf -u "admin:$password" "$admin/api/v1/sites" >/dev/null;then break;fi
  test "$i" -lt 40; sleep .25
done
jq -n --arg hash "$(printf %s "$token"|sha256sum|cut -d' ' -f1)" --arg cidr "$ip/32"   '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_dns_suffixes:["backends.example.test"],backend_cidrs:[$cidr],min_waf_pl:1}' |
  docker exec -i "$edge" sh -c 'umask 077; mkdir -p /data/providers; cat >/data/providers/cluster-a.json'
state="$admin/api/v1/providers/cluster-a/state"
put(){ curl -ksS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -X PUT --data-binary "@$1" "$state"; }
probe(){ curl -sS --max-time 8 -H 'Host: web.apps.example.test' -o /dev/null -w '%{http_code}' "$public/"; }
jq -n --arg target "http://$dns:8080" '{revision:0,sites:[{host:"web.apps.example.test",routes:[{match:"prefix",path:"/",target:$target}]}]}' >"$tmp/snapshot"
put "$tmp/snapshot" | jq -e '.revision==1 and .changed' >/dev/null
test "$(probe)" = 200
docker exec "$edge" sh -ec "grep -Fx 'TARGET=http://$ip:8080' /data/sites/web.apps.example.test.routes/*.route; ! grep -F '$dns' /data/nginx/sites/web.apps.example.test.conf"
# Simulate a persisted legacy configuration on this disposable appliance.
docker exec "$edge" sh -ec "sed -i 's|^TARGET=.*|TARGET=http://$dns:8080|' /data/sites/web.apps.example.test.routes/*.route; /opt/liteedge/bin/render-nginx.sh >/dev/null; python3 /opt/liteedge/bin/nginx_reload.py /opt/liteedge/sbin/nginx /data/nginx/nginx.conf"
test "$(probe)" = 503
jq '.revision=1' "$tmp/snapshot" >"$tmp/reconcile"
put "$tmp/reconcile" | jq -e '.revision==2 and .changed' >/dev/null
test "$(probe)" = 200
# Another resolvable name in the approved suffix resolves to the appliance
# itself, outside the explicit backend IP scope.
jq '.revision=2|.sites[0].routes[0].target="http://forbidden.backends.example.test:9443"' "$tmp/snapshot" >"$tmp/denied"
put "$tmp/denied" | jq -e '.ok==false' >/dev/null
test "$(probe)" = 200
echo 'PASS DNS pinning, fail-closed legacy migration, reconciliation and scope rejection'
