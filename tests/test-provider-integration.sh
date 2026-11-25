#!/usr/bin/env bash
set -euo pipefail
image="$1"
suffix="$(openssl rand -hex 5)"
net="le-kube-test-$suffix"
edge="le-kube-edge-$suffix"
app="le-kube-app-$suffix"
tmp="$(mktemp -d)"
cleanup() {
  rc=$?
  if [[ "$rc" != 0 ]]; then
    [[ ! -f "$tmp/result" ]] || jq 'del(.private_key,.certificate)' "$tmp/result" >&2
    docker logs "$edge" >&2 || true
  fi
  docker rm -fv "$edge" "$app" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
docker network create "$net" >/dev/null
cat >"$tmp/backend.py" <<'PY_SERVER'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class Server(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/headers"):
            body=json.dumps({k.lower():v for k,v in self.headers.items()}).encode()
        else:
            body=b"root-ok"
        self.send_response(200)
        self.send_header("Content-Type","application/json" if self.path.startswith("/headers") else "text/plain")
        self.send_header("Content-Length",str(len(body)))
        self.end_headers()
        self.wfile.write(body)
HTTPServer(("0.0.0.0",8080),Server).serve_forever()
PY_SERVER
chmod 644 "$tmp/backend.py"
docker create --name "$app" --network "$net" --entrypoint python3 "$image" /tmp/backend.py >/dev/null
docker cp "$tmp/backend.py" "$app:/tmp/backend.py"
docker start "$app" >/dev/null
ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$app")"
admin="$(openssl rand -hex 24)"
token="$(openssl rand -hex 32)"
docker run -d --name "$edge" --network "$net" -p 127.0.0.1::9443 -p 127.0.0.1::8080 -p 127.0.0.1::8443 -e ADMIN_PASSWORD="$admin" "$image" >/dev/null
mgmt="https://127.0.0.1:$(docker port "$edge" 9443/tcp | cut -d: -f2)"
http="http://127.0.0.1:$(docker port "$edge" 8080/tcp | cut -d: -f2)"
tlsport="$(docker port "$edge" 8443/tcp | cut -d: -f2)"
for attempt in $(seq 1 40); do
  if curl -ksS -u "admin:$admin" "$mgmt/api/v1/sites" | jq -e '.ok==true' >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 40 ]]; then docker logs "$edge" >&2; exit 1; fi
  sleep .25
done
jq -n --arg hash "$(printf %s "$token" | sha256sum | cut -d' ' -f1)" --arg cidr "$ip/32" \
 '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_cidrs:[$cidr],min_waf_pl:1,allow_wildcards:true,allow_catch_all:true,default_waf_profile:"strict",waf_profiles:{strict:{min_waf_pl:2}}}' |
 docker exec -i "$edge" sh -c 'umask 077; mkdir -p /data/providers; cat >/data/providers/cluster-a.json'
