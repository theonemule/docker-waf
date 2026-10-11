#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/release" "$TMP/install" "$TMP/invalid"
cp "$ROOT/docker-compose.yml" "$TMP/release/docker-compose.yml"
(cd "$TMP/release" && sha256sum docker-compose.yml > docker-compose.yml.sha256)
cat > "$TMP/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
out='' url=''
while (( $# )); do
  if [[ "$1" == -o ]]; then out="$2"; shift 2; else url="$1"; shift; fi
done
[[ "$url" == "https://github.com/acme/my-image/releases/download/${FAKE_RELEASE_TAG:-v3.4.5}/"* ]] || exit 4
cp "$FAKE_RELEASE_DIR/${url##*/}" "$out"
MOCK_CURL
cat > "$TMP/bin/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
MOCK_DOCKER
chmod +x "$TMP/bin/curl" "$TMP/bin/docker"
sed 's/__LITEEDGE_RELEASE_TAG__/v3.4.5/g' "$ROOT/install.sh" > "$TMP/install/install-docker.sh"
chmod +x "$TMP/install/install-docker.sh"
(
  cd "$TMP/install"
  FAKE_RELEASE_DIR="$TMP/release" FAKE_DOCKER_LOG="$TMP/docker.log" LITEEDGE_REPO=acme/my-image \
    PATH="$TMP/bin:$PATH" ./install-docker.sh >/dev/null
)
cmp "$TMP/release/docker-compose.yml" "$TMP/install/docker-compose.yml"
grep -qx 'LITEEDGE_VERSION=v3.4.5' "$TMP/install/.env"
grep -qx 'LITEEDGE_REPO=acme/my-image' "$TMP/install/.env"
grep -qx 'compose pull' "$TMP/docker.log"
grep -qx 'compose up -d' "$TMP/docker.log"

# Regression: a valid release tag containing the placeholder's text must not
# be confused with the unexpanded source sentinel. Run as a download would:
# non-executable file invoked with Bash.
for tag in v3.4.5-LITEEDGE_RELEASE_TAG v3.4.5-__LITEEDGE_RELEASE_TAG__; do
  mkdir -p "$TMP/$tag"
  sed "s/__LITEEDGE_RELEASE_TAG__/$tag/g" "$ROOT/install.sh" > "$TMP/$tag/install-docker.sh"
  chmod 0644 "$TMP/$tag/install-docker.sh"
  (
    cd "$TMP/$tag"
    FAKE_RELEASE_TAG="$tag" FAKE_RELEASE_DIR="$TMP/release" FAKE_DOCKER_LOG="$TMP/docker-$tag.log" \
      LITEEDGE_REPO=acme/my-image PATH="$TMP/bin:$PATH" bash install-docker.sh >/dev/null
  )
  cmp "$TMP/release/docker-compose.yml" "$TMP/$tag/docker-compose.yml"
  grep -Fxq "LITEEDGE_VERSION=$tag" "$TMP/$tag/.env"
  grep -Fxq 'compose pull' "$TMP/docker-$tag.log"
done

# A bad checksum must abort before installation and must not install the Compose file.
printf '0000000000000000000000000000000000000000000000000000000000000000  docker-compose.yml\n' > "$TMP/release/docker-compose.yml.sha256"
cp "$TMP/install/install-docker.sh" "$TMP/invalid/install-docker.sh"
if (cd "$TMP/invalid" && FAKE_RELEASE_DIR="$TMP/release" FAKE_DOCKER_LOG="$TMP/docker-bad.log" \
     LITEEDGE_REPO=acme/my-image PATH="$TMP/bin:$PATH" ./install-docker.sh >/dev/null 2>&1); then
  echo 'Installer accepted an invalid Compose checksum.' >&2; exit 1
fi
[[ ! -f "$TMP/invalid/docker-compose.yml" ]]
[[ ! -e "$TMP/docker-bad.log" ]]

# Exercise the CGI import endpoint with a stub bundlectl so argument forwarding
# and request rejection can be verified without a running WAF appliance.
cat > "$TMP/common.sh" <<'MOCK_COMMON'
bool_value() { if [[ "${1:-0}" == 1 ]]; then echo 1; else echo 0; fi; }
MOCK_COMMON
cat > "$TMP/bundlectl.sh" <<'MOCK_BUNDLE'
#!/usr/bin/env bash
printf 'bundle_scope=%s bundle_host=%s\n' "${4:-}" "${5:-}"
MOCK_BUNDLE
chmod +x "$TMP/bundlectl.sh"
sed -e 's@source /opt/liteedge/bin/common.sh@source "$LITEEDGE_TEST_COMMON"@' \
    -e 's@/opt/liteedge/bin/bundlectl.sh import@"$LITEEDGE_TEST_BUNDLECTL" import@' \
    "$ROOT/cgi/admin.sh" > "$TMP/admin.sh"
chmod +x "$TMP/admin.sh"
request_import() {
  printf 'test' | PATH_INFO=/admin/import REQUEST_METHOD=POST CONTENT_LENGTH=4 \
    QUERY_STRING="$1" LITEEDGE_TEST_COMMON="$TMP/common.sh" \
    LITEEDGE_TEST_BUNDLECTL="$TMP/bundlectl.sh" "$TMP/admin.sh"
}
site_result="$(request_import 'scope=site&host=example.com&certificates=1')"
grep -q 'bundle_scope=site bundle_host=example.com' <<< "$site_result"
global_result="$(request_import 'certificates=0')"
grep -q 'bundle_scope= bundle_host=' <<< "$global_result"
for invalid in 'scope=site' 'scope=all&host=example.com' 'scope=site&host=bad/host'; do
  response="$(request_import "$invalid")"
  grep -q 'Status: 400 Bad Request' <<< "$response"
  if grep -q 'bundle_scope=' <<< "$response"; then echo "Rejected request reached bundlectl: $invalid" >&2; exit 1; fi
done

echo 'PASS: versioned installer, checksum rejection, and scoped CGI import contracts'