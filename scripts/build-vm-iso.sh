#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/build/versions.env"
VERSION="${1:-3.0.0}"
ISO_VARIANT="${LITEEDGE_ISO_VARIANT:-vm}"
case "$ISO_VARIANT" in vm|baremetal) ;; *) echo "Unsupported ISO variant: $ISO_VARIANT" >&2; exit 1 ;; esac
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || { echo "Invalid release version" >&2; exit 1; }
[[ -s "$ROOT/dist/liteedge-linux-musl-x86_64.tar.gz" ]]
(cd "$ROOT/dist" && sha256sum -c liteedge-linux-musl-x86_64.tar.gz.sha256)
command -v docker >/dev/null 2>&1 || { echo 'Docker is required.' >&2; exit 1; }
mkdir -p "$ROOT/dist"
# Both the Alpine image and the ISO build scripts are pinned by immutable IDs.
docker run --rm --pull always \
  -e VERSION="$VERSION" \
  -e LITEEDGE_ISO_VARIANT="$ISO_VARIANT" \
  -e LITEEDGE_ISO_SOURCE=/src \
  -e APORTS_COMMIT="$APORTS_COMMIT" \
  -e ALPINE_VERSION="$ALPINE_VERSION" \
  -e ALPINE_APK_MIRROR="${ALPINE_APK_MIRROR:-https://dl-2.alpinelinux.org/alpine}" \
  -v "$ROOT:/src" \
  -w /src \
  "${ALPINE_BUILD_IMAGE:-docker.io/library/alpine:${ALPINE_VERSION}@${ALPINE_DIGEST}}" \
  /bin/sh /src/scripts/build-vm-iso-inner.sh
( cd "$ROOT/dist"; sha256sum -c "liteedge-${ISO_VARIANT}-installer-${VERSION}-x86_64.iso.sha256" )
ls -lh "$ROOT/dist/liteedge-${ISO_VARIANT}-installer-${VERSION}-x86_64.iso"*