state="$mgmt/api/v1/providers/cluster-a/state"
put() { curl -ksS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -X PUT --data-binary "@$1" "$state"; }
preflight() { curl -ksS -H "Authorization: Bearer $token" -H "Content-Type: application/json" -X POST --data-binary "@$1" "$state"; }
get() { curl -ksS -H "Authorization: Bearer $token" "$state"; }
echo "TEST: unauthenticated"
code="$(curl -ksS -o /dev/null -w '%{http_code}' "$state")"
test "$code" = 401
echo "TEST: authenticated state"
get | jq -e '.revision==0' >/dev/null
echo "TEST: admin isolation"
test "$(curl -ksS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "$mgmt/api/v1/sites")" = 401
echo "TEST: manual create"
curl -ksS -u "admin:$admin" -H 'X-LiteEdge-API: 1' -d 'host=manual.example.test' "$mgmt/api/v1/actions/site/save" | jq -e '.ok' >/dev/null
host=web.apps.example.test
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/key" -out "$tmp/cert" -subj "/CN=$host" -addext "subjectAltName=DNS:$host" >/dev/null 2>&1
jq -n --arg host "$host" --arg target "http://$ip:8080" --rawfile cert "$tmp/cert" --rawfile key "$tmp/key" \
 '{revision:0,sites:[{host:$host,routes:[{match:"prefix",path:"/",target:$target},
  {match:"exact",path:"/headers",target:$target,schemes:["http"],request_headers:[{op:"set",name:"X-Color",value:"blue"},{op:"add",name:"X-Mix",value:"green"},{op:"remove",name:"X-Remove"}]},
  {match:"exact",path:"/headers",target:$target,schemes:["https"],request_headers:[{op:"set",name:"X-Color",value:"purple"}]},
  {match:"exact",path:"/headers",target:$target,schemes:["http"],header_matches:[{name:"X-Mode",value:"Canary"}],request_headers:[{op:"set",name:"X-Color",value:"canary"}]},
  {match:"prefix",path:"/headers",target:$target,schemes:["http"],request_headers:[{op:"set",name:"X-Color",value:"prefix"}]},
  {match:"exact",path:"/redirect",schemes:["http"],redirect:{hostname:"new.apps.example.test",scheme:"https",status_code:301}},
  {match:"exact",path:"/restricted",schemes:["http"],redirect:{hostname:"new.apps.example.test",status_code:302},allow_ips:["192.0.2.0/24"]},
  {match:"exact",path:"/invalid",schemes:["http"],backends:[{target:"invalid",weight:1}]},
  {match:"exact",path:"/empty-service",schemes:["http"],backends:[{target:"unavailable",weight:1}]},
  {match:"exact",path:"/mixed",schemes:["http"],backends:[{target:$target,weight:3},{target:"invalid",weight:1}]}],tls:{certificate:$cert,private_key:$key}}]}' >"$tmp/apply"
echo "TEST: non-mutating validation and attributed errors"
preflight "$tmp/apply" | jq -e '.ok and .revision==0 and .changed==false' >/dev/null
jq '.sites[0].routes[0].waf_profile="unapproved"' "$tmp/apply" > "$tmp/denied"
preflight "$tmp/denied" | jq -e '.ok==false and .rejection=={site_index:0,route_index:0,field:"waf_profile",reason:"WAFProfileDenied"}' >/dev/null
jq '.revision=99' "$tmp/apply" > "$tmp/stale-preflight"
preflight "$tmp/stale-preflight" | jq -e '.ok==false and (has("rejection")|not)' >/dev/null
get | jq -e '.revision==0 and (.hosts|length)==0' >/dev/null
echo "TEST: apply snapshot"
put "$tmp/apply" | tee "$tmp/result" | jq -e '.ok and .revision==1 and .changed' >/dev/null
for attempt in $(seq 1 30); do
  if curl -fsS -H "Host: $host" "$http/" | grep -q root-ok; then break; fi
  if [[ "$attempt" == 30 ]]; then docker logs "$edge" >&2; exit 1; fi
  sleep .2
done
echo "TEST: TLS forwarding"
curl -fsS --noproxy '*' --cacert "$tmp/cert" --resolve "$host:$tlsport:127.0.0.1" "https://$host:$tlsport/" | grep -q root-ok
curl -fsS -H "Host: $host" -H 'X-Color: red' -H 'X-Mix: yellow' -H 'X-Remove: yes' "$http/headers" |
  jq -e '."x-color"=="blue" and ."x-mix"=="yellow,green" and (has("x-remove")|not)' >/dev/null
curl -fsS -H "Host: $host" "$http/headers" | jq -e '."x-mix"=="green"' >/dev/null
curl -fsS --noproxy '*' --cacert "$tmp/cert" --resolve "$host:$tlsport:127.0.0.1" "https://$host:$tlsport/headers" |
  jq -e '."x-color"=="purple"' >/dev/null
