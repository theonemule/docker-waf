#!/bin/bash
set -euo pipefail
image="$1";tmp=$(mktemp -d);out="${2:-$tmp/results.txt}";name="le-waf-shared-$(openssl rand -hex 4)"
: >"$out"
cleanup(){ rc=$?;cat "$out" 2>/dev/null||true;docker logs "$name" >"$out.container.log" 2>&1||true;if ((rc));then tail -80 "$out.container.log" >&2||true;fi;docker rm -fv "$name" >/dev/null 2>&1||true;rm -rf "$tmp";exit "$rc"; }
trap cleanup EXIT
cpu="$(awk '/^Cpus_allowed_list:/{print $2}' /proc/self/status | cut -d, -f1 |cut -d- -f1)"
docker run -d --cpuset-cpus="$cpu" --name "$name" -e ADMIN_PASSWORD=spike-test -p 127.0.0.1::9443 -p 127.0.0.1::8080 "$image" >/dev/null
admin="https://127.0.0.1:$(docker port "$name" 9443/tcp|cut -d: -f2)"
public="http://127.0.0.1:$(docker port "$name" 8080/tcp|cut -d: -f2)"
for i in $(seq 1 60);do if curl -ksf -u admin:spike-test "$admin/api/v1/sites" >/dev/null;then break;fi;[[ "$i" -lt 60 ]];sleep .3;done
cat >"$tmp/backend.py" <<'PY'
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200);self.end_headers();self.wfile.write(b"ok")
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length",0)));self.do_GET()
ThreadingHTTPServer(("0.0.0.0",12001),H).serve_forever()
PY
docker cp "$tmp/backend.py" "$name:/tmp/backend.py"
docker exec -d "$name" python3 /tmp/backend.py
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
token=$(openssl rand -hex 32)
jq -n --arg hash "$(printf %s "$token"|sha256sum|cut -d' ' -f1)" --arg cidr "$ip/32" '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_cidrs:[$cidr],min_waf_pl:1,waf_profiles:{relaxed:{min_waf_pl:1,disabled_rules:[920420]},special:{min_waf_pl:1,plugins:["test-plugin"]}}}'|docker exec -i "$name" sh -c 'umask 077; mkdir -p /data/providers; cat >/data/providers/cluster-a.json'
state="$admin/api/v1/providers/cluster-a/state"
sample(){ docker exec "$name" sh -c 'for p in $(pidof nginx);do awk -v p="$p" "/^Rss:/{r=\$2}/^Pss:/{s=\$2}/^Private_Clean:/{c=\$2}/^Private_Dirty:/{d=\$2}END{print p,r,s,c+d}" /proc/$p/smaps_rollup;done;cat /sys/fs/cgroup/memory.current 2>/dev/null||true' ;}
# Catch accidental return to a per-location full parse. 192 MiB leaves
# ample margin over the observed ~50–60 MiB and below the old ~427 MiB.
assert_shared_budget(){
  local pss
  pss=$(sample | awk 'NF==4{sum+=$3}END{print sum+0}')
  test "$pss" -gt 0 && test "$pss" -lt 196608
  printf 'PASS shared NGINX PSS budget: %s KiB (<192 MiB)\n' "$pss" >>"$out"
}
echo "startup memory PID RSS PSS PRIVATE (KiB)" >>"$out"
sample >>"$out"
jq -n --arg target "http://$ip:12001" '{revision:0,sites:[range(0;6)|{host:("site"+tostring+".apps.example.test"),listeners:["http"],routes:[{match:"prefix",path:"/",schemes:["http"],target:$target},{match:"exact",path:"/exempt",schemes:["http"],target:$target,waf_profile:"relaxed"}]}]}' >"$tmp/snapshot"
put(){ curl -ksS --max-time 120 -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -X PUT --data-binary "@$1" "$state"; }
echo "apply 12 HTTP routes" >>"$out"
put "$tmp/snapshot"|jq -e '.ok and .revision==1' >>"$out"
sleep 2
sample >>"$out"
docker exec "$name" sh -ec '/opt/liteedge/sbin/nginx -t -c /data/.liteedge-nginx-generations/active.conf' >"$tmp/nginx-test" 2>&1
cat "$tmp/nginx-test" >>"$out"
grep -F 'LiteEdge shared ModSecurity files: 1, cache hits: 11' "$tmp/nginx-test"
assert_shared_budget
# One base in a snapshot, each local file contains only controls.
docker exec "$name" sh -ec 'dir=/data/nginx/waf-routes;test "$(find "$dir" -name _shared-crs.conf | wc -l)" = 1;test "$(find "$dir" -name "*.local.conf" | wc -l)" = 12;! grep -l "Include .*rules/\*.conf" "$dir"/*.local.conf' 
probe(){ curl -sS --max-time 8 -o /dev/null -w '%{http_code}' -H "Host: $1" "${@:3}" "$public$2"; }
for n in 0 1 5;do
 host="site$n.apps.example.test"
 test "$(probe "$host" /)" = 200
 test "$(probe "$host" / -H 'Content-Type: application/x-spike' -d 'x')" = 403
 test "$(probe "$host" /exempt -H 'Content-Type: application/x-spike' -d 'x')" = 200
 test "$(probe "$host" '/exempt?q=%3Cscript%3Ealert(1)%3C/script%3E')" = 403
 test "$(probe "$host" / -H 'Content-Type: application/x-spike' -d 'x')" = 403
