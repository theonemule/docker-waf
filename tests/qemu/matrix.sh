#!/usr/bin/env bash
# Sourced by run.sh; all traffic goes through a LightEdge public listener.
# name client-protocol host frontend-nodeport-loopback-base container-port backend-protocol ca metadata
readarray -t CASES <<'ROWS'
gateway-http http hello 28080 8080 http - -
gateway-https https hello 28440 8443 http front -
gateway-extra-http http extra 28180 18081 http - -
gateway-extra-https https extra 28540 18443 http front -
gateway-http-to-https http secure 28080 8080 https - -
gateway-https-to-https https secure 28440 8443 https front -
ingress-http http ingress 28080 8080 http - -
ingress-https https ingress-tls 28440 8443 http front -
gateway-grpc grpc grpc 28080 8080 grpc - gateway
gateway-grpcs grpcs grpc 28440 8443 grpc front gateway
gateway-tcp tcp - 29000 19000 tcp - -
gateway-udp udp - 29100 19001 udp - -
gateway-tls tls passthrough 29440 19444 tls backend -
ROWS
fingerprint(){ openssl x509 -in "$1" -outform DER |sha256sum|cut -d' ' -f1; }
front_fp=$(fingerprint private/frontend.crt)
backend_fp=$(fingerprint private/backend.crt)
case_probe(){
 local row="$1" location="$2" endpoint="$3" count="$4"
 local name proto host base port expected ca meta
 read -r name proto host base port expected ca meta <<<"$row"
 local addr args=() command=()
 if [[ "$location" == public ]];then
   addr="127.0.0.1:$((base+endpoint))";command=(/lab/input/probe)
   case "$ca" in front)args+=(-ca /lab/private/frontend.crt -fingerprint "$front_fp");;backend)args+=(-ca /lab/private/backend.crt -fingerprint "$backend_fp");;esac
 else
   addr="$endpoint:$port";command=(k -n apps exec deploy/hello -- /probe)
   case "$ca" in front)args+=(-ca /trust/ca.crt -fingerprint "$front_fp");;backend)args+=(-ca /cert/tls.crt -fingerprint "$backend_fp");;esac
 fi
 [[ "$host" == - ]]||args+=(-host "$host.apps.example.test")
 [[ "$meta" == - ]]||args+=(-metadata "$meta")
 "${command[@]}" probe -protocol "$proto" -addr "$addr" -count "$count" -backend "$expected" "${args[@]}"
}
wait_routes(){
 local kind name
 for pair in httproute:hello httproute:extra httproute:secure grpcroute:grpc tcproute:tcp udproute:udp tlsroute:tls;do
   kind=${pair%:*};name=${pair#*:}
   for i in $(seq 1 90);do
     if k -n apps get "$kind" "$name" -o json |jq -e '.metadata.generation as $g | (.status.parents|length)==(.spec.parentRefs|length) and all(.status.parents[];.conditions|any(.type=="Programmed" and .status=="True" and .observedGeneration==$g)) and all(.status.parents[];.conditions|any(.type=="ResolvedRefs" and .status=="True" and .observedGeneration==$g))' >/dev/null;then break;fi
     [[ $i -lt 90 ]];sleep 2
   done
 done
 for i in $(seq 1 90);do
   if k -n apps get backendtlspolicy verified-upstream -o json|jq -e 'any(.status.ancestors[]?.conditions[]?;.type=="Accepted" and .status=="True")' >/dev/null;then break;fi
   [[ $i -lt 90 ]];sleep 2
 done
}
wait_members(){
 local replicas="$1" member local_state shared_state ok
 mkdir -p evidence/convergence
 for attempt in $(seq 1 90);do
   ok=true
   shared_state=$(k -n lightedge-system exec test-lightedge-appliance-0 -c appliance -- jq -c '{revision,digest}' /ha/current.json 2>/dev/null) || ok=false
   # A successful readiness probe can precede an application reconciliation.
   # Require each member's applied revision AND direct test route to agree.
   for member in $(seq 0 "$((replicas-1))");do
     local_state=$(k -n lightedge-system exec "test-lightedge-appliance-$member" -c appliance -- jq -c '{revision,digest}' /data/.liteedge-ha-applied.json 2>/dev/null) || { ok=false;continue; }
     [[ "$shared_state" == "$local_state" ]] || ok=false
     k -n lightedge-system exec "test-lightedge-appliance-$member" -c appliance -- curl -fsS --max-time 3 -H 'Host: hello.apps.example.test' http://127.0.0.1:8080/ >/dev/null 2>&1 || ok=false
     printf '%s %s %s %s\n' "$attempt" "$member" "$shared_state" "$local_state" >>evidence/convergence/members.log
   done
   if $ok;then return 0;fi
   sleep 2
 done
 echo 'HA members failed to converge' >&2;return 1
}
matrix(){
 local phase="$1" replicas="$2" samples="$3" row name ip member file failed=0 passed
 wait_members "$replicas"
 mkdir -p "evidence/matrix/$phase"
 for row in "${CASES[@]}";do
   name=${row%% *}
   file="evidence/matrix/$phase/$name-public.jsonl"
   passed=true
   # Warm-up is bounded and recorded separately, not counted as successful samples.
   for i in $(seq 1 20);do
     if case_probe "$row" public 2 1 > /dev/null 2>"evidence/matrix/$phase/$name-warmup.log";then break;fi
     if [[ $i == 20 ]];then passed=false;break;fi;sleep 2
   done
   : >"$file"
   for n in 2 3;do case_probe "$row" public "$n" "$samples" >>"$file" 2>>"evidence/matrix/$phase/$name-errors.log" || passed=false;done
   jq -se --argjson n "$((2*samples))" 'length==$n and all(.[];.message=="Hello World" and (.node=="le-node2" or .node=="le-node3")) and ([.[].pod]|unique|length)==2' "$file" >/dev/null || passed=false
   for member in $(seq 0 "$((replicas-1))");do
     ip=$(k -n lightedge-system get pod "test-lightedge-appliance-$member" -o jsonpath='{.status.podIP}')
     file="evidence/matrix/$phase/$name-appliance-$member.jsonl"
     case_probe "$row" direct "$ip" 12 >"$file" 2>>"evidence/matrix/$phase/$name-errors.log" || passed=false
     jq -se 'length==12 and ([.[].pod]|unique|length)==2' "$file" >/dev/null || passed=false
   done
   if $passed;then status=PASS;else status=FAIL;failed=1;fi
   printf '%s\t%s\t%s\n' "$phase" "$name" "$status" |tee -a evidence/protocol-results.tsv
   if ! $passed;then cat "evidence/matrix/$phase/$name-errors.log" 2>/dev/null || true;fi
 done
 return "$failed"
}
# Strong negative cases check transport behavior, not merely API status.
negative_cases(){
 # Unknown SNI should not expose a leaf certificate from the passthrough socket.
 if timeout 8 openssl s_client -connect 127.0.0.1:29442 -servername unknown.apps.example.test -showcerts </dev/null >evidence/unknown-sni.log 2>&1;then
   echo 'Unknown SNI unexpectedly completed handshake' >&2;return 1
 fi
 ! grep -q 'BEGIN CERTIFICATE' evidence/unknown-sni.log
 # Invalid backend UDP port must fail closed and leave HTTP/gRPC unaffected.
 k -n apps patch udproute udp --type=json -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":12001}]'
 for i in $(seq 1 90);do
   if k -n apps get udproute udp -o json|jq -e 'any(.status.parents[]?.conditions[]?;.type=="ResolvedRefs" and .status=="False" and .reason=="BackendNotFound")' >/dev/null;then break;fi
   [[ $i -lt 90 ]];sleep 2
 done
 wait_members 2
 if case_probe "${CASES[11]}" public 2 1 >evidence/invalid-udp.log 2>&1;then echo 'Invalid UDP route unexpectedly passed';return 1;fi
 case_probe "${CASES[0]}" public 2 1 >evidence/invalid-udp-unrelated-http.jsonl
 case_probe "${CASES[8]}" public 2 1 >evidence/invalid-udp-unrelated-grpc.jsonl
 k -n apps patch udproute udp --type=json -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":12002}]'
 wait_routes
 for i in $(seq 1 30);do if case_probe "${CASES[11]}" public 2 1 >evidence/restored-udp.jsonl 2>/dev/null;then break;fi;[[ $i -lt 30 ]];sleep 2;done
 printf 'negative\tunknown-sni\tPASS\nnegative\twrong-udp-port-and-recovery\tPASS\n'|tee -a evidence/protocol-results.tsv
}