curl -fsS -H "Host: $host" -H 'X-Mode: Canary' "$http/headers" | jq -e '."x-color"=="canary"' >/dev/null
curl -fsS -H "Host: $host" -H 'X-Mode: canary' "$http/headers" | jq -e '."x-color"=="blue"' >/dev/null
curl -fsS -H "Host: $host" "$http/headers/child" | jq -e '."x-color"=="prefix"' >/dev/null
curl -fsS -H "Host: $host" "$http/headersother" | jq -e 'has("x-color")|not' >/dev/null
code=$(curl -sS -H "Host: $host" -H 'X-Mode: Canary' --get --data-urlencode 'q=<script>alert(1)</script>' -o /dev/null -w '%{http_code}' "$http/headers")
test "$code" = 403
curl -sS -D "$tmp/redirect-headers" -o /dev/null -H "Host: $host" "$http/redirect?test=one"
grep -q 'HTTP/1.1 301' "$tmp/redirect-headers"
grep -qi '^location: https://new.apps.example.test/redirect?test=one' "$tmp/redirect-headers"
code=$(curl -sS -H "Host: $host" --get --data-urlencode 'q=<script>alert(1)</script>' -o /dev/null -w '%{http_code}' "$http/redirect")
test "$code" = 403
test "$(curl -sS -H "Host: $host" -o /dev/null -w '%{http_code}' "$http/restricted")" = 403
echo "PASS WAF enforcement on conditional routes and redirects, redirect status, URL and IP allowlist"
test "$(curl -sS -H "Host: $host" -o /dev/null -w '%{http_code}' "$http/invalid")" = 500
test "$(curl -sS -H "Host: $host" -o /dev/null -w '%{http_code}' "$http/empty-service")" = 503
echo "PASS unavailable Service returns local HTTP 503 without broader fallback"
good=0; bad=0
for i in $(seq 1 40); do
  code=$(curl -sS -H "Host: $host" -o /dev/null -w '%{http_code}' "$http/mixed")
  case "$code" in 200) good=$((good+1));; 500) bad=$((bad+1));; *) echo "unexpected status $code"; exit 1;; esac
done
test "$good" -ge 25 && test "$bad" -ge 7
echo "PASS weighted invalid backend: $good successful, $bad HTTP 500"
echo "PASS listener-specific routes and set/add/remove headers"
docker exec "$edge" sh -c 'grep -q "^WAF_PL=2$" /data/sites/web.apps.example.test.routes/*.route'
jq '.revision=1' "$tmp/apply" >"$tmp/noop"
# Every native site mutation must honor ownership, not only UI controls.
for action in site/disable route/add route/delete waf/disable config/reset; do
  curl -ksS -u "admin:$admin" -H 'X-LiteEdge-API: 1'     --data-urlencode "host=$host" --data-urlencode "target=http://$ip:8080"     --data-urlencode 'id=0123456789abcdef' --data-urlencode 'rule_id=942100'     "$mgmt/api/v1/actions/$action" | jq -e '.ok==false' >/dev/null
done

put "$tmp/noop" | jq -e '.ok and .revision==1 and (.changed|not)' >/dev/null
curl -ksS -u "admin:$admin" -H 'X-LiteEdge-API: 1' -d "host=$host" "$mgmt/api/v1/actions/site/delete" | jq -e '.ok==false' >/dev/null
jq '.sites[0].routes[0].target="http://127.0.0.1:9443"' "$tmp/noop" >"$tmp/bad"
put "$tmp/bad" | jq -e '.ok==false' >/dev/null
jq '.sites[0].routes[0].waf_profile="unapproved"' "$tmp/noop" >"$tmp/unapproved"
put "$tmp/unapproved" | jq -e '.ok==false' >/dev/null

