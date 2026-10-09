#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

HTTP_PORT="${LITEEDGE_HTTP_PORT:-80}"
HTTPS_PORT="${LITEEDGE_HTTPS_PORT:-443}"
ADMIN_HTTPS_PORT="${LITEEDGE_ADMIN_HTTPS_PORT:-9443}"
PUBLIC_HTTP_PORT="${LITEEDGE_PUBLIC_HTTP_PORT:-80}"
BIND_ADDRESS="${LITEEDGE_BIND_ADDRESS:-0.0.0.0}"
PUBLIC_HTTPS_PORT="${LITEEDGE_PUBLIC_HTTPS_PORT:-443}"
HTTPS_REDIRECT_SUFFIX=""
[[ "$PUBLIC_HTTPS_PORT" == 443 ]] || HTTPS_REDIRECT_SUFFIX=":$PUBLIC_HTTPS_PORT"

valid_bind_address() {
  local value=$1 a b c d extra octet
  IFS=. read -r a b c d extra <<< "$value"
  [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

RUN_DIR="${LITEEDGE_RUN_DIR:-/tmp/liteedge-run}"
RESOLVER="${LITEEDGE_RESOLVER:-}"

WORKER_CONNECTIONS="$(server_setting_get WORKER_CONNECTIONS 1024)"
KEEPALIVE_TIMEOUT="$(server_setting_get KEEPALIVE_TIMEOUT 65)"
CLIENT_HEADER_TIMEOUT="$(server_setting_get CLIENT_HEADER_TIMEOUT 15)"
CLIENT_BODY_TIMEOUT="$(server_setting_get CLIENT_BODY_TIMEOUT 15)"
SEND_TIMEOUT="$(server_setting_get SEND_TIMEOUT 30)"
SETTINGS_RESOLVER="$(server_setting_get RESOLVER "")"
PARANOIA_LEVEL="$(waf_setting_get PARANOIA_LEVEL 1)"

[[ "$HTTP_PORT" =~ ^[0-9]+$ && "$HTTP_PORT" -ge 1 && "$HTTP_PORT" -le 65535 ]] || die "Invalid HTTP port."
[[ "$HTTPS_PORT" =~ ^[0-9]+$ && "$HTTPS_PORT" -ge 1 && "$HTTPS_PORT" -le 65535 ]] || die "Invalid HTTPS port."
[[ "$ADMIN_HTTPS_PORT" =~ ^[0-9]+$ && "$ADMIN_HTTPS_PORT" -ge 1 && "$ADMIN_HTTPS_PORT" -le 65535 ]] || die "Invalid admin port."
[[ "$PUBLIC_HTTP_PORT" =~ ^[0-9]+$ && "$PUBLIC_HTTP_PORT" -ge 1 && "$PUBLIC_HTTP_PORT" -le 65535 ]] || die "Invalid public HTTP port."
[[ "$HTTP_PORT" != "$HTTPS_PORT" && "$ADMIN_HTTPS_PORT" != "$HTTP_PORT" && "$ADMIN_HTTPS_PORT" != "$HTTPS_PORT" ]] || die "Listener ports must be distinct."
[[ "$PUBLIC_HTTPS_PORT" =~ ^[0-9]+$ && "$PUBLIC_HTTPS_PORT" -ge 1 && "$PUBLIC_HTTPS_PORT" -le 65535 ]] || die "Invalid public HTTPS port."
valid_bind_address "$BIND_ADDRESS" || die "Invalid bind address."
[[ "$RUN_DIR" == /* && "$RUN_DIR" != *$'\n'* ]] || die "Invalid runtime directory."

if [[ -n "$SETTINGS_RESOLVER" ]]; then
  RESOLVER="$SETTINGS_RESOLVER"
elif [[ -z "$RESOLVER" ]]; then
  RESOLVER="$(awk '/^nameserver[[:space:]]+/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
fi
[[ -n "$RESOLVER" && "$RESOLVER" =~ ^[A-Fa-f0-9:.]+$ ]] || RESOLVER="1.1.1.1"

for value in "$WORKER_CONNECTIONS" "$KEEPALIVE_TIMEOUT" "$CLIENT_HEADER_TIMEOUT" "$CLIENT_BODY_TIMEOUT" "$SEND_TIMEOUT"; do
  [[ "$value" =~ ^[0-9]+$ ]] || die "Invalid numeric server setting."
done
[[ "$PARANOIA_LEVEL" =~ ^[1-4]$ ]] || die "Invalid OWASP CRS protection level."

mkdir -p "$NGINX_DIR" "$NGINX_SITE_DIR" "$RUN_DIR" "$RUN_DIR/client_temp" "$RUN_DIR/proxy_temp" "$RUN_DIR/fastcgi_temp" "$RUN_DIR/uwsgi_temp" "$RUN_DIR/scgi_temp"
chmod 700 "$RUN_DIR"

escape_sed() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

replace_file() {
  local target="$1" tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  cat > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$target"
}


data_esc="$(escape_sed "$DATA_DIR")"
run_esc="$(escape_sed "$RUN_DIR")"
resolver_esc="$(escape_sed "$RESOLVER")"
bind_esc="$(escape_sed "$BIND_ADDRESS")"
redirect_suffix_esc="$(escape_sed "$HTTPS_REDIRECT_SUFFIX")"

sed \
  -e "s|@DATA_DIR@|$data_esc|g" \
  -e "s|@RUN_DIR@|$run_esc|g" \
  -e "s|@HTTP_PORT@|$HTTP_PORT|g" \
  -e "s|@HTTPS_PORT@|$HTTPS_PORT|g" \
  -e "s|@ADMIN_HTTPS_PORT@|$ADMIN_HTTPS_PORT|g" \
  -e "s|@PUBLIC_HTTP_PORT@|$PUBLIC_HTTP_PORT|g" \
  -e "s|@PUBLIC_HTTPS_PORT@|$PUBLIC_HTTPS_PORT|g" \
  -e "s|@RESOLVER@|$resolver_esc|g" \
  -e "s|@WORKER_CONNECTIONS@|$WORKER_CONNECTIONS|g" \
  -e "s|@KEEPALIVE_TIMEOUT@|$KEEPALIVE_TIMEOUT|g" \
  -e "s|@CLIENT_HEADER_TIMEOUT@|$CLIENT_HEADER_TIMEOUT|g" \
  -e "s|@CLIENT_BODY_TIMEOUT@|$CLIENT_BODY_TIMEOUT|g" \
  -e "s|@SEND_TIMEOUT@|$SEND_TIMEOUT|g" \
  /opt/liteedge/etc/nginx/nginx.conf | replace_file "$NGINX_CONF"

# Imported NGINX vhosts rely on shared maps and rate-limit zones.
# Regenerate the optional include on *every* config update, including CRS.
if [[ -s "$DATA_DIR/migration/maps.conf" ]]; then
  map_file="$DATA_DIR/migration/maps.conf"
  sed -i "/^[[:space:]]*include .*\/nginx\/admin\.conf;$/i\    include $map_file;" "$NGINX_CONF"
fi

admin_template=/opt/liteedge/etc/nginx/admin.conf.template
if [[ "${LITEEDGE_ADMIN_HTTP_ONLY:-0}" == 1 ]]; then
  admin_template=/opt/liteedge/etc/nginx/admin-http.conf.template
fi

sed \
  -e "s|@DATA_DIR@|$data_esc|g" \
  -e "s|@RUN_DIR@|$run_esc|g" \
  -e "s|@HTTP_PORT@|$HTTP_PORT|g" \
  -e "s|@HTTPS_PORT@|$HTTPS_PORT|g" \
  -e "s|@ADMIN_HTTPS_PORT@|$ADMIN_HTTPS_PORT|g" \
  -e "s|@BIND_ADDRESS@|$bind_esc|g" \
  -e "s|@HTTPS_REDIRECT_SUFFIX@|$redirect_suffix_esc|g" \
  "$admin_template" | replace_file "$NGINX_DIR/admin.conf"

# ModSecurity's writable paths and include root are runtime-specific too.
sed \
  -e "s|@DATA_DIR@|$data_esc|g" \
  -e "s|@RUN_DIR@|$run_esc|g" \
  /opt/liteedge/etc/modsecurity/modsecurity.conf.template | replace_file "$NGINX_DIR/modsecurity.conf"
# Keep ModSecurity JSON auditing active with prebuilt or freshly compiled runtimes.
# Raw audit data stays private; normalized UI events never include request bodies.
sed -i -e "s|^SecAuditLog .*|SecAuditLog $DATA_DIR/logs/modsec_audit.json|" "$NGINX_DIR/modsecurity.conf"
cat <<'CONF' >> "$NGINX_DIR/modsecurity.conf"
SecAuditLogFormat JSON
SecAuditLogType Serial
SecAuditLogParts AFHZ
SecAuditEngine RelevantOnly
CONF

# Override the CRS paranoia level after crs-setup.conf and before CRS rules load.
cat <<EOF | replace_file "$NGINX_DIR/modsecurity-pre.conf"
SecAction "id:1999999,phase:1,nolog,pass,setvar:tx.paranoia_level=$PARANOIA_LEVEL,setvar:tx.executing_paranoia_level=$PARANOIA_LEVEL"
EOF

# Build one runtime ModSecurity overlay from managed custom rules and global rule disables.
overrides_tmp="$(mktemp "$NGINX_DIR/.modsecurity-overrides.XXXXXX")"
: > "$overrides_tmp"
shopt -s nullglob
for rule_file in "$WAF_CUSTOM_DIR"/*.conf; do
  cat "$rule_file" >> "$overrides_tmp"
  printf '\n' >> "$overrides_tmp"
done
while IFS= read -r rule_id; do
  [[ -n "$rule_id" ]] || continue
  printf 'SecRuleRemoveById %s\n' "$rule_id" >> "$overrides_tmp"
done < <(global_disabled_waf_rules)
chmod 0644 "$overrides_tmp"
mv -f "$overrides_tmp" "$NGINX_DIR/modsecurity-overrides.conf"

nginx_dir_esc="$(escape_sed "$NGINX_DIR")"
crs_dir_esc="$(escape_sed "$(active_crs_dir)")"
sed -e "s|@NGINX_DIR@|$nginx_dir_esc|g" -e "s|@CRS_DIR@|$crs_dir_esc|g" \
  /opt/liteedge/etc/nginx/modsecurity-main.conf.template | replace_file "$NGINX_DIR/modsecurity-main.conf"
sed -e "s|@NGINX_DIR@|$nginx_dir_esc|g" -e "s|@CRS_DIR@|$crs_dir_esc|g" \
  /opt/liteedge/etc/nginx/modsecurity-wordpress.conf.template | replace_file "$NGINX_DIR/modsecurity-wordpress.conf"