done
echo 'PASS route-local rule exclusion and WAF isolation across three hosts' >>"$out"
# Use the same immutable publish path and consecutive actual configuration changes.
for i in $(seq 1 5);do
 jq --argjson i "$i" '.revision=$i|.sites[0].routes[0].response_headers=[{op:"set",name:"X-Spike",value:($i|tostring)}]' "$tmp/snapshot" >"$tmp/update"
 echo "reload $i" >>"$out"
 put "$tmp/update"|jq -e --argjson rev "$((i+1))" '.ok and .revision==$rev' >>"$out"
 sleep 1
 sample >>"$out"
 test "$(probe site0.apps.example.test / -H 'Content-Type: application/x-spike' -d x)" = 403
 test "$(probe site0.apps.example.test /exempt -H 'Content-Type: application/x-spike' -d x)" = 200
done
assert_shared_budget
echo 'PASS five updates and exclusion isolation' >>"$out"

# Global custom rule ordering is preserved: all generated routes fall back
# to full legacy rules while custom rules are enabled, then return to sharing.
printf '%s\n' 'SecRule REQUEST_HEADERS:X-Lab-Custom "@streq block" "id:1001001,phase:1,deny,status:403,log"' >"$tmp/custom.conf"
docker cp "$tmp/custom.conf" "$name:/tmp/custom.conf"
docker exec "$name" /opt/liteedge/bin/wafctl.sh custom-save 1001001 /tmp/custom.conf
test "$(probe site0.apps.example.test / -H 'X-Lab-Custom: block')" = 403
test "$(probe site0.apps.example.test /exempt -H 'X-Lab-Custom: block')" = 403
test "$(probe site0.apps.example.test /exempt -H 'Content-Type: application/x-spike' -d x)" = 200
docker exec "$name" sh -ec '! grep -R "modsecurity_rules_file_shared" /data/nginx/sites'
docker exec "$name" /opt/liteedge/bin/wafctl.sh custom-delete 1001001
test "$(probe site0.apps.example.test / -H 'X-Lab-Custom: block')" = 200
docker exec "$name" sh -ec 'grep -R -q "modsecurity_rules_file_shared" /data/nginx/sites'
echo 'PASS custom global rule fallback and removal' >>"$out"
# Install a synthetic plugin with config/before/after order dependencies.
docker exec -i "$name" sh -ec 'mkdir -p /data/waf/plugins/test-plugin/plugins;cat >/data/waf/plugins/test-plugin/plugins/test-config.conf' <<'RULE'
SecAction "id:1001002,phase:1,pass,nolog,setvar:tx.lab_plugin=1"
RULE
docker exec -i "$name" sh -ec 'cat >/data/waf/plugins/test-plugin/plugins/test-before.conf' <<'RULE'
SecRule TX:lab_plugin "@eq 1" "id:1001003,phase:1,pass,nolog,setvar:tx.lab_plugin_before=1"
RULE
docker exec -i "$name" sh -ec 'cat >/data/waf/plugins/test-plugin/plugins/test-after.conf' <<'RULE'
SecRule TX:lab_plugin_before "@eq 1" "id:1001004,phase:1,deny,status:403,log,chain"
SecRule REQUEST_HEADERS:X-Lab-Plugin "@streq block"
RULE
jq '.revision=6|.sites[0].routes[0].waf_profile="special"|.sites[0].routes[1].waf_pl=2|.sites[1].routes[0].waf_pl=3|.sites[2].routes[0].waf_pl=4' "$tmp/snapshot" >"$tmp/plugin"
put "$tmp/plugin" |jq -e '.ok and .revision==7' >>"$out"
test "$(probe site0.apps.example.test / -H 'X-Lab-Plugin: block')" = 403
test "$(probe site5.apps.example.test / -H 'X-Lab-Plugin: block')" = 200
# All levels must still block a known attack, and the generated transaction
# overrides must retain the original paranoia variable names.
for n in 0 1 2 5;do test "$(probe "site$n.apps.example.test" '/?q=%3Cscript%3Ealert(1)%3C/script%3E')" = 403;done
docker exec "$name" sh -ec 'for level in 1 2 3 4;do grep -q "tx.paranoia_level=$level,setvar:tx.executing_paranoia_level=$level" /data/nginx/waf-routes/*.local.conf;done'
docker exec "$name" sh -ec 'grep -q "test-plugin/plugins/test-before.conf" /data/nginx/waf-routes/site0.apps.example.test-*.conf;grep -q "modsecurity_rules_file_shared" /data/nginx/sites/site5.apps.example.test.conf'
echo 'PASS plugin ordering and isolation, PL1-4 controls, mixed shared and legacy routes' >>"$out"
# Compare identical configured PL1–4 and request outcomes with and without
# caching. The no-op global rule intentionally selects the legacy path.
# This is policy parity, not an assertion that legacy CRS4 variable names
# implement higher paranoia levels correctly.
policy_matrix(){
  local entry host path code
  for entry in 'site5 /' 'site0 /exempt' 'site1 /' 'site2 /';do
    read -r host path <<<"$entry"
    host="$host.apps.example.test"
    for query in '' '?q=hello%21' '?q=%3Cscript%3Ealert(1)%3C/script%3E';do
      printf '%s %s %s\n' "$host" "$path$query" "$(probe "$host" "$path$query")"
    done
    printf '%s missing-UA %s\n' "$host" "$(probe "$host" "$path?q=%3Cscript%3Ealert(1)%3C/script%3E" -H 'User-Agent:')"
    printf '%s media-type %s\n' "$host" "$(probe "$host" "$path" -H 'Content-Type: application/x-spike' -d x)"
  done
}
policy_matrix >"$tmp/shared-policy"
printf '%s\n' 'SecRule REQUEST_HEADERS:X-Lab-Nonexistent "@streq never" "id:1001005,phase:1,pass,nolog"' >"$tmp/noop-rule.conf"
docker cp "$tmp/noop-rule.conf" "$name:/tmp/noop-rule.conf"
docker exec "$name" /opt/liteedge/bin/wafctl.sh custom-save 1001005 /tmp/noop-rule.conf
policy_matrix >"$tmp/legacy-policy"
diff -u "$tmp/shared-policy" "$tmp/legacy-policy"
cat "$tmp/shared-policy" >>"$out"
docker exec "$name" /opt/liteedge/bin/wafctl.sh custom-delete 1001005
echo 'PASS PL1–4 shared/legacy status parity (20 requests each)' >>"$out"

# Explicit WAF-off route on a native site must remain off.
api(){ local a="$1";shift;curl -ksS -u admin:spike-test -H 'X-LiteEdge-API: 1' "$@" "$admin/api/v1/actions/$a"|jq -e '.ok' >/dev/null; }
api site/save -d host=native.example.test
api route/add -d host=native.example.test -d path=/ -d target=http://127.0.0.1:12001 -d waf=0 -d force_https=0
test "$(probe native.example.test '/?q=%3Cscript%3Ealert(1)%3C/script%3E')" = 200
test "$(probe site5.apps.example.test '/?q=%3Cscript%3Ealert(1)%3C/script%3E')" = 403
echo 'PASS native WAF-off route and unrelated WAF protection' >>"$out"
echo 'PASS shared rules regression' >>"$out"