put "$tmp/apply" | jq -e '.ok==false' >/dev/null
get | jq -e '.revision==1 and (.hosts|length)==1 and (has("private_key")|not)' >/dev/null
curl -fsS -H "Host: $host" "$http/" | grep -q root-ok
echo "TEST: concurrent revision conflict"
jq '.sites[0].routes[0].rate_count=1000' "$tmp/noop" >"$tmp/race-a"
jq '.sites[0].routes[0].rate_count=2000' "$tmp/noop" >"$tmp/race-b"
put "$tmp/race-a" >"$tmp/race-a-result" &
a=$!
put "$tmp/race-b" >"$tmp/race-b-result" &
b=$!
wait "$a"; wait "$b"
jq -s -e 'map(.ok)|sort == [false,true]' "$tmp/race-a-result" "$tmp/race-b-result" >/dev/null
get | jq -e '.revision==2' >/dev/null
echo "TEST: delete"
printf '{"revision":2,"sites":[]}' >"$tmp/delete"
put "$tmp/delete" | jq -e '.ok and .revision==3 and (.hosts|length)==0' >/dev/null
curl -ksS -u "admin:$admin" "$mgmt/api/v1/sites" | jq -e '.sites|any(.host=="manual.example.test") and all(.host!="web.apps.example.test")' >/dev/null
# A dedicated catch-all provider cannot coexist with unrelated manual sites.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/wildcard-key" -out "$tmp/wildcard-cert" -subj '/CN=*.apps.example.test' -addext 'subjectAltName=DNS:*.apps.example.test' >/dev/null 2>&1
jq -n --arg target "http://$ip:8080" --rawfile cert "$tmp/wildcard-cert" --rawfile key "$tmp/wildcard-key" '{revision:3,sites:[{host:"*",listeners:["http"],routes:[{match:"prefix",path:"/",target:$target,schemes:["http"]}]},{host:"*.apps.example.test",listeners:["http","https"],tls:{certificate:$cert,private_key:$key},routes:[{match:"prefix",path:"/",target:$target,schemes:["http","https"],request_headers:[{op:"set",name:"X-Color",value:"wildcard"}]}]},{host:"reserved.apps.example.test",listeners:["http"],routes:[]},{host:"reject.apps.example.test",listeners:["https"],tls_reject:true,routes:[]},{host:"specific.apps.example.test",listeners:["http"],routes:[{match:"exact",path:"/headers/child",host_priority:20,schemes:["http"],target:$target,request_headers:[{op:"set",name:"X-Color",value:"broad-exact"}]},{match:"prefix",path:"/headers",host_priority:1026,schemes:["http"],target:$target,request_headers:[{op:"set",name:"X-Color",value:"specific-prefix"}]},{match:"prefix",path:"/",host_priority:20,schemes:["http"],target:$target,request_headers:[{op:"set",name:"X-Color",value:"fallback"}]}]}]}' > "$tmp/host-patterns"
put "$tmp/host-patterns" | jq -e '.ok==false' >/dev/null
curl -ksS -u "admin:$admin" -H 'X-LiteEdge-API: 1' -d 'host=manual.example.test' "$mgmt/api/v1/actions/site/delete" | jq -e '.ok' >/dev/null
put "$tmp/host-patterns" | jq -e '.ok and .revision==4' >/dev/null
for i in $(seq 1 30); do
  if curl -fsS -H 'Host: nested.sub.apps.example.test' "$http/headers" | jq -e '."x-color"=="wildcard"' >/dev/null; then break; fi
  test "$i" -lt 30; sleep .2
done
curl -fsS -H 'Host: unrelated.example.test' "$http/headers" | jq -e 'has("x-color")|not' >/dev/null
curl -fsS -H 'Host: apps.example.test' "$http/headers" | jq -e 'has("x-color")|not' >/dev/null
test "$(curl -sS -H 'Host: reserved.apps.example.test' -o /dev/null -w '%{http_code}' "$http/")" = 404
curl -fsS --noproxy '*' --cacert "$tmp/wildcard-cert" --resolve "reserved.apps.example.test:$tlsport:127.0.0.1" "https://reserved.apps.example.test:$tlsport/headers" | jq -e '."x-color"=="wildcard"' >/dev/null
curl -fsS -H 'Host: sub.apps.example.test:1234' "$http/headers" | jq -e '.host=="sub.apps.example.test:1234"' >/dev/null
if curl -kfsS --noproxy '*' --resolve "reject.apps.example.test:$tlsport:127.0.0.1" "https://reject.apps.example.test:$tlsport/headers"; then
  echo 'FAIL invalid TLS listener fell through to wildcard'; exit 1
fi
curl -fsS -H 'Host: specific.apps.example.test' "$http/headers/child" | jq -e '."x-color"=="specific-prefix"' >/dev/null
curl -fsS -H 'Host: specific.apps.example.test' "$http/headersother" | jq -e '."x-color"=="fallback"' >/dev/null
echo 'PASS host specificity precedes path match; safe fallback and rejected TLS handshake'


curl -ksS -u "admin:$admin" -H 'X-LiteEdge-API: 1' -d 'host=manual.example.test' "$mgmt/api/v1/actions/site/save" | jq -e '.ok==false' >/dev/null
curl -ksS -u "admin:$admin" --get --data-urlencode 'host=*.apps.example.test' "$mgmt/api/v1/site" | jq -e '.ok and .site.host=="*.apps.example.test"' >/dev/null
printf '{"revision":4,"sites":[]}' > "$tmp/delete-patterns"
put "$tmp/delete-patterns" | jq -e '.ok and .revision==5' >/dev/null
echo 'PASS wildcard and dedicated catch-all, exact listener 404, cross-owner rejection, deletion'
# Ingress wildcard certificate and one-label semantics, including the
# catch-all precedence, must be verified on real NGINX sockets.
jq -n --arg target "http://$ip:8080" --rawfile cert "$tmp/wildcard-cert" --rawfile key "$tmp/wildcard-key" '{revision:5,sites:[{host:"*",listeners:["http"],routes:[{match:"prefix",path:"/",target:$target,schemes:["http"]}]},{host:"*.apps.example.test",wildcard_single:true,listeners:["http","https"],tls:{certificate:$cert,private_key:$key},routes:[{match:"prefix",path:"/",target:$target,schemes:["http","https"],request_headers:[{op:"set",name:"X-Color",value:"single"}],response_headers:[{op:"set",name:"X-Result",value:"single"}]}]}]}' > "$tmp/single-wildcard"
put "$tmp/single-wildcard" | jq -e '.ok and .revision==6' >/dev/null
for i in $(seq 1 30);do
  if curl -fsS -H 'Host: sub.apps.example.test' "$http/headers" | jq -e '."x-color"=="single"' >/dev/null;then break;fi
  test "$i" -lt 30;sleep .25
done
curl -fsS -H 'Host: nested.sub.apps.example.test' "$http/headers" | jq -e 'has("x-color")|not' >/dev/null
curl -fsS -H 'Host: apps.example.test' "$http/headers" | jq -e 'has("x-color")|not' >/dev/null
curl -fsS --noproxy '*' --cacert "$tmp/wildcard-cert" --resolve "sub.apps.example.test:$tlsport:127.0.0.1" -D "$tmp/single-headers" "https://sub.apps.example.test:$tlsport/headers" | jq -e '."x-color"=="single"' >/dev/null
tr -d '\r' < "$tmp/single-headers" | grep -qi '^x-result: single$'
tr -d '\r' < "$tmp/single-headers" | grep -qi '^strict-transport-security: max-age=31536000$'
if curl -kfsS --noproxy '*' --resolve "nested.sub.apps.example.test:$tlsport:127.0.0.1" "https://nested.sub.apps.example.test:$tlsport/headers";then
  echo 'FAIL single-label wildcard accepted nested TLS SNI';exit 1
fi
curl -ksS -u "admin:$admin" --get --data-urlencode 'host=*.apps.example.test' "$mgmt/api/v1/site" | jq -e '.site.wildcard_single and any(.site.routes[]; .features.response_headers[0].value=="single")' >/dev/null
printf '{"revision":6,"sites":[]}' > "$tmp/delete-single"
put "$tmp/delete-single" | jq -e '.ok and .revision==7' >/dev/null
echo 'PASS single-label wildcard HTTP and HTTPS, catch-all fallback, HSTS and API read model'
# Recreate a valid managed snapshot, tamper only generated effective config,
# then submit the identical desired state. The native renderer must repair it.
jq '.revision=7' "$tmp/single-wildcard" > "$tmp/drift"
put "$tmp/drift" | jq -e '.ok and .revision==8' >/dev/null
docker exec "$edge" sh -ec 'printf "\n# generated drift\n" >> /data/nginx/sites/_.apps.example.test.conf'
jq '.revision=8' "$tmp/drift" > "$tmp/repair"
put "$tmp/repair" | jq -e '.ok and .revision==9 and .changed' >/dev/null
docker exec "$edge" sh -ec 'cmp /data/nginx/sites/_.apps.example.test.conf /data/nginx/baselines/_.apps.example.test.conf'
echo 'PASS unchanged desired state repairs managed runtime drift; no manual patch inheritance'
# Hostname-less TLS needs a second explicit authorization flag. The TLS
# certificate is still verified by the client for the requested hostname.
jq --rawfile cert "$tmp/wildcard-cert" --rawfile key "$tmp/wildcard-key" '.revision=9|.sites=[{host:"*",listeners:["http","https"],tls:{certificate:$cert,private_key:$key},routes:[{match:"prefix",path:"/",schemes:["http","https"],target:.sites[0].routes[0].target}]}]' "$tmp/drift" >"$tmp/catchall-tls"
preflight "$tmp/catchall-tls" | jq -e '.ok==false and .rejection.site_index==0' >/dev/null
docker exec "$edge" sh -ec 'jq ".allow_catch_all_tls=true" /data/providers/cluster-a.json >/tmp/provider-tls.json; cat /tmp/provider-tls.json >/data/providers/cluster-a.json'
put "$tmp/catchall-tls" | jq -e '.ok and .revision==10' >/dev/null
for i in $(seq 1 40);do
 if curl -fsS --noproxy '*' --cacert "$tmp/wildcard-cert" --resolve "sub.apps.example.test:$tlsport:127.0.0.1" "https://sub.apps.example.test:$tlsport/headers" 2>/dev/null | jq -e 'has("x-color")|not' >/dev/null;then break;fi
 test "$i" -lt 40;sleep .25
