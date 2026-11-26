#!/usr/bin/env bash
# Run on a disposable development host with Docker, curl, openssl and enough
# disk/RAM for three VMs. Never uses the current kubeconfig or host networking.
set -euo pipefail
[[ $# == 3 ]] || { echo "Usage: $0 EDGE_IMAGE CONTROLLER_IMAGE EVIDENCE_DIRECTORY" >&2;exit 2; }
edge="$1";controller="$2";out="$(realpath -m "$3")"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
[[ ! -e "$out" ]] || { echo "Evidence directory must not already exist" >&2;exit 2; }
mkdir -p "$out"
cache="${QEMU_CACHE_DIR:-$HOME/.cache/lightedge-qemu}"
mkdir -p "$cache"
cache="$(realpath "$cache")"
kubectl_path="$(command -v kubectl)"
helm_path="$(command -v helm)"
name="lightedge-qemu-$(openssl rand -hex 5)"
labels=()
build_labels=()
if [[ -n "${QEMU_CI_SCOPE:-}" ]]; then
  [[ "$QEMU_CI_SCOPE" =~ ^[0-9]+-[0-9]+-(single|[123])$ ]]
  [[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" ]]
  tmp="$RUNNER_TEMP/lightedge-qemu-ci-$QEMU_CI_SCOPE"
  mkdir "$tmp"
  labels=(--label com.lightedge.ci.qemu=true --label "com.lightedge.ci.qemu.scope=$QEMU_CI_SCOPE")
  build_labels=("${labels[@]}")
else
  tmp="$(mktemp -d)"
fi
harness_image="lightedge-qemu-harness:${name##*-}"
fixture_container="$name-fixture"
container_created=0
network_created=0
fixture_image="lightedge-qemu-fixture:${name##*-}"
cleanup(){
 rc=$?;set +e
 if [[ $container_created == 1 ]];then
   docker cp "$name:/lab/evidence/." "$out/" 2>/dev/null || rc=1
   docker logs "$name" >"$out/runner.log" 2>&1 || rc=1
   # Successful qualification must carry proof of guest destruction and boot
   # validation, not just a successful Docker exit status.
   if [[ "$rc" == 0 ]];then
     grep -Fxq 'PASS mutable VM disks and private state removed' "$out/guest-cleanup.txt" || rc=1
     for n in 1 2 3;do
       [[ -s "$out/node$n-boot-id.txt" && -s "$out/node$n-provisioning.txt" && -s "$out/le-node$n-disk.json" ]] || rc=1
     done
   fi
   docker rm -fv "$name" >/dev/null 2>&1 || rc=1
   if docker container inspect "$name" >/dev/null 2>&1;then rc=1;fi
 fi
 if [[ $network_created == 1 ]];then docker network rm "$name" >/dev/null || { echo "Failed to remove test network $name" >&2; if [[ $rc == 0 ]];then rc=1;fi; };fi
 if docker container inspect "$fixture_container" >/dev/null 2>&1;then docker rm -fv "$fixture_container" >/dev/null || rc=1;fi
 for image in "$fixture_image" "$harness_image";do
   if docker image inspect "$image" >/dev/null 2>&1;then docker image rm "$image" >/dev/null || rc=1;fi
 done
 rm -rf "$tmp" || rc=1
 [[ ! -e "$tmp" ]] || rc=1
 if [[ -n "${QEMU_CI_SCOPE:-}" ]];then
   bash tests/qemu/cleanup-ci.sh "$QEMU_CI_SCOPE" >"$out/cleanup.log" 2>&1 || rc=1
 fi
 cat "$out/cleanup.log" 2>/dev/null || true
 printf '%s\n' "$rc" >"$out/host-result.exit"
 echo "Evidence: $out"
 exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bash tests/qemu/fetch-inputs.sh "$cache"
docker build --no-cache --pull "${build_labels[@]}" -t "$harness_image" tests/qemu
docker build --no-cache --pull "${build_labels[@]}" -t "$fixture_image" tests/qemu/fixture
docker image inspect "$edge" "$controller" "$fixture_image" --format '{{.Id}} {{.RepoTags}}' >"$out/image-ids.txt"
docker save "$edge" "$controller" "$fixture_image" -o "$tmp/lightedge-images.tar"
device=()
if docker run --rm --device /dev/kvm "${labels[@]}" --entrypoint sh "$harness_image" -c "test -r /dev/kvm && test -w /dev/kvm" >/dev/null 2>&1;then device=(--device /dev/kvm);fi
# Separate L2 segment: the persistent manual lab uses the default bridge and
# the same guest IPs. Never let its multicast frames reach these test VMs.
docker network create --driver bridge "${labels[@]}" "$name" >/dev/null
network_created=1
docker create --name "$name" "${labels[@]}" --network "$name" "${device[@]}" --shm-size=64m \
  -e "EDGE_IMAGE=$edge" -e "CONTROLLER_IMAGE=$controller" -e "FIXTURE_IMAGE=$fixture_image" -e "QEMU_WORKER_MEM_MB=${QEMU_WORKER_MEM_MB:-1536}" -e "QEMU_CONTROL_MEM_MB=${QEMU_CONTROL_MEM_MB:-2048}" \
  --entrypoint bash "$harness_image" /lab/input/run.sh >/dev/null
container_created=1
mkdir -p "$tmp/input" "$tmp/lab/evidence"
cp tests/qemu/{run.sh,ha-pv.yaml,hello.yaml,values.yaml,matrix.sh,memory-sampler.sh} "$tmp/input/"
id=$(docker create --name "$fixture_container" "${labels[@]}" "$fixture_image")
docker cp "$id:/probe" "$tmp/input/probe"
docker rm -v "$id" >/dev/null
cp -a deploy/kubernetes/helm/lightedge "$tmp/input/chart"
cp -L "$kubectl_path" "$tmp/input/kubectl"
cp -L "$helm_path" "$tmp/input/helm"
cp "$cache/alpine-3.22.6-x86_64-bios-cloudinit-r0.qcow2" "$tmp/input/alpine.qcow2"
chmod 0444 "$tmp/input/alpine.qcow2"
cp "$cache"/{k3s,k3s-airgap-images-amd64.tar.zst} "$tmp/input/"
cp "$cache/gateway-api-v1.4.0-experimental.yaml" "$tmp/input/gateway-api.yaml"
mv "$tmp/lightedge-images.tar" "$tmp/input/"
chmod +x "$tmp/input/"{k3s,kubectl,helm,run.sh}
mv "$tmp/input" "$tmp/lab/"
docker cp "$tmp/lab" "$name:/lab"
echo "Runner container: $name"
docker start -a "$name"
