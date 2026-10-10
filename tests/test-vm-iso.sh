#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for file in scripts/install-alpine.sh scripts/build-vm-iso-inner.sh scripts/vm-firstboot.sh scripts/vm-iso-install.sh scripts/genapkovl-liteedge.sh scripts/mkimg.liteedge.sh; do
  sh -n "$ROOT/$file"
done
bash -n "$ROOT/scripts/build-vm-iso.sh"
grep -Fq 'build-iso:' "$ROOT/.github/workflows/build-and-publish.yml"
grep -Fq 'build-appliance, build-container, build-iso' "$ROOT/.github/workflows/build-and-publish.yml"
grep -Fq 'lteedge' "$ROOT/scripts/mkimg.liteedge.sh" && { echo 'Typo in ISO profile' >&2; exit 1; } || true
grep -Fq 'apkovl="genapkovl-liteedge.sh"' "$ROOT/scripts/mkimg.liteedge.sh"
grep -Fq 'linux-lts' "$ROOT/scripts/genapkovl-liteedge.sh"
grep -Fq 'grub-efi' "$ROOT/scripts/genapkovl-liteedge.sh"
grep -Fq 'fcgiwrap' "$ROOT/scripts/genapkovl-liteedge.sh"
grep -Fq 'spawn-fcgi' "$ROOT/scripts/genapkovl-liteedge.sh"
grep -Fq 'libmaxminddb' "$ROOT/scripts/genapkovl-liteedge.sh"
grep -Fq 'setup-alpine -f' "$ROOT/scripts/vm-iso-install.sh"
grep -Fq '/etc/liteedge-offline' "$ROOT/scripts/vm-firstboot.sh"
grep -Fq '/local.d/liteedge-firstboot.start' "$ROOT/scripts/genapkovl-liteedge.sh"
grep -Fq 'apk info -e' "$ROOT/scripts/install-alpine.sh"
grep -Fq 'sha256sum -c' "$ROOT/scripts/build-vm-iso.sh"
echo 'PASS offline VM ISO pipeline, BIOS/UEFI profile, dependency set and first-boot contracts'
