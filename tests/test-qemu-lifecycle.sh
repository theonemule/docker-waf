#!/usr/bin/env bash
# Contract test: teardown must be part of qualification even on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n tests/test-qemu-kubernetes.sh tests/qemu/run.sh tests/qemu/cleanup-ci.sh
grep -Fq 'qemu-img convert -f qcow2 -O qcow2' tests/qemu/run.sh
grep -Fq 'has("backing-filename")|not' tests/qemu/run.sh
grep -Fq 'qemu-img check' tests/qemu/run.sh
grep -Fq 'boot_nonce-$name' tests/qemu/run.sh
grep -Fq 'cloud-init status --wait' tests/qemu/run.sh
grep -Fq 'test ! -e /var/lib/rancher/k3s' tests/qemu/run.sh
grep -Fq '.status.nodeInfo.bootID==$boot' tests/qemu/run.sh
grep -Fq 'rm -rf /lab/private' tests/qemu/run.sh
grep -Fq 'docker rm -fv' tests/test-qemu-kubernetes.sh
grep -Fq 'com.lightedge.ci.qemu.scope=' tests/test-qemu-kubernetes.sh
grep -Fq 'bash tests/qemu/cleanup-ci.sh all' .github/workflows/build-and-publish.yml
grep -Fq 'Destroy and verify disposable QEMU resources' .github/workflows/build-and-publish.yml
grep -Fq "if: always() && matrix.suite == 'qemu'" .github/workflows/build-and-publish.yml
echo 'PASS disposable VM provisioning and mandatory scoped cleanup contracts'
