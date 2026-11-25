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

# Restore interrupted provider transactions before rendering or starting NGINX.
python3 /opt/liteedge/bin/providerctl.py recover

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

if [[ -n "${LITEEDGE_HA_DIR:-}" ]]; then
  python3 /opt/liteedge/bin/ha_config.py startup
else
  /opt/liteedge/bin/render-runtime.sh
  /opt/liteedge/bin/render-nginx.sh
fi
# Publish a fully validated generation before the first master start.
python3 /opt/liteedge/bin/nginx_reload.py startup /opt/liteedge/sbin/nginx "$DATA_DIR/nginx/nginx.conf"
# Continuous normalization/export and alert delivery; never blocks the proxy process.
/opt/liteedge/bin/obs-worker.sh run >>"$DATA_DIR/logs/observability-worker.log" 2>&1 &
/opt/liteedge/bin/health-worker.sh run >>"$DATA_DIR/logs/health-worker.log" 2>&1 &

rm -f "$RUN_DIR/fcgiwrap.sock" "$RUN_DIR/reload-ack.sock" "$RUN_DIR/deadline.sock" "$RUN_DIR/grpc-invalid.sock"
# Only deadline-enabled routes depend on this local worker; ordinary NGINX
# routes remain available if it fails. Supervise it independently.
deadline_parent="$$"
deadline_parent_start="$(awk '{print $22}' "/proc/$deadline_parent/stat")"
(
  while [[ "$(awk '{print $22}' "/proc/$deadline_parent/stat" 2>/dev/null || true)" == "$deadline_parent_start" ]]; do
    /opt/liteedge/bin/deadline-proxy "$RUN_DIR/deadline.sock" "$deadline_parent" || true
    sleep 1
  done
) >>"$DATA_DIR/logs/deadline-worker.log" 2>&1 &
# A slow or failed optional worker must not prevent unrelated sites starting.
for ((i=0;i<20;i++));do [[ -S "$RUN_DIR/deadline.sock" ]] && break;sleep .1;done
spawn-fcgi -s "$RUN_DIR/fcgiwrap.sock" -M 600 -- /usr/bin/fcgiwrap
chmod 600 "$RUN_DIR/fcgiwrap.sock"

if [[ -n "${LITEEDGE_HA_DIR:-}" ]]; then
  python3 /opt/liteedge/bin/ha_config.py watch >>"$DATA_DIR/logs/ha-worker.log" 2>&1 &
fi
(
  sleep 60
  while :; do
    /opt/liteedge/bin/renew-certs.sh >>"$DATA_DIR/logs/acme-renew.log" 2>&1 || true
    sleep 43200
  done
) &

exec /opt/liteedge/sbin/nginx -c "$DATA_DIR/.liteedge-nginx-generations/active.conf" -g 'daemon off;'
