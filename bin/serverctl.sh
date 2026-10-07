#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

cmd="${1:-}"
shift || true

write_defaults() {
  cat <<'EOF'
WORKER_CONNECTIONS=1024
KEEPALIVE_TIMEOUT=65
CLIENT_HEADER_TIMEOUT=15
CLIENT_BODY_TIMEOUT=15
SEND_TIMEOUT=30
DEFAULT_ROUTE_TIMEOUT=60
RESOLVER=
EOF
}

ensure_settings() {
  [[ -f "$SERVER_SETTINGS_FILE" ]] || write_defaults > "$SERVER_SETTINGS_FILE"
}

validate_number() {
  local name="$1" value="$2" min="$3" max="$4"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be numeric."
  (( 10#$value >= min && 10#$value <= max )) || die "$name must be between $min and $max."
}

apply_settings() {
  /opt/liteedge/bin/render-runtime.sh
  /opt/liteedge/bin/render-nginx.sh
  "$NGINX_BIN" -t -c "$NGINX_CONF"
  reload_nginx
}

case "$cmd" in
  show)
    ensure_settings
    cat "$SERVER_SETTINGS_FILE"
    ;;
  save)
    worker="${1:-}"
    keepalive="${2:-}"
    header_timeout="${3:-}"
    body_timeout="${4:-}"
    send_timeout="${5:-}"
    route_timeout="${6:-}"
    resolver="${7:-}"

    validate_number "Worker connections" "$worker" 128 65535
    validate_number "Keepalive timeout" "$keepalive" 1 3600
    validate_number "Client header timeout" "$header_timeout" 1 3600
    validate_number "Client body timeout" "$body_timeout" 1 3600
    validate_number "Send timeout" "$send_timeout" 1 3600
    validate_timeout "$route_timeout"
    if [[ -n "$resolver" && ! "$resolver" =~ ^[A-Fa-f0-9:.]+$ ]]; then
      die "Resolver must be a valid IPv4 or IPv6 address, or blank for automatic detection."
    fi

    backup="$(mktemp)"
    existed=0
    if [[ -f "$SERVER_SETTINGS_FILE" ]]; then
      cp "$SERVER_SETTINGS_FILE" "$backup"
      existed=1
    fi
    trap 'rm -f "$backup"' EXIT

    cat > "$SERVER_SETTINGS_FILE" <<EOF
WORKER_CONNECTIONS=$worker
KEEPALIVE_TIMEOUT=$keepalive
CLIENT_HEADER_TIMEOUT=$header_timeout
CLIENT_BODY_TIMEOUT=$body_timeout
SEND_TIMEOUT=$send_timeout
DEFAULT_ROUTE_TIMEOUT=$route_timeout
RESOLVER=$resolver
EOF

    if ! apply_settings; then
      if [[ "$existed" == 1 ]]; then
        cp "$backup" "$SERVER_SETTINGS_FILE"
      else
        rm -f "$SERVER_SETTINGS_FILE"
      fi
      /opt/liteedge/bin/render-runtime.sh >/dev/null 2>&1 || true
      /opt/liteedge/bin/render-nginx.sh >/dev/null 2>&1 || true
      reload_nginx >/dev/null 2>&1 || true
      die "Server settings were rejected. Previous settings were restored."
    fi

    rm -f "$backup"
    trap - EXIT
    ;;
  *)
    echo "Usage: serverctl.sh show | save WORKER_CONNECTIONS KEEPALIVE HEADER_TIMEOUT BODY_TIMEOUT SEND_TIMEOUT DEFAULT_ROUTE_TIMEOUT RESOLVER" >&2
    exit 2
    ;;
esac
