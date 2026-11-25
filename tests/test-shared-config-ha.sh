#!/usr/bin/env bash
# Two independent /data volumes, one authoritative shared filesystem.
set -euo pipefail
image="$1"
acme_test="${2:-}"
suffix="$(openssl rand -hex 4)"
net="le-shared-$suffix"
vol="$net-source"; a="$net-a"; b="$net-b"; backend="$net-backend"
tmp="$(mktemp -d)"
cleanup(){
 rc=$?
 if [[ "$rc" != 0 ]]; then
   for n in "$a" "$b"; do
     docker logs "$n" --tail 30 2>/dev/null || true
     docker exec "$n" sh -c 'tail -20 /data/logs/ha-worker.log' 2>/dev/null || true
   done
 fi
 docker rm -fv "$a" "$b" "$backend" >/dev/null 2>&1 || true
 docker volume rm "$vol" >/dev/null 2>&1 || true
 docker network rm "$net" >/dev/null 2>&1 || true
 rm -rf "$tmp"
}
trap cleanup EXIT
umask 077
docker volume create "$vol" >/dev/null
docker network create "$net" >/dev/null
key="$(openssl rand -hex 32)"
docker run --rm --user 0 -v "$vol:/ha" -e KEY="$key" --entrypoint sh "$image" -ec '
  umask 077
  printf "%s" "$KEY" >/ha/key
  printf "%s" "{\"cluster_id\":\"test-ha\",\"bootstrap_node\":\"node-a\",\"members\":{\"node-a\":\"edge-a\",\"node-b\":\"edge-b\"}}" >/ha/cluster.json
  chown -R 10001:10001 /ha
  chmod 700 /ha
'
cat >"$tmp/backend.py" <<'PY'
from http.server import BaseHTTPRequestHandler,HTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body=self.headers.get("X-Revision","native").encode()
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
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$backend")
token="$(openssl rand -hex 32)"; password="$(openssl rand -hex 24)"
policy=$(jq -cn --arg hash "$(printf %s "$token"|sha256sum|cut -d' ' -f1)" --arg cidr "$ip/32" '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_cidrs:[$cidr],min_waf_pl:1}')
docker run -d --name "$a" --network "$net" -v "$vol:/ha" -p 127.0.0.1::9443 -p 127.0.0.1::8080 -e ADMIN_PASSWORD="$password" -e LITEEDGE_HA_DIR=/ha -e LITEEDGE_HA_NODE_ID=node-a -e LITEEDGE_HA_BOOTSTRAP=1 -e LITEEDGE_HA_POLL_SECONDS=1 -e TEST_ACME_PEERS="$a $b" -e TEST_POLICY="$policy" --entrypoint sh "$image" -ec 'umask 077; mkdir -p /data/providers; printf "%s" "$TEST_POLICY" >/data/providers/cluster-a.json; exec /opt/liteedge/entrypoint.sh' >/dev/null
mgmt(){ printf 'https://127.0.0.1:%s' "$(docker port "$1" 9443/tcp|cut -d: -f2)"; }
http(){ printf 'http://127.0.0.1:%s' "$(docker port "$1" 8080/tcp|cut -d: -f2)"; }
state(){ curl -ksS -H "Authorization: Bearer $token" "$(mgmt "$1")/api/v1/providers/cluster-a/state"; }
wait_ready(){
 for i in $(seq 1 60); do
   if state "$1" 2>/dev/null | jq -e '.ok' >/dev/null 2>&1; then return; fi
   sleep .3
 done
 return 1
}
wait_ready "$a"
docker run -d --name "$b" --network "$net" -v "$vol:/ha" -p 127.0.0.1::9443 -p 127.0.0.1::8080 -e ADMIN_PASSWORD="$password" -e LITEEDGE_HA_DIR=/ha -e LITEEDGE_HA_NODE_ID=node-b -e LITEEDGE_HA_POLL_SECONDS=1 -e TEST_ACME_PEERS="$a $b" "$image" >/dev/null
wait_ready "$b"
test "$(docker exec "$a" cat /ha/current.json|jq -r .revision)" = 1
test "$(docker exec "$a" sha256sum /data/certs/_admin/fullchain.pem |cut -d' ' -f1)" != "$(docker exec "$b" sha256sum /data/certs/_admin/fullchain.pem|cut -d' ' -f1)"
echo 'PASS shared bootstrap and independent local management TLS'
put(){
 local node="$1" revision="$2" marker="$3"
 jq -cn --argjson rev "$revision" --arg target "http://$ip:8080" --arg marker "$marker" '{revision:$rev,sites:[{host:"ha.apps.example.test",routes:[{match:"prefix",path:"/",schemes:["http"],target:$target,request_headers:[{op:"set",name:"X-Revision",value:$marker}]}]}]}' |
  curl -ksS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -X PUT --data-binary @- "$(mgmt "$node")/api/v1/providers/cluster-a/state"
}
traffic(){ curl -fsS --max-time 3 -H "Host: ${2:-ha.apps.example.test}" "$(http "$1")/"; }
wait_traffic(){
 for i in $(seq 1 60); do
   if [[ "$(traffic "$1" 2>/dev/null || true)" == "$2" ]]; then return; fi
   sleep .25
 done
 return 1
}
put "$a" 0 one | jq -e '.ok and .revision==1' >/dev/null
wait_traffic "$a" one
# No API request to B: its watcher reads the signed manifest itself.
wait_traffic "$b" one
state "$b" | jq -e '.revision==1' >/dev/null
echo 'PASS a single provider update refreshes both appliances'
put "$b" 0 stale | jq -e '.ok==false' >/dev/null
put "$b" 1 two | jq -e '.ok and .revision==2' >/dev/null
wait_traffic "$a" two; wait_traffic "$b" two
echo 'PASS writes through either member share one provider revision and reject stale CAS'
# Simultaneous writes with the same provider revision: exactly one wins.
put "$a" 2 race-a >"$tmp/race-a" & pa=$!
put "$b" 2 race-b >"$tmp/race-b" & pb=$!
wait "$pa"; wait "$pb"
jq -s -e 'map(.ok)|sort==[false,true]' "$tmp/race-a" "$tmp/race-b" >/dev/null
state "$a" | jq -e '.revision==3' >/dev/null
state "$b" | jq -e '.revision==3' >/dev/null
echo 'PASS shared writer lock and cross-member compare-and-swap'

