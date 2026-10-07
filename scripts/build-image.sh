#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-3.0.0}"
IMAGE="${IMAGE:-ghcr.io/theonemule/docker-waf:local}"
ARCH="$(uname -m)"
"$ROOT/scripts/build-release.sh" "$VERSION"
docker build --build-arg "LITEEDGE_ARCH=$ARCH" -t "$IMAGE" "$ROOT"
