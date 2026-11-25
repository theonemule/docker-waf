#!/usr/bin/env bash
set -euo pipefail
image="$1"; name="le-ports-$(openssl rand -hex 4)"; tmp="$(mktemp -d)"
cleanup(){ rc=$?; if ((rc));then cat "$tmp/response" 2>/dev/null||true; docker logs "$name" --tail 50||true;fi;docker rm -fv "$name" >/dev/null 2>&1||true;rm -rf "$tmp";}
trap cleanup EXIT
password="$(openssl rand -hex 24)"
docker run -d --name "$name" -e ADMIN_PASSWORD="$password" -e LITEEDGE_EXTRA_HTTP_PORTS=8080:18080,8090:18090 -p 127.0.0.1::9443 -p 127.0.0.1::8080 -p 127.0.0.1::18080 -p 127.0.0.1::18090 "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
proxy(){ printf 'http://127.0.0.1:%s' "$(docker port "$name" "$1/tcp"|cut -d: -f2)";}
main="$(proxy 8080)"; extra="$(proxy 18080)"; third="$(proxy 18090)"
docker exec "$name" sh -ec 'mkdir -p /tmp/primary /tmp/extra /tmp/third;echo primary >/tmp/primary/index.html;echo extra >/tmp/extra/index.html;echo third >/tmp/third/index.html'
for spec in primary:12001 extra:12002 third:12003;do docker exec -d "$name" python3 -m http.server "${spec#*:}" --bind 127.0.0.1 --directory "/tmp/${spec%:*}";done
for i in $(seq 1 80);do if curl -ksf -u "admin:$password" "$admin/api/v1/sites" >/dev/null 2>&1;then break;fi;test "$i" -lt 80;sleep .25;done
api(){ local action="$1";shift;curl -ksS -u "admin:$password" -H 'X-LiteEdge-API: 1' -o "$tmp/response" -w '%{http_code}' "$@" "$admin/api/v1/actions/$action"; }
get(){ curl -fsS -H "Host: ports.example.test" "$@";}
code(){ curl -sS -o /dev/null -w '%{http_code}' "$@";}
test "$(api site/save -d host=ports.example.test)" = 200
for spec in http:12001 http:8080:12002 http:8090:12003;do
  key="${spec%:*}"; target="${spec##*:}"
  f="$(jq -nc --arg k "$key" '{schemes:[$k]}')"
  test "$(api route/add -d host=ports.example.test -d path=/ -d match=prefix -d target=http://127.0.0.1:"$target" -d force_https=0 -d waf=1 --data-urlencode "features_json=$f")" = 200
done
test "$(get "$main/")" = primary
test "$(get "$extra/")" = extra
test "$(get "$third/")" = third
test "$(code -H 'Host: unrelated.example.test' "$extra/")" = 404
test "$(code -H 'Host: ports.example.test' --get --data-urlencode 'q=<script>alert(1)</script>' "$extra/")" = 403
curl -ksSf -u "admin:$password" "$admin/api/v1/site?host=ports.example.test" >"$tmp/site"
jq -e '.site.listeners|index("http:8080")!=null and index("http:8090")!=null' "$tmp/site"
test "$(api route/add -d host=ports.example.test -d path=/bad -d target=http://127.0.0.1:12001 -d force_https=0 --data-urlencode 'features_json={"schemes":["http:9443"]}')" = 400
test "$(api route/add -d host=ports.example.test -d path=/bad -d target=http://127.0.0.1:12001 -d force_https=0 --data-urlencode 'features_json={"schemes":["http:9999"]}')" = 400
test "$(api route/add -d host=ports.example.test -d path=/old -d match=prefix -d force_https=0 --data-urlencode 'features_json={"schemes":["http:8080"],"redirect":{"hostname":"new.example.test","status_code":302}}')" = 200
curl -sS -D "$tmp/headers" -o /dev/null -H 'Host: ports.example.test' "$extra/old"
grep -qi '^location: http://new.example.test:8080/old' "$tmp/headers"
id=$(jq -r '.site.routes[]|select(.features.schemes==["http:8090"])|.id' "$tmp/site")
test "$(api route/delete -d host=ports.example.test -d id="$id")" = 200
test "$(code -H 'Host: ports.example.test' "$third/")" = 404
test "$(get "$extra/")" = extra
echo 'PASS native same-host/path isolation across three ports, deny unknown host, WAF, API read model, reserved/unprovisioned port rejection, redirect port, deletion'
