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
tmp="$(mktemp -d)"
container_created=0
fixture_image="lightedge-qemu-fixture:${name##*-}"
cleanup(){
 rc=$?;set +e
 if [[ $container_created == 1 ]];then
   docker cp "$name:/lab/evidence/." "$out/" 2>/dev/null || true
   docker logs "$name" >"$out/runner.log" 2>&1 || true
   docker rm -fv "$name" >/dev/null 2>&1||true
 fi
 docker image rm "$fixture_image" >/dev/null 2>&1 || true
 rm -rf "$tmp"
 printf '%s\n' "$rc" >"$out/host-result.exit"
 echo "Evidence: $out"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bash tests/qemu/fetch-inputs.sh "$cache"
docker build --no-cache --pull -t lightedge-qemu-harness:dev tests/qemu
docker build --no-cache --pull -t "$fixture_image" tests/qemu/fixture
docker image inspect "$edge" "$controller" "$fixture_image" --format '{{.Id}} {{.RepoTags}}' >"$out/image-ids.txt"
docker save "$edge" "$controller" "$fixture_image" -o "$tmp/lightedge-images.tar"
device=()
if docker run --rm --device /dev/kvm --entrypoint sh lightedge-qemu-harness:dev -c "test -r /dev/kvm && test -w /dev/kvm" >/dev/null 2>&1;then device=(--device /dev/kvm);fi
docker create --name "$name" "${device[@]}" --shm-size=64m \
  -e "EDGE_IMAGE=$edge" -e "CONTROLLER_IMAGE=$controller" -e "FIXTURE_IMAGE=$fixture_image" -e "QEMU_WORKER_MEM_MB=${QEMU_WORKER_MEM_MB:-1536}" -e "QEMU_CONTROL_MEM_MB=${QEMU_CONTROL_MEM_MB:-2048}" \
  --entrypoint bash lightedge-qemu-harness:dev /lab/input/run.sh >/dev/null
container_created=1
mkdir -p "$tmp/input" "$tmp/lab/evidence"
cp tests/qemu/{run.sh,ha-pv.yaml,hello.yaml,values.yaml,matrix.sh,memory-sampler.sh} "$tmp/input/"
id=$(docker create "$fixture_image")
docker cp "$id:/probe" "$tmp/input/probe"
docker rm "$id" >/dev/null
cp -a deploy/kubernetes/helm/lightedge "$tmp/input/chart"
cp -L "$kubectl_path" "$tmp/input/kubectl"
cp -L "$helm_path" "$tmp/input/helm"
cp "$cache/alpine-3.22.6-x86_64-bios-cloudinit-r0.qcow2" "$tmp/input/alpine.qcow2"
cp "$cache"/{k3s,k3s-airgap-images-amd64.tar.zst} "$tmp/input/"
cp "$cache/gateway-api-v1.4.0-experimental.yaml" "$tmp/input/gateway-api.yaml"
mv "$tmp/lightedge-images.tar" "$tmp/input/"
chmod +x "$tmp/input/"{k3s,kubectl,helm,run.sh}
mv "$tmp/input" "$tmp/lab/"
docker cp "$tmp/lab" "$name:/lab"
echo "Runner container: $name"
docker start -a "$name"
