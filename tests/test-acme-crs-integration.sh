#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/data/sites" "$TMP/data/certs" "$TMP/data/imported/sites" "$TMP/testbin"
cat > "$TMP/common.sh" <<'COMMON'
DATA_DIR="${DATA_DIR:?}"
SITE_DIR="$DATA_DIR/sites"
CERT_DIR="$DATA_DIR/certs"
ACME_DIR="$DATA_DIR/acme"
die() { echo "$*" >&2; exit 1; }
kv_get() { sed -n "s/^$2=//p" "$1" | head -1; }
slug_for_host() { printf '%s' "$1"; }
site_file() { printf '%s/%s.site' "$SITE_DIR" "$1"; }
cert_dir() { printf '%s/%s' "$CERT_DIR" "$1"; }
validate_host() { [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]; }
validate_aliases() { :; }
COMMON
printf 'HOST=one.example\nALIASES=\n' > "$TMP/data/sites/one.example.site"
printf 'HOST=two.example\nALIASES=\n' > "$TMP/data/sites/two.example.site"
sed 's@source /opt/liteedge/bin/common.sh@source "$ACME_TEST_COMMON"@' "$ROOT/bin/certctl.sh" > "$TMP/testbin/certctl.sh"
chmod +x "$TMP/testbin/certctl.sh"
export DATA_DIR="$TMP/data" ACME_TEST_COMMON="$TMP/common.sh"
"$TMP/testbin/certctl.sh" set-email one.example one@example.org
"$TMP/testbin/certctl.sh" set-email two.example two@example.net
[[ "$(cat "$TMP/data/certs/one.example/acme-email")" == one@example.org ]]
[[ "$(cat "$TMP/data/certs/two.example/acme-email")" == two@example.net ]]
[[ "$(stat -c '%a' "$TMP/data/certs/one.example/acme-email")" == 600 ]]
if "$TMP/testbin/certctl.sh" set-email one.example 'malicious";foo@example.org' >/dev/null 2>&1; then
  echo 'Unsafe email accepted' >&2; exit 1
fi

mkdir -p "$TMP/data/imported/sites/one.example" "$TMP/data/imported/sites/two.example" "$TMP/data/sites/two.example.routes"
cat > "$TMP/data/imported/sites/one.example/template.conf" <<'CONF'
server {
 if ($host = one.example) {
    return 301 https://$host$request_uri;
 } # managed by Certbot
 listen 8080;
 server_name one.example;
 return 404; # managed by Certbot
 # LITEEDGE_EXTRA_ROUTES:http
}
CONF
cat > "$TMP/data/imported/sites/two.example/template.conf" <<'CONF'
server {
 listen 8080;
 server_name two.example;
 # LITEEDGE_IMPORTED_LOCATION:1111111111111111
 return 301 https://$host$request_uri;
 # LITEEDGE_EXTRA_ROUTES:http
}
CONF
cat > "$TMP/data/sites/two.example.routes/acme.route" <<'ROUTE'
PATH=/.well-known/acme-challenge/
IMPORT_SCHEME=http
ACTION=custom
ROUTE
python3 "$ROOT/scripts/enable-imported-acme-http01.py" --data "$TMP/data" --apply >/dev/null
first="$(sha256sum "$TMP/data/imported/sites/"*/template.conf)"
python3 "$ROOT/scripts/enable-imported-acme-http01.py" --data "$TMP/data" --apply >/dev/null
second="$(sha256sum "$TMP/data/imported/sites/"*/template.conf)"
[[ "$first" == "$second" ]] || { echo 'Nonidempotent ACME template patch' >&2; exit 1; }
grep -q 'location ^~ /.well-known/acme-challenge/' "$TMP/data/imported/sites/one.example/template.conf"
! grep -q '^\s*if (\$host = one.example)' "$TMP/data/imported/sites/one.example/template.conf"
[[ "$(grep -c 'location ^~ /.well-known/acme-challenge/' "$TMP/data/imported/sites/two.example/template.conf" || true)" == 0 ]]
[[ "$(grep -c 'location / {' "$TMP/data/imported/sites/two.example/template.conf")" == 1 ]]
echo 'PASS: separate site contact emails, input validation, secure files, HTTP-01 challenge with redirects and idempotence'
