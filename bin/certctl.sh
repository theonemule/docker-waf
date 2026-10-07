#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

cmd="${1:-}"
host="${2:-}"
[[ -n "$cmd" && -n "$host" ]] || die "Usage: certctl.sh selfsigned|import|letsencrypt HOST [args]"
validate_host "$host"

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

case "$cmd" in
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

    cert_pub="$(openssl x509 -in "$cert_source" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
    key_pub="$(openssl pkey -in "$key_source" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "$cert_pub" == "$key_pub" ]] || die "Certificate and private key do not match."

    openssl x509 -in "$cert_source" -noout -checkhost "$host" >/dev/null 2>&1 ||
      die "Certificate does not cover $host."
    for alias in $aliases; do
      openssl x509 -in "$cert_source" -noout -checkhost "$alias" >/dev/null 2>&1 ||
        die "Certificate does not cover alias $alias."
    done

    install -m 644 "$cert_source" "$cdir/fullchain.pem"
    install -m 600 "$key_source" "$cdir/privkey.pem"
    printf '%s\n' imported > "$cdir/mode"
    printf '%s %s\n' "$host" "$aliases" > "$cdir/domains"
    install_and_reload
    ;;

  letsencrypt)
    [[ -n "${ACME_EMAIL:-}" ]] || die "ACME_EMAIL must be set in .env before issuing Let's Encrypt certificates."

    cat > "$ACME_DIR/config" <<CFG
CA="letsencrypt"
BASEDIR="$ACME_DIR"
WELLKNOWN="$ACME_DIR/challenges/.well-known/acme-challenge"
CERTDIR="$ACME_DIR/certs"
CONTACT_EMAIL="$ACME_EMAIL"
CHALLENGETYPE="http-01"
CFG
    chmod 600 "$ACME_DIR/config"

    if [[ ! -d "$ACME_DIR/accounts" ]]; then
      dehydrated --register --accept-terms --config "$ACME_DIR/config"
    fi

    args=(--cron --config "$ACME_DIR/config" --alias "$(slug_for_host "$host")" --domain "$host")
    for alias in $aliases; do
      args+=(--domain "$alias")
    done
    dehydrated "${args[@]}"

    acme_cert="$ACME_DIR/certs/$(slug_for_host "$host")/fullchain.pem"
    acme_key="$ACME_DIR/certs/$(slug_for_host "$host")/privkey.pem"
    [[ -s "$acme_cert" && -s "$acme_key" ]] || die "ACME client did not produce the expected certificate files."

    install -m 644 "$acme_cert" "$cdir/fullchain.pem"
    install -m 600 "$acme_key" "$cdir/privkey.pem"
    printf '%s\n' letsencrypt > "$cdir/mode"
    printf '%s %s\n' "$host" "$aliases" > "$cdir/domains"
    install_and_reload
    ;;

  *)
    die "Unknown certificate action: $cmd"
    ;;
esac
