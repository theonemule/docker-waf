#!/usr/bin/env bash
set -euo pipefail
umask 027

export PATH="/opt/liteedge/bin:/opt/liteedge/sbin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export LD_LIBRARY_PATH="/opt/liteedge/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

DATA_DIR="${DATA_DIR:-/data}"
export DATA_DIR
RUN_DIR="${LITEEDGE_RUN_DIR:-/tmp/liteedge-run}"
export LITEEDGE_RUN_DIR="$RUN_DIR"

mkdir -p \
  "$DATA_DIR/sites" \
  "$DATA_DIR/certs" \
  "$DATA_DIR/auth" \
  "$DATA_DIR/acme/challenges/.well-known/acme-challenge" \
  "$DATA_DIR/acme/certs" \
  "$DATA_DIR/logs" \
  "$DATA_DIR/www" \
  "$DATA_DIR/nginx/sites" \
  "$RUN_DIR"

[[ -w "$DATA_DIR" ]] || {
  echo "LiteEdge data directory is not writable by uid $(id -u): $DATA_DIR" >&2
  exit 1
}

chmod 750 "$DATA_DIR/auth"
chmod 755 "$DATA_DIR/www"
chmod 700 "$RUN_DIR"

ADMIN_USER="${ADMIN_USER:-admin}"

if [[ ! -s "$DATA_DIR/auth/.htpasswd" ]]; then
  [[ -n "${ADMIN_PASSWORD:-}" ]] || {
    echo "ADMIN_PASSWORD is required on first start." >&2
    exit 1
  }
  password_hash="$(openssl passwd -6 "$ADMIN_PASSWORD")"
  printf '%s:%s\n' "$ADMIN_USER" "$password_hash" > "$DATA_DIR/auth/.htpasswd"
  chmod 600 "$DATA_DIR/auth/.htpasswd"
fi

if [[ ! -s "$DATA_DIR/certs/_admin/fullchain.pem" || ! -s "$DATA_DIR/certs/_admin/privkey.pem" ]]; then
  mkdir -p "$DATA_DIR/certs/_admin"
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "$DATA_DIR/certs/_admin/privkey.pem" \
    -out "$DATA_DIR/certs/_admin/fullchain.pem" \
    -subj "/CN=liteedge.local" >/dev/null 2>&1
  chmod 600 "$DATA_DIR/certs/_admin/privkey.pem"
  chmod 644 "$DATA_DIR/certs/_admin/fullchain.pem"
fi

/opt/liteedge/bin/render-runtime.sh
/opt/liteedge/bin/render-nginx.sh

rm -f "$RUN_DIR/fcgiwrap.sock"
spawn-fcgi -s "$RUN_DIR/fcgiwrap.sock" -M 600 -- /usr/bin/fcgiwrap
chmod 600 "$RUN_DIR/fcgiwrap.sock"

(
  sleep 60
  while :; do
    /opt/liteedge/bin/renew-certs.sh >>"$DATA_DIR/logs/acme-renew.log" 2>&1 || true
    sleep 43200
  done
) &

exec /opt/liteedge/sbin/nginx -c "$DATA_DIR/nginx/nginx.conf" -g 'daemon off;'
