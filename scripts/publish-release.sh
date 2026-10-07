#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
case "$VERSION" in v*) VERSION="${VERSION#v}" ;; esac
TAG="v$VERSION"

command -v gh >/dev/null 2>&1 || { echo "gh is required." >&2; exit 1; }
"$ROOT/scripts/build-release.sh"

ARCH="$(uname -m)"
ASSET="$ROOT/dist/liteedge-linux-musl-${ARCH}.tar.gz"
CHECKSUM="$ASSET.sha256"

if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
  echo "Commit the release source before publishing." >&2
  exit 1
fi

if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists." >&2
  exit 1
fi

git -C "$ROOT" tag -a "$TAG" -m "LiteEdge $VERSION"
git -C "$ROOT" push origin "$TAG"

gh release create "$TAG" "$ASSET" "$CHECKSUM" \
  --repo theonemule/docker-waf \
  --title "LiteEdge $VERSION" \
  --notes "Pre-built Alpine/musl LiteEdge runtime containing NGINX with the ModSecurity connector compiled in, libModSecurity, OWASP CRS, dehydrated, and the complete LiteEdge management/runtime scripts and UI."
