#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/build/versions.env"
VERSION="${1:-${VERSION:-0.1.0}}"
BUILD_JOBS="${BUILD_JOBS:-1}"
case "$VERSION" in v*) VERSION="${VERSION#v}" ;; esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || { echo "Invalid VERSION: $VERSION" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Docker is required to produce the Alpine release artifact." >&2; exit 1; }

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
else
  echo "Docker is installed but this user cannot access the Docker daemon." >&2
  exit 1
fi

mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/liteedge-linux-musl-"*.tar.gz "$ROOT/dist/liteedge-linux-musl-"*.sha256
"${DOCKER[@]}" run --rm \
  -e VERSION="$VERSION" \
  -e BUILD_JOBS="$BUILD_JOBS" \
  -v "$ROOT:/src" \
  -w /src \
  "alpine:${ALPINE_VERSION}@${ALPINE_DIGEST}" \
  /bin/sh /src/scripts/build-release-inner.sh
echo
echo "Release artifacts:"
ls -lh "$ROOT"/dist/liteedge-linux-musl-*
