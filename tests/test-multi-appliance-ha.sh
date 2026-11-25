#!/usr/bin/env bash
# Real provider HTTPS replication + an independent passive-failover NGINX
# front end. All appliances, credentials and networks are disposable.
set -euo pipefail
image="$1"
builder="$2"
suffix="$(openssl rand -hex 4)"
net="le-ha-$suffix"
a="$net-a"; b="$net-b"; backend="$net-backend"; lb="$net-lb"
tmp="$(mktemp -d)"
build_container=""
cleanup(){
 rc=$?
 if [[ "$rc" != 0 ]]; then
   docker logs "$a" --tail 25 2>/dev/null || true
   docker logs "$b" --tail 25 2>/dev/null || true
   docker logs "$lb" --tail 25 2>/dev/null || true
 fi
 [[ -z "$build_container" ]] || docker rm -fv "$build_container" >/dev/null 2>&1 || true
 docker rm -fv "$a" "$b" "$backend" "$lb" >/dev/null 2>&1 || true
 docker network rm "$net" >/dev/null 2>&1 || true
 rm -rf "$tmp"
}
trap cleanup EXIT
umask 077
docker network create "$net" >/dev/null
cat >"$tmp/backend.py" <<'PY'
from http.server import BaseHTTPRequestHandler,HTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body=self.headers.get("X-Revision","missing").encode()
        self.send_response(200)
        self.send_header("Content-Length",str(len(body)))
        self.end_headers()
        self.wfile.write(body)
HTTPServer(("0.0.0.0",8080),Handler).serve_forever()
PY
chmod 644 "$tmp/backend.py"
docker create --name "$backend" --network "$net" --entrypoint python3 "$image" /tmp/backend.py >/dev/null
docker cp "$tmp/backend.py" "$backend:/tmp/backend.py"
docker start "$backend" >/dev/null
backend_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$backend")
admin="$(openssl rand -hex 24)"
setup_edge(){
 local container="$1" label="$2" token port
 token="$(openssl rand -hex 32)"
 printf '%s' "$token" > "$tmp/token-$label"
 docker run -d --name "$container" --network "$net" -p 127.0.0.1::9443 -e ADMIN_PASSWORD="$admin" "$image" >/dev/null
 port=$(docker port "$container" 9443/tcp | cut -d: -f2)
 for i in $(seq 1 60); do
   if curl -ksS -u "admin:$admin" "https://127.0.0.1:$port/api/v1/sites" | jq -e '.ok' >/dev/null 2>&1; then break; fi
   test "$i" -lt 60; sleep .25
 done
 docker exec "$container" sh -ec 'umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout /data/certs/_admin/privkey.pem -out /data/certs/_admin/fullchain.pem -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 >/dev/null 2>&1'
 docker exec "$container" cat /data/certs/_admin/fullchain.pem > "$tmp/ca-$label.crt"
 jq -n --arg hash "$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)" --arg cidr "$backend_ip/32" '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_cidrs:[$cidr],min_waf_pl:1}' |
   docker exec -i "$container" sh -ec 'umask 077; mkdir -p /data/providers; cat >/data/providers/cluster-a.json'
 docker restart "$container" >/dev/null
 wait_edge "$container" "$label"
}
wait_edge(){
 local container="$1" label="$2" port
 port=$(docker port "$container" 9443/tcp | cut -d: -f2)
 for i in $(seq 1 60); do
   if curl -fsS --cacert "$tmp/ca-$label.crt" -H "Authorization: Bearer $(cat "$tmp/token-$label")" "https://127.0.0.1:$port/api/v1/providers/cluster-a/state" | jq -e '.ok' >/dev/null 2>&1; then break; fi
   test "$i" -lt 60; sleep .25
 done
}
setup_edge "$a" a
setup_edge "$b" b
port_a=$(docker port "$a" 9443/tcp | cut -d: -f2)
port_b=$(docker port "$b" 9443/tcp | cut -d: -f2)
jq -n --arg tmp "$tmp" --arg pa "$port_a" --arg pb "$port_b" '[{name:"primary",url:("https://127.0.0.1:"+$pa),provider_id:"cluster-a",token_file:($tmp+"/token-a"),ca_file:($tmp+"/ca-a.crt")},{name:"secondary",url:("https://127.0.0.1:"+$pb),provider_id:"cluster-a",token_file:($tmp+"/token-b"),ca_file:($tmp+"/ca-b.crt")}]' >"$tmp/targets.json"
# Build the real provider package's opt-in test executable.
build_container=$(docker create "$builder" /bin/sh -ec 'go test -mod=readonly -c -o /tmp/provider-live.test ./internal/provider')
docker start -a "$build_container"
docker cp "$build_container:/tmp/provider-live.test" "$tmp/provider-live.test"
chmod 700 "$tmp/provider-live.test"
export LIGHTEDGE_TEST_TARGETS="$tmp/targets.json" LIGHTEDGE_TEST_BACKEND="http://$backend_ip:8080"
run_phase(){ LIGHTEDGE_TEST_PHASE="$1" "$tmp/provider-live.test" -test.run '^TestLiveApplianceReplication$' -test.v; }
run_phase initial
ip_a=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$a")
ip_b=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$b")
cat >"$tmp/lb.conf" <<CONF
pid /tmp/lb.pid;
error_log /dev/stderr warn;
events {}
http {
  access_log off;
  client_body_temp_path /tmp/lb-client;
  proxy_temp_path /tmp/lb-proxy;
  upstream edges {
    server $ip_a:8080 max_fails=1 fail_timeout=2s;
    server $ip_b:8080 max_fails=1 fail_timeout=2s;
  }
  server {
    listen 8080;
    location / {
      proxy_connect_timeout 1s;
      proxy_read_timeout 3s;
      proxy_next_upstream error timeout http_502 http_503 http_504;
      proxy_set_header Host \$http_host;
      proxy_pass http://edges;
      add_header X-Test-Upstream \$upstream_addr always;
    }
  }
}
CONF
chmod 644 "$tmp/lb.conf"
docker create --name "$lb" --network "$net" -p 127.0.0.1::8080 --entrypoint /bin/sh "$image" -ec 'mkdir -p /tmp/liteedge-run; exec /opt/liteedge/sbin/nginx -p /tmp -c /tmp/lb.conf -g "daemon off;"' >/dev/null
docker cp "$tmp/lb.conf" "$lb:/tmp/lb.conf"
docker start "$lb" >/dev/null
url="http://127.0.0.1:$(docker port "$lb" 8080/tcp | cut -d: -f2)/"
traffic(){ curl -fsS --max-time 6 -H 'Host: ha.apps.example.test' "$url"; }
for i in $(seq 1 30); do
 if [[ "$(traffic 2>/dev/null || true)" == one ]]; then break; fi
 test "$i" -lt 30; sleep .25
