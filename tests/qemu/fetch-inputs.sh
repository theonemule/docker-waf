#!/usr/bin/env bash
set -euo pipefail
cache="$1";mkdir -p "$cache";cd "$cache"
# One per-host lock prevents readers seeing partially written inputs. Each
# cached artifact is checked against the versioned expected digest on every run.
exec 9>.fetch.lock
flock -w 120 9
fetch(){
  local algo="$1" digest="$2" file="$3" url
  shift 3
  if [[ -f "$file" ]] && printf '%s  %s\n' "$digest" "$file" | "${algo}sum" -c --status; then
    echo "Verified cached $file"
    return
  fi
  rm -f "$file" "$file.part"
  for url in "$@"; do
    if curl -fLsS --retry 2 --connect-timeout 10 --speed-limit 1024 --speed-time 20 --max-time 300 "$url" -o "$file.part" &&
       printf '%s  %s\n' "$digest" "$file.part" | "${algo}sum" -c --status; then
      mv "$file.part" "$file"
      echo "Verified downloaded $file"
      return
    fi
    rm -f "$file.part"
    echo "Fetch or checksum failed: $url" >&2
  done
  return 1
}
alpine="alpine-3.22.6-x86_64-bios-cloudinit-r0.qcow2"
base=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud
k3s=https://github.com/k3s-io/k3s/releases/download/v1.34.3%2Bk3s1
fetch sha512 864ad8b9e3d14272d592f380c814c647bb6666fcd5b73c86dc21528da71306a93f2ce29b89ea8e6099b76786bb7835f0e27ca1824ec7f4b0b243160a13ba262d "$alpine" "$base/$alpine" "https://dl-2.alpinelinux.org/alpine/v3.22/releases/cloud/$alpine"
fetch sha256 f95350e3997165974d1d1406f01aabaf869aed7ca790cc2d83a92a82f26a06c5 k3s "$k3s/k3s"
fetch sha256 b8dff3265568e1be66ab72ac0ded68bd266fa37a32c010f1253dba6547a49ce8 k3s-airgap-images-amd64.tar.zst "$k3s/k3s-airgap-images-amd64.tar.zst"
fetch sha256 0414b160767377e85fd362855501200c6b83b84758bcd532652e3fe1cc677e49 gateway-api-v1.4.0-experimental.yaml https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml
