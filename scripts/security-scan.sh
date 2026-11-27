#!/usr/bin/env bash
# Scan the exact built images and tracked source, never a mutable registry tag.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(realpath -m "${1:?report directory required}")"; shift
mkdir -p "$out"
[[ $# == 2 ]] || { echo "Two candidate images required" >&2; exit 1; }
rm -f "$out/source-secrets.json" "$out/image-1.json" "$out/image-2.json" "$out/image-1.id" "$out/image-2.id"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
version=0.76.2
digest=bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf
curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 \
  "https://github.com/aquasecurity/trivy/releases/download/v$version/trivy_${version}_Linux-64bit.tar.gz" -o "$work/trivy.tar.gz"
printf '%s  %s\n' "$digest" "$work/trivy.tar.gz" | sha256sum -c -
tar -xzf "$work/trivy.tar.gz" -C "$work" trivy
scanner="$work/trivy"
"$scanner" --version
sanitize() {
  # Never export matching secret text or snippets into a GitHub artifact.
  jq '(.Results[]? | .Secrets[]?) |= {RuleID,Category,Severity,Title,StartLine,EndLine}' "$1" > "$2"
}
mkdir "$work/source"
git -C "$ROOT" archive HEAD | tar -x -C "$work/source"
# Keep reports outside the source tree. JSON reports may contain detected
# secrets: Trivy masks matches, and the workflow retains reports briefly.
"$scanner" fs --cache-dir "$work/cache" --scanners secret --format json --output "$work/source-secrets.json" "$work/source"
sanitize "$work/source-secrets.json" "$out/source-secrets.json"
n=0
for image in "$@";do
  n=$((n+1))
  docker image inspect "$image" --format '{{.Id}}' > "$out/image-$n.id"
  docker save "$image" -o "$work/image.tar"
  "$scanner" image --cache-dir "$work/cache" --input "$work/image.tar" --scanners vuln,secret --format json --output "$work/image-$n.json" --timeout 8m
  sanitize "$work/image-$n.json" "$out/image-$n.json"
  rm -f "$work/image.tar"
done
python3 "$ROOT/scripts/security-scan-gate.py" "$out"
