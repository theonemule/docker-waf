#!/usr/bin/env bash
set -euo pipefail
image="$1";name="le-https-ports-$(openssl rand -hex 4)";tmp="$(mktemp -d)";network="$name-net";backend="$name-backend"
cleanup(){ rc=$?;if ((rc));then cat "$tmp/result" 2>/dev/null||true;docker logs "$name" --tail 60||true;fi;docker rm -fv "$name" "$backend" >/dev/null 2>&1||true;docker network rm "$network" >/dev/null 2>&1||true;rm -rf "$tmp"; }
trap cleanup EXIT
password="$(openssl rand -hex 24)";token="$(openssl rand -hex 32)"
host=ports.apps.example.test;manual=manual.example.test
for label in primary extra manual;do
  dns="$host";[[ "$label" != manual ]]||dns="$manual"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/$label.key" -out "$tmp/$label.crt" -subj "/CN=$dns" -addext "subjectAltName=DNS:$dns" >/dev/null 2>&1
done
docker network create "$network" >/dev/null
docker run -d --network "$network" --name "$name" -e ADMIN_PASSWORD="$password" -e LITEEDGE_EXTRA_HTTPS_PORTS=8443:18443,8444:18444 -p 127.0.0.1::9443 -p 127.0.0.1::8443 -p 127.0.0.1::18443 -p 127.0.0.1::18444 "$image" >/dev/null
mapped(){ docker port "$name" "$1/tcp"|cut -d: -f2; }
admin="https://127.0.0.1:$(mapped 9443)"
standard="$(mapped 8443)";extra="$(mapped 18443)";reject="$(mapped 18444)"
docker run -d --name "$backend" --network "$network" --entrypoint /bin/sh "$image" -ec '
mkdir -p /tmp/primary /tmp/extra
echo primary >/tmp/primary/index.html;echo extra >/tmp/extra/index.html
python3 -m http.server 12001 --bind 0.0.0.0 --directory /tmp/primary &
exec python3 -m http.server 12002 --bind 0.0.0.0 --directory /tmp/extra' >/dev/null
backend_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$backend")"
for i in $(seq 1 80);do if curl -ksf -u "admin:$password" "$admin/api/v1/sites" >/dev/null 2>&1;then break;fi;test "$i" -lt 80;sleep .25;done
api(){ local action="$1";shift;curl -ksS -u "admin:$password" -H 'X-LiteEdge-API: 1' -o "$tmp/result" -w '%{http_code}' "$@" "$admin/api/v1/actions/$action"; }
get(){ local h="$1" port="$2" ca="$3";shift 3;curl -fsS --noproxy '*' --cacert "$tmp/$ca.crt" --resolve "$h:$port:127.0.0.1" "$@" "https://$h:$port/"; }
# Manual routes share the normal native site certificate.
test "$(api site/save -d host="$manual")" = 200
test "$(api cert/import -d host="$manual" --data-urlencode "certificate@$tmp/manual.crt" --data-urlencode "private_key@$tmp/manual.key")" = 200
test "$(api route/add -d host="$manual" -d match=prefix -d path=/ -d "target=http://$backend_ip:12001" -d force_https=0 --data-urlencode 'features_json={"schemes":["https:8443"]}')" = 200
test "$(get "$manual" "$extra" manual)" = primary
test "$(get "$manual" "$standard" manual -o /dev/null -w '%{http_code}' 2>/dev/null || true)" = 404
curl -ksSf -u "admin:$password" "$admin/api/v1/site?host=$manual" | jq -e '.site.tls_listeners["https:8443"]=="configured"'
# Provider-owned routes use independent certs for the same DNS hostname.
jq -n --arg cidr "$backend_ip/32" --arg hash "$(printf %s "$token"|sha256sum|cut -d' ' -f1)" '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_cidrs:[$cidr],min_waf_pl:1,extra_https_ports:[8443,8444]}' | docker exec -i "$name" sh -ec 'umask 077;mkdir -p /data/providers;cat >/data/providers/cluster-a.json'
state="$admin/api/v1/providers/cluster-a/state"
put(){ curl -ksS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -X PUT --data-binary "@$1" "$state" >"$tmp/result";jq -e '.ok' "$tmp/result"; }
jq -n --arg primary "http://$backend_ip:12001" --arg extra "http://$backend_ip:12002" --arg host "$host" --rawfile pcrt "$tmp/primary.crt" --rawfile pkey "$tmp/primary.key" --rawfile ecrt "$tmp/extra.crt" --rawfile ekey "$tmp/extra.key" '{revision:0,sites:[{host:$host,listeners:["https","https:8443","https:8444"],tls:{certificate:$pcrt,private_key:$pkey},tls_listeners:{"https:8443":{certificate:$ecrt,private_key:$ekey},"https:8444":null},routes:[{match:"prefix",path:"/",target:$primary,schemes:["https"]},{match:"prefix",path:"/",target:$extra,schemes:["https:8443"]},{match:"exact",path:"/old",schemes:["https:8443"],redirect:{hostname:"new.apps.example.test",status_code:302}}]}]}' >"$tmp/desired"
put "$tmp/desired"
test "$(get "$host" "$standard" primary)" = primary
test "$(get "$host" "$extra" extra)" = extra
if get "$host" "$extra" primary >/dev/null 2>&1;then exit 1;fi
if get "$host" "$standard" extra >/dev/null 2>&1;then exit 1;fi
if get "$host" "$reject" extra >/dev/null 2>&1;then exit 1;fi
if curl -ksf --noproxy '*' --resolve "unknown.example.test:$extra:127.0.0.1" "https://unknown.example.test:$extra/" >/dev/null 2>&1;then exit 1;fi
curl -fsS --noproxy '*' --cacert "$tmp/extra.crt" --resolve "$host:$extra:127.0.0.1" -D "$tmp/headers" -o /dev/null "https://$host:$extra/old"
grep -qi '^location: https://new.apps.example.test:8443/old' "$tmp/headers"
test "$(get "$host" "$extra" extra --get --data-urlencode 'q=<script>alert(1)</script>' -o /dev/null -w '%{http_code}' 2>/dev/null || true)" = 403
curl -ksSf -u "admin:$password" "$admin/api/v1/site?host=$host" | jq -e '.site.tls_listeners=={"https":"configured","https:8443":"configured","https:8444":"rejected"}'
echo 'PASS independent TLS certificates, routes, rejected handshake, unknown SNI, WAF, redirect port and API listener status'
# Removal is scoped to the selected socket and its stored certificate.
jq '.revision=1|.sites[0].listeners=["https","https:8444"]|del(.sites[0].tls_listeners["https:8443"])|.sites[0].routes|=map(select(.schemes==["https"]))' "$tmp/desired" >"$tmp/remove"
put "$tmp/remove"
if get "$host" "$extra" extra >/dev/null 2>&1;then exit 1;fi
test "$(get "$host" "$standard" primary)" = primary
test "$(get "$manual" "$extra" manual)" = primary
docker exec "$name" test ! -e /data/certs/ports.apps.example.test/listeners/https-8443
echo 'PASS selective listener deletion, certificate cleanup and independent manual site'