done
for i in $(seq 1 10); do [[ "$(traffic)" == one ]]; done
echo 'PASS both targets receive the initial snapshot'
docker stop "$b" >/dev/null
for i in $(seq 1 8); do [[ "$(traffic)" == one ]]; done
run_phase outage
for i in $(seq 1 30); do
 if [[ "$(traffic 2>/dev/null || true)" == two ]]; then break; fi
 test "$i" -lt 30; sleep .25
done
for i in $(seq 1 8); do [[ "$(traffic)" == two ]]; done
echo 'PASS external load-balancer failover and healthy target update during outage'
docker start "$b" >/dev/null
wait_edge "$b" b
# Docker may reassign an ephemeral host port on restart. Refresh only the
# test endpoint, keeping the same provider identity, CA and persisted data.
port_b=$(docker port "$b" 9443/tcp | cut -d: -f2)
jq --arg p "$port_b" '.[1].url=("https://127.0.0.1:"+$p)' "$tmp/targets.json" > "$tmp/targets-new"
mv "$tmp/targets-new" "$tmp/targets.json"
run_phase recovery
# Configuration application signals NGINX to reload; wait for the actual
# recovered worker to serve the updated snapshot, not merely its API revision.
for i in $(seq 1 40); do
  if [[ "$(docker exec "$b" curl -fsS --max-time 2 -H 'Host: ha.apps.example.test' http://127.0.0.1:8080/ 2>/dev/null || true)" == two ]]; then break; fi
  test "$i" -lt 40; sleep .25
done
test "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$b")" = "$ip_b"
# Wait for the external balancer's passive failure window to expire, then
# confirm both appliances actually serve the recovered snapshot.
sleep 3
for i in $(seq 1 20); do
  [[ "$(curl -fsS --max-time 6 -D "$tmp/lb-headers" -H 'Host: ha.apps.example.test' "$url")" == two ]]
  tr -d '\r' < "$tmp/lb-headers" | grep -i '^X-Test-Upstream:' >> "$tmp/upstreams"
done
grep -F "$ip_a:8080" "$tmp/upstreams" >/dev/null
grep -F "$ip_b:8080" "$tmp/upstreams" >/dev/null
echo 'PASS independent revisions, recovered target catches up without reloading unchanged primary'
