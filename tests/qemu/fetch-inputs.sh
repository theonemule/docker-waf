#!/usr/bin/env bash
set -euo pipefail
cache="$1";mkdir -p "$cache";cd "$cache"
alpine=alpine-3.22.6-x86_64-bios-cloudinit-r0.qcow2
base=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud
k3s=https://github.com/k3s-io/k3s/releases/download/v1.34.3%2Bk3s1
fetch(){ local url="$1" file="$2";if [[ ! -s "$file" ]];then curl -fL --retry 3 --connect-timeout 15 "$url" -o "$file.part";mv "$file.part" "$file";fi; }
fetch "$base/$alpine.sha512" "$alpine.sha512"
fetch "$base/$alpine" "$alpine"
printf "%s  %s\n" "$(head -c 128 "$alpine.sha512")" "$alpine" | sha512sum -c -
printf "%s  %s\n" 864ad8b9e3d14272d592f380c814c647bb6666fcd5b73c86dc21528da71306a93f2ce29b89ea8e6099b76786bb7835f0e27ca1824ec7f4b0b243160a13ba262d "$alpine" | sha512sum -c -
fetch "$k3s/sha256sum-amd64.txt" sha256sum-amd64.txt
fetch "$k3s/k3s" k3s
fetch "$k3s/k3s-airgap-images-amd64.tar.zst" k3s-airgap-images-amd64.tar.zst
grep -E ' [*]?(k3s|k3s-airgap-images-amd64.tar.zst)$' sha256sum-amd64.txt | sha256sum -c -
fetch https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml gateway-api-v1.4.0-experimental.yaml
