#!/usr/bin/env bash
# Run on the dedicated, serialized CI163 runner only. Never touch the manual lab.
set -euo pipefail
scope="${1:?CI scope or all}"
label=com.lightedge.ci.qemu
filter=(--filter "label=$label=true")
if [[ "$scope" != all ]]; then
  [[ "$scope" =~ ^[0-9]+-[0-9]+-(single|[123])$ ]]
  filter+=(--filter "label=$label.scope=$scope")
fi
containers=$(docker ps -aq "${filter[@]}")
for id in $containers; do docker rm -fv "$id"; done
networks=$(docker network ls -q "${filter[@]}")
for id in $networks; do docker network rm "$id"; done
volumes=$(docker volume ls -q "${filter[@]}")
for id in $volumes; do docker volume rm "$id"; done
images=$(docker image ls -q "${filter[@]}" | sort -u)
for id in $images; do docker image rm "$id"; done
[[ -z "$(docker ps -aq "${filter[@]}")" ]]
[[ -z "$(docker network ls -q "${filter[@]}")" ]]
[[ -z "$(docker volume ls -q "${filter[@]}")" ]]
[[ -z "$(docker image ls -q "${filter[@]}")" ]]
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  if [[ "$scope" == all ]]; then
    for dir in "$RUNNER_TEMP"/lightedge-qemu-ci-*; do
      [[ -e "$dir" ]] || continue
      suffix="${dir##*/lightedge-qemu-ci-}"
      [[ "$suffix" =~ ^[0-9]+-[0-9]+-(single|[123])$ ]] || continue
      rm -rf -- "$dir"
      [[ ! -e "$dir" ]]
    done
  else
    rm -rf -- "$RUNNER_TEMP/lightedge-qemu-ci-$scope"
    [[ ! -e "$RUNNER_TEMP/lightedge-qemu-ci-$scope" ]]
  fi
fi
echo "PASS no disposable QEMU CI resources remain ($scope)"
