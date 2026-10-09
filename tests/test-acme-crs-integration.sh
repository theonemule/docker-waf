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

# Regression: both account registration and certificate issuance must use
# the same *site-specific, existing* config file. Previously --cron wrongly
# pointed to /data/acme/config even after a successful site registration.
mkdir -p "$TMP/testbin" "$TMP/data/acme/certs/one.example" "$TMP/data/acme/certs/two.example"
cat > "$TMP/testbin/dehydrated" <<'MOCK_ACME'
#!/usr/bin/env bash
set -euo pipefail
mode='' config='' cert_alias=''
while (( $# )); do
  case "$1" in
    --register) mode=register; shift ;;
    --cron) mode=cron; shift ;;
    --config) config="$2"; shift 2 ;;
    --alias) cert_alias="$2"; shift 2 ;;
    --domain) shift 2 ;;
    *) shift ;;
  esac
done
[[ -s "$config" && "$config" == "$DATA_DIR/acme/sites/"*/config ]]
base="$(dirname "$config")"
grep -Fq 'CONTACT_EMAIL=' "$config"
if [[ "$mode" == register ]]; then
  mkdir -p "$base/accounts/fake"
  printf 'registered\n' > "$base/accounts/fake/registration"
elif [[ "$mode" == cron ]]; then
  [[ -d "$base/accounts/fake" && -n "$cert_alias" ]]
  mkdir -p "$DATA_DIR/acme/certs/$cert_alias"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$DATA_DIR/acme/certs/$cert_alias/privkey.pem" -out "$DATA_DIR/acme/certs/$cert_alias/fullchain.pem" -subj "/CN=$cert_alias" >/dev/null 2>&1
else
  exit 1
fi
printf '%s %s\n' "$mode" "$config" >> "$DATA_DIR/mock-acme-calls.log"
MOCK_ACME
chmod +x "$TMP/testbin/dehydrated"
# The final install/reload is simulated: test only reads and writes temporary data.
cat > "$TMP/testbin/render-nginx.sh" <<'MOCK_RENDER'
#!/bin/sh
exit 0
MOCK_RENDER
chmod +x "$TMP/testbin/render-nginx.sh"
# Intercept absolute helper paths in the isolated test script.
sed -i 's@/opt/liteedge/bin/render-nginx.sh@"$ACME_TEST_RENDER"@g; s@reload_nginx$@true@g' "$TMP/testbin/certctl.sh"
export PATH="$TMP/testbin:$PATH" ACME_TEST_RENDER="$TMP/testbin/render-nginx.sh"
"$TMP/testbin/certctl.sh" letsencrypt one.example one@example.org >/dev/null
"$TMP/testbin/certctl.sh" letsencrypt two.example two@example.net >/dev/null
[[ "$(grep -c '^register ' "$TMP/data/mock-acme-calls.log")" == 2 ]]
[[ "$(grep -c '^cron ' "$TMP/data/mock-acme-calls.log")" == 2 ]]
[[ "$(grep -c '/acme/sites/one.example/config$' "$TMP/data/mock-acme-calls.log")" == 2 ]]
[[ "$(grep -c '/acme/sites/two.example/config$' "$TMP/data/mock-acme-calls.log")" == 2 ]]
# Reusing an existing registration never refers to a nonexistent global config.
"$TMP/testbin/certctl.sh" letsencrypt one.example one@example.org >/dev/null
[[ "$(grep -c '^register ' "$TMP/data/mock-acme-calls.log")" == 2 ]]
[[ "$(grep -c '^cron ' "$TMP/data/mock-acme-calls.log")" == 3 ]]
# Failed earlier issuance may have registered an ACME account before saving
# the per-site email; a retry without resubmitting it must still work.
rm -f "$TMP/data/certs/one.example/acme-email"
"$TMP/testbin/certctl.sh" letsencrypt one.example >/dev/null
[[ "$(grep -c '^register ' "$TMP/data/mock-acme-calls.log")" == 2 ]]
[[ "$(grep -c '^cron ' "$TMP/data/mock-acme-calls.log")" == 4 ]]


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