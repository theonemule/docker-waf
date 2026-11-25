#!/usr/bin/env bash
set -euo pipefail
if [[ "${LITEEDGE_CONFIG_LOCK_HELD:-0}" != 1 ]]; then
  exec python3 /opt/liteedge/bin/configlock.py "$0" "$@"
fi
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

cmd="${1:-}"
host="${2:-}"
[[ -n "$cmd" && -n "$host" ]] || die "Usage: certctl.sh selfsigned|import|letsencrypt HOST [args]"
validate_host "$host"
assert_manual_site "$host"

site="$(site_file "$host")"
[[ -f "$site" ]] || die "Unknown site: $host"

aliases="$(kv_get "$site" ALIASES)"
validate_aliases "$aliases"
cdir="$(cert_dir "$host")"
mkdir -p "$cdir"

install_and_reload() {
  /opt/liteedge/bin/render-nginx.sh
  reload_nginx
}

# Persist contact email per certificate/site, not as a single global value.
validate_acme_email() {
  local email="$1"
  [[ ${#email} -le 254 && "$email" =~ ^[A-Za-z0-9_%+.-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] ||
    die "Enter a valid contact email for this site's Let's Encrypt certificate."
}
effective_acme_email() {
  local saved="" registered
  registered="$ACME_DIR/sites/$(slug_for_host "$host")/registered-email"
  [[ -s "$cdir/acme-email" ]] && saved="$(head -n1 "$cdir/acme-email")"
  [[ -n "$saved" || ! -s "$registered" ]] || saved="$(head -n1 "$registered")"
  printf '%s' "${saved:-${ACME_EMAIL:-}}"
}
save_acme_email() {
  local chosen="$1" temp
  validate_acme_email "$chosen"
  temp="$(mktemp "$cdir/.acme-email.XXXXXX")"
  chmod 0600 "$temp"
  printf '%s\n' "$chosen" > "$temp"
  mv -f "$temp" "$cdir/acme-email"
}

certificate_covers_site() {
  local cert="$1" name result
  for name in "$host" $aliases; do
    result="$(openssl x509 -in "$cert" -noout -checkhost "$name" 2>/dev/null)" || return 1
    [[ "$result" == *"does match certificate"* ]] || return 1
  done
}

validate_certificate_pair() {
  local cert="$1" key="$2" cert_pub key_pub
  certificate_covers_site "$cert" || die "Certificate does not cover the site and aliases."
  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)" || die "Invalid certificate."
  key_pub="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)" || die "Invalid private key."
  [[ "$cert_pub" == "$key_pub" ]] || die "Certificate and private key do not match."
}

case "$cmd" in
  set-email)
    save_acme_email "${3:-}"
    ;;

  selfsigned)
    san="DNS:$host"
    for alias in $aliases; do
      san="$san,DNS:$alias"
    done

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
      -keyout "$tmp/privkey.pem" \
      -out "$tmp/fullchain.pem" \
      -subj "/CN=$host" \
      -addext "subjectAltName=$san" >/dev/null 2>&1

    install -m 600 "$tmp/privkey.pem" "$cdir/privkey.pem"
    install -m 644 "$tmp/fullchain.pem" "$cdir/fullchain.pem"
    printf '%s\n' selfsigned > "$cdir/mode"
    printf '%s %s\n' "$host" "$aliases" > "$cdir/domains"
    install_and_reload
    ;;

  import)
    cert_source="${3:-}"
    key_source="${4:-}"
    [[ -s "$cert_source" && -s "$key_source" ]] || die "Certificate and key files are required."

    openssl x509 -in "$cert_source" -noout >/dev/null 2>&1 || die "Invalid X.509 certificate."
    openssl pkey -in "$key_source" -noout >/dev/null 2>&1 || die "Invalid private key."

    validate_certificate_pair "$cert_source" "$key_source"

    install -m 644 "$cert_source" "$cdir/fullchain.pem"
    install -m 600 "$key_source" "$cdir/privkey.pem"
    printf '%s\n' imported > "$cdir/mode"
    printf '%s %s\n' "$host" "$aliases" > "$cdir/domains"
    install_and_reload
    ;;

  letsencrypt|renew)
    if [[ "$cmd" == renew ]]; then
      # Checked under the shared writer lock, after synchronizing the source.
      [[ "$(cat "$cdir/mode" 2>/dev/null || true)" == letsencrypt ]] || exit 0
      if [[ -s "$cdir/fullchain.pem" ]] && openssl x509 -in "$cdir/fullchain.pem" -noout -checkend 2592000 >/dev/null 2>&1 && certificate_covers_site "$cdir/fullchain.pem"; then
        exit 0
      fi
    fi
    email="${3:-}"
    [[ -n "$email" ]] || email="$(effective_acme_email)"
    [[ -n "$email" ]] || die "Set a Let's Encrypt contact email in this site's TLS certificate settings."
    validate_acme_email "$email"

    slug="$(slug_for_host "$host")"
    # Independent account keys and registration for each site.
    account_base="$ACME_DIR/sites/$slug"
    config="$account_base/config"
    mkdir -p "$account_base" "$ACME_DIR/certs" "$ACME_DIR/challenges/.well-known/acme-challenge"
    chmod 0700 "$account_base"
    cat > "$config" <<CFG
CA="letsencrypt"
BASEDIR="$account_base"
ACCOUNTDIR="$account_base/accounts"
CERTDIR="$ACME_DIR/certs"
WELLKNOWN="$ACME_DIR/challenges/.well-known/acme-challenge"
CONTACT_EMAIL="$email"
CHALLENGETYPE="http-01"
CFG
    chmod 0600 "$config"

    # If contact changes, preserve old account rather than claiming that
    # a new email has automatically changed an existing ACME registration.
    if [[ -f "$account_base/registered-email" && "$(cat "$account_base/registered-email")" != "$email" ]]; then
      if [[ -d "$account_base/accounts" ]]; then
        mv "$account_base/accounts" "$account_base/accounts-$(date +%s).previous"
      fi
      rm -f "$account_base/registered-email"
    fi
    if [[ ! -f "$account_base/registered-email" ]]; then
      dehydrated --register --accept-terms --config "$config"
      printf '%s\n' "$email" > "$account_base/registered-email"
      chmod 0600 "$account_base/registered-email"
    fi

    args=(--cron --config "$config" --alias "$(slug_for_host "$host")" --domain "$host")
    for alias in $aliases; do
      args+=(--domain "$alias")
    done
    dehydrated "${args[@]}"

    acme_cert="$ACME_DIR/certs/$(slug_for_host "$host")/fullchain.pem"
    acme_key="$ACME_DIR/certs/$(slug_for_host "$host")/privkey.pem"
    [[ -s "$acme_cert" && -s "$acme_key" ]] || die "ACME client did not produce the expected certificate files."

    validate_certificate_pair "$acme_cert" "$acme_key"
    install -m 644 "$acme_cert" "$cdir/fullchain.pem"
    install -m 600 "$acme_key" "$cdir/privkey.pem"
    printf '%s\n' letsencrypt > "$cdir/mode"
    printf '%s %s\n' "$host" "$aliases" > "$cdir/domains"
    save_acme_email "$email"
    install_and_reload
    ;;

  *)
    die "Unknown certificate action: $cmd"
    ;;
esac