# Native site management uses the same shared source.
curl -ksS -u "admin:$password" -H 'X-LiteEdge-API: 1' -d 'host=manual.example.test' "$(mgmt "$b")/api/v1/actions/site/save" | jq -e '.ok' >/dev/null
for i in $(seq 1 60); do
  if docker exec "$a" test -f /data/sites/manual.example.test.site; then break; fi
  test "$i" -lt 60; sleep .25
done
curl -ksS -u "admin:$password" -H 'X-LiteEdge-API: 1' --data-urlencode 'host=manual.example.test' --data-urlencode "target=http://$ip:8080" "$(mgmt "$a")/api/v1/actions/route/add" | jq -e '.ok' >/dev/null
for i in $(seq 1 60); do
  if [[ "$(traffic "$b" manual.example.test 2>/dev/null || true)" == native ]]; then break; fi
  test "$i" -lt 60; sleep .25
done
echo 'PASS native admin site and route changes use the same shared source'
# Simulate a killed writer after modifying its local native state.
docker exec "$a" sh -ec 'printf "{}" >/data/.liteedge-ha-pending.json; printf "HOST=uncommitted.example.test\n" >/data/sites/manual.example.test.site'
for i in $(seq 1 60); do
  if docker exec "$a" sh -ec 'test ! -e /data/.liteedge-ha-pending.json && grep -q "^HOST=manual.example.test$" /data/sites/manual.example.test.site'; then break; fi
  test "$i" -lt 60; sleep .25
done
echo 'PASS interrupted local writer recovered from unchanged signed revision'
if [[ "$acme_test" == offline-acme ]]; then
  # Offline test double runs the real certctl/locking/rendering path.
  # Request issuance via A, then have both nodes attempt renewal concurrently.
  curl -ksS -u "admin:$password" -H 'X-LiteEdge-API: 1' -d 'host=manual.example.test&email=ops@example.test' "$(mgmt "$a")/api/v1/actions/cert/letsencrypt" | jq -e '.ok' >/dev/null
  for i in $(seq 1 60); do
    if docker exec "$b" test -s /data/certs/manual.example.test/fullchain.pem; then break; fi
    test "$i" -lt 60; sleep .25
  done
  cert_a=$(docker exec "$a" sha256sum /data/certs/manual.example.test/fullchain.pem|cut -d' ' -f1)
  cert_b=$(docker exec "$b" sha256sum /data/certs/manual.example.test/fullchain.pem|cut -d' ' -f1)
  test "$cert_a" = "$cert_b"
  docker exec "$a" /opt/liteedge/bin/certctl.sh renew manual.example.test >/dev/null & pa=$!
  docker exec "$b" /opt/liteedge/bin/certctl.sh renew manual.example.test >/dev/null & pb=$!
  wait "$pa"; wait "$pb"
  test "$(docker exec "$a" grep -c '^register$' /ha/acme/test-invocations)" = 1
  test "$(docker exec "$b" grep -c '^issue$' /ha/acme/test-invocations)" = 2
  for i in $(seq 1 60); do
    if docker exec "$a" openssl x509 -in /data/certs/manual.example.test/fullchain.pem -noout -checkend 2592000 >/dev/null 2>&1 &&
       docker exec "$b" openssl x509 -in /data/certs/manual.example.test/fullchain.pem -noout -checkend 2592000 >/dev/null 2>&1; then break; fi
    test "$i" -lt 60; sleep .25
  done
  test "$(docker exec "$a" sha256sum /data/certs/manual.example.test/fullchain.pem|cut -d' ' -f1)" = "$(docker exec "$b" sha256sum /data/certs/manual.example.test/fullchain.pem|cut -d' ' -f1)"
  echo 'PASS shared HTTP-01 challenge across both nodes, certificate publication and duplicate renewal suppression (offline ACME double)'
