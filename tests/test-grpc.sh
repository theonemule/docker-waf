#!/usr/bin/env bash
set -euo pipefail
image="$1";name="le-grpc-$(openssl rand -hex 4)";tmp="$(mktemp -d)";builder=""
cleanup(){ rc=$?;if ((rc));then cat "$tmp/result" "$tmp/headers" 2>/dev/null||true;docker logs "$name" --tail 80||true;fi;[[ -z "$builder" ]]||docker rm -fv "$builder" >/dev/null 2>&1||true;docker rm -fv "$name" >/dev/null 2>&1||true;rm -rf "$tmp"; }
trap cleanup EXIT
builder=$(docker create golang:1.26.10-bookworm sh -ec 'CGO_ENABLED=0 go build -o /grpc /main.go')
docker cp tests/fixtures/grpc/main.go "$builder:/main.go";docker start -a "$builder";docker cp "$builder:/grpc" "$tmp/grpc"
docker run -d --name "$name" -e ADMIN_PASSWORD=grpc-test -p 127.0.0.1::9443 -p 127.0.0.1::8080 "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
docker cp "$tmp/grpc" "$name:/tmp/grpc"
docker exec -d "$name" /tmp/grpc 12001
docker exec -d "$name" /tmp/grpc 12002
for i in $(seq 1 100);do if curl -ksf -u admin:grpc-test "$admin/api/v1/sites" >/dev/null;then break;fi;test "$i" -lt 100;sleep .25;done
api(){ local a="$1";shift;curl -ksS -u admin:grpc-test -H 'X-LiteEdge-API: 1' -o "$tmp/result" -w '%{http_code}' "$@" "$admin/api/v1/actions/$a"; }
test "$(api site/save -d host=grpc.example.test)" = 200
test "$(api route/add -d host=grpc.example.test -d match=exact -d path=/example.Echo/Call -d target=http://127.0.0.1:12001 -d force_https=0 -d waf=1 --data-urlencode 'features_json={"grpc":true,"method":"POST","schemes":["http"],"request_headers":[{"op":"set","name":"X-Route","value":"one"}]}')" = 200
test "$(api route/add -d host=grpc.example.test -d match=prefix -d path=/example.Echo -d target=http://127.0.0.1:12002 -d force_https=0 -d waf=1 --data-urlencode 'features_json={"grpc":true,"method":"POST","schemes":["http"]}')" = 200
call(){ docker exec "$name" sh -c 'printf "\000\000\000\000\000" | curl --http2-prior-knowledge -sS -D - -o /dev/null -H "Host: grpc.example.test" -H "Content-Type: application/grpc" -H "TE: trailers" --data-binary @- "$@"' sh "http://127.0.0.1:8080/$1" "${@:2}" ; }
call example.Echo/Call >"$tmp/headers"
grep -qi '^grpc-status: 0' "$tmp/headers"
grep -qi '^x-echo-route: one' "$tmp/headers"
grep -qi '^x-echo-port: 12001' "$tmp/headers"
call example.Echo/Other >"$tmp/headers"
grep -qi '^grpc-status: 0' "$tmp/headers"
grep -qi '^x-echo-port: 12002' "$tmp/headers"
call example.Echo/Call -H 'X-Test: <script>alert(1)</script>' >"$tmp/headers"
grep -q 'HTTP/2 403' "$tmp/headers"
curl -ksSf -u admin:grpc-test "$admin/api/v1/site?host=grpc.example.test"|jq -e 'any(.site.routes[];.features.grpc==true)'
echo 'PASS native gRPC HTTP/2 exact/service routing, response trailers, request metadata, WAF and API roundtrip'