done
curl -fsS -H 'Host: unrelated.example.test' "$http/headers" | jq -e 'has("x-color")|not' >/dev/null
echo 'PASS explicitly authorized catch-all TLS listener and verified certificate'


echo 'PASS: scoped HTTPS API, actual HTTP/TLS forwarding, ownership, stale update, unchanged snapshot, deletion and manual site preservation'

# Administrator credential lifecycle is separate from the machine endpoint.
sleep 3
admin_api="$mgmt/api/v1/provider-admin"
# The shared WAF cache makes previous transactions much faster. Let
# the unchanged 30 requests/minute, burst 30 management limiter drain
# before this separate admin inventory/credential phase.
sleep 35
admin_action() { local action="$1"; shift; sleep 2; curl -ksS -u "admin:$admin" -H 'X-LiteEdge-API: 1' --data-urlencode 'provider_id=cluster-b' "$@" "$mgmt/api/v1/actions/provider/$action"; }
test "$(curl -ksS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "$admin_api")" = 401
curl -ksS -u "admin:$admin" "$admin_api" | jq -e '.ok and any(.providers[]; .id=="cluster-a" and .revision==10 and .hosts==["*"] and .credential_configured and (.policy|has("token_sha256")|not))' >/dev/null
newtoken="$(openssl rand -hex 32)"
newpolicy='{"host_suffixes":["other.example.test"],"backend_cidrs":[],"min_waf_pl":2,"waf_profiles":{"strict":{"min_waf_pl":3}}}'
admin_action save --data-urlencode "provider_token=$newtoken" --data-urlencode "policy_json=$newpolicy" | jq -e '.ok' >/dev/null
state_b="$mgmt/api/v1/providers/cluster-b/state"
curl -ksS -H "Authorization: Bearer $newtoken" "$state_b" | jq -e '.revision==0 and .hosts==[]' >/dev/null
curl -ksS -u "admin:$admin" "$admin_api" | jq -e '.ok and any(.providers[]; .id=="cluster-b" and .policy.min_waf_pl==2 and .credential_configured)' >/dev/null
admin_action save --data-urlencode 'policy_json={"host_suffixes":["other.example.test"],"min_waf_pl":3}' | jq -e '.ok' >/dev/null
rotated="$(openssl rand -hex 32)"
admin_action rotate --data-urlencode "provider_token=$rotated" | jq -e '.ok' >/dev/null
test "$(curl -ksS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $newtoken" "$state_b")" = 401
curl -ksS -H "Authorization: Bearer $rotated" "$state_b" | jq -e '.revision==0' >/dev/null
admin_action delete | jq -e '.ok' >/dev/null
test "$(curl -ksS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $rotated" "$state_b")" = 401
test "$(curl -ksS -u "admin:$admin" -H 'X-LiteEdge-API: 1' --data-urlencode provider_id=cluster-a --data-urlencode "policy_json=$newpolicy" -o /dev/null -w '%{http_code}' "$mgmt/api/v1/actions/provider/save")" = 400
test "$(curl -ksS -u "admin:$admin" -H 'X-LiteEdge-API: 1' --data-urlencode provider_id=cluster-a -o /dev/null -w '%{http_code}' "$mgmt/api/v1/actions/provider/delete")" = 400
test "$(curl -ksS -u "admin:$admin" --data-urlencode provider_id=cluster-a -o /dev/null -w '%{http_code}' "$mgmt/api/v1/actions/provider/delete")" = 403
echo 'PASS admin inventory, create/edit drained provider, rotate, delete, active owner guard, machine token isolation and CSRF'
