#!/usr/bin/env bash
# Run ONLY against an explicitly prepared qualification namespace, not a
# serving production namespace. Tests real RWX lock and rename coherence
# across distinct Kubernetes nodes, without changing the HA revision.
set -euo pipefail
[[ $# == 4 ]] || { echo "Usage: $0 KUBECONFIG CONTEXT QUALIFICATION_NAMESPACE HELM_RELEASE" >&2;exit 2; }
config="$1";context="$2";ns="$3";release="$4"
[[ -f "$config" && "$ns" =~ ^lightedge-qualify-[a-z0-9-]+$ && "$release" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo 'Explicit qualification namespace and kubeconfig required' >&2;exit 2; }
k=(kubectl --kubeconfig "$config" --context "$context")
[[ "$("${k[@]}" get ns "$ns" -o jsonpath='{.metadata.labels.lightedge\.io/qualification}')" == true ]] || { echo 'Namespace must be labelled lightedge.io/qualification=true' >&2;exit 2; }
kn=("${k[@]}" -n "$ns")
setname="$release-lightedge-appliance"
claim=$("${kn[@]}" get statefulset "$setname" -o json|jq -er '.spec.template.spec.volumes[]|select(.name=="shared-config")|.persistentVolumeClaim.claimName')
pv=$("${kn[@]}" get pvc "$claim" -o json|jq -er 'select(.status.phase=="Bound" and (.spec.accessModes|index("ReadWriteMany")!=null))|.spec.volumeName')
# hostPath/local PVs cannot substantiate a production shared-storage claim.
"${k[@]}" get pv "$pv" -o json|jq -e '(.spec|has("hostPath") or has("local")|not) and (.spec.accessModes|index("ReadWriteMany")!=null)' >/dev/null
mapfile -t pods < <("${kn[@]}" get pods -l "app.kubernetes.io/name=lightedge-appliance,app.kubernetes.io/instance=$release" -o json|jq -r '.items[]|select(.status.phase=="Running" and any(.status.conditions[]; .type=="Ready" and .status=="True"))|[.metadata.name,.spec.nodeName]|@tsv')
[[ ${#pods[@]} -ge 2 ]] || { echo 'Two Ready appliance replicas required' >&2;exit 1; }
read -r a node_a <<<"${pods[0]}";b="";node_b=""
for row in "${pods[@]:1}";do read -r candidate node <<<"$row";if [[ "$node" != "$node_a" ]];then b="$candidate";node_b="$node";break;fi;done
[[ -n "$b" ]] || { echo 'Replicas must run on distinct Kubernetes nodes' >&2;exit 1; }
echo "Qualification context=$context namespace=$ns claim=$claim PV=$pv nodes=$node_a,$node_b"
aexec(){ "${kn[@]}" exec "$a" -c appliance -- "$@"; }
bexec(){ "${kn[@]}" exec "$b" -c appliance -- "$@"; }
aexec python3 /opt/liteedge/bin/ha_config.py ready
bexec python3 /opt/liteedge/bin/ha_config.py ready
id="$(openssl rand -hex 16)"
path="/ha/.qualification-$id"
holder=""
cleanup(){ if [[ -n "$holder" ]];then wait "$holder" 2>/dev/null||true;fi;aexec python3 -c 'import shutil,sys;shutil.rmtree(sys.argv[1],ignore_errors=True)' "$path" >/dev/null 2>&1||true; }
trap cleanup EXIT
# Member A holds an isolated lock until B acknowledges contention. No
# mutation of current.json, provider state, or shared application records.
aexec python3 -c '
import fcntl,os,pathlib,sys,time
p=pathlib.Path(sys.argv[1]);p.mkdir(mode=0o700)
with (p/"lock").open("x") as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 with (p/"temporary").open("x") as f:
  f.write(sys.argv[2]);f.flush();os.fsync(f.fileno())
 os.replace(p/"temporary",p/"published")
 fd=os.open(p,os.O_RDONLY|os.O_DIRECTORY);os.fsync(fd);os.close(fd)
 (p/"ready").touch()
 for _ in range(300):
  if (p/"seen").exists():break
  time.sleep(.1)
 else:raise RuntimeError("peer did not observe shared storage")
' "$path" "$id" &
holder=$!
for i in $(seq 1 60);do if bexec test -f "$path/ready";then break;fi;test "$i" -lt 60;sleep .25;done
bexec python3 -c '
import fcntl,pathlib,sys
p=pathlib.Path(sys.argv[1]);assert (p/"published").read_text()==sys.argv[2]
with (p/"lock").open("r+") as lock:
 try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError:pass
 else:raise RuntimeError("RWX does not enforce cross-node exclusion")
(p/"seen").touch()
' "$path" "$id"
wait "$holder";holder=""
bexec python3 -c '
import fcntl,pathlib,sys
p=pathlib.Path(sys.argv[1])
with (p/"lock").open("r+") as lock:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
' "$path"
r0=$(aexec jq -er '.revision' /data/.liteedge-ha-applied.json)
r1=$(bexec jq -er '.revision' /data/.liteedge-ha-applied.json)
test "$r0" = "$r1"
echo "PASS cross-node RWX flock exclusion and release, rename visibility, fsync, readiness and equal signed revision $r0"