fi

docker stop "$b" >/dev/null
put "$a" 3 three | jq -e '.ok and .revision==4' >/dev/null
wait_traffic "$a" three
docker start "$b" >/dev/null
wait_ready "$b"
wait_traffic "$b" three
echo 'PASS stopped member catches up on startup without receiving a network notification'
# Invalid signatures cannot cause a peer reload or accepted write.
docker exec "$a" sh -ec 'cp /ha/current.json /ha/current.saved; jq ".signature=\"bad\"" /ha/current.saved >/ha/current.bad; mv /ha/current.bad /ha/current.json'
sleep 2
[[ "$(traffic "$a")" == three && "$(traffic "$b")" == three ]]
put "$b" 4 invalid | jq -e '.ok==false' >/dev/null
docker exec "$a" sh -ec 'mv /ha/current.saved /ha/current.json'
state "$a" | jq -e '.revision==4' >/dev/null
echo 'PASS invalid shared signature leaves last-good traffic intact and rejects writes'
# Content tampering with an unchanged signed manifest cannot be committed.
docker exec "$a" sh -ec 'd="/ha/revision-$(printf "%020d" "$(jq -r .revision /ha/current.json)")-$(jq -r .digest /ha/current.json)"; cp "$d/sites/manual.example.test.site" /ha/site.saved; printf "CORRUPT=1\n" >>"$d/sites/manual.example.test.site"'
put "$b" 4 invalid | jq -e '.ok==false' >/dev/null
[[ "$(traffic "$a")" == three && "$(traffic "$b")" == three ]]
docker exec "$a" sh -ec 'd="/ha/revision-$(printf "%020d" "$(jq -r .revision /ha/current.json)")-$(jq -r .digest /ha/current.json)"; cat /ha/site.saved >"$d/sites/manual.example.test.site"; rm /ha/site.saved'
put "$b" 4 three | jq -e '.ok and .revision==4 and .changed==false' >/dev/null
echo 'PASS signed content integrity and no-op revision stability'
# Restore via a new signed revision rather than moving the pointer backward.
previous=$(docker exec "$a" jq -r .revision /ha/current.json)
put "$a" 4 four | jq -e '.ok and .revision==5' >/dev/null
wait_traffic "$a" four; wait_traffic "$b" four
docker exec "$b" python3 /opt/liteedge/bin/ha_config.py restore-revision "$previous" | jq -e --argjson prev "$previous" '.restored_from==$prev and .current.revision>$prev' >/dev/null
wait_traffic "$a" three; wait_traffic "$b" three
state "$a" | jq -e '.revision==6' >/dev/null
state "$b" | jq -e '.revision==6' >/dev/null
echo 'PASS signed historical restoration creates a new revision and preserves provider CAS'
docker exec "$a" python3 /opt/liteedge/bin/ha_config.py prune --keep 2 | jq -e '.applied==false and (.candidates|length)>0' >/dev/null
docker exec "$b" python3 /opt/liteedge/bin/ha_config.py prune --keep 2 --apply | jq -e '.applied and (.pruned|length)>0' >/dev/null
docker exec "$a" python3 /opt/liteedge/bin/ha_config.py history | jq -e '(.revisions|length)==2' >/dev/null
[[ "$(traffic "$a")" == three && "$(traffic "$b")" == three ]]
echo 'PASS explicit retention leaves active and previous revision intact'


# Both nodes report the same signed revision; logs and rendered files remain separate.
test "$(docker exec "$a" jq -r .revision /data/.liteedge-ha-applied.json)" = "$(docker exec "$b" jq -r .revision /data/.liteedge-ha-applied.json)"
echo 'PASS shared file HA with independent local runtime and one configuration authority'
