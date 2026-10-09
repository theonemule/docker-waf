#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

mkdir -p "$NGINX_DIR" "$NGINX_BASELINE_DIR" "$NGINX_DIFF_DIR" "$NGINX_CONFLICT_DIR"
stage="$(mktemp -d "$NGINX_DIR/sites.stage.XXXXXX")"
baseline_stage="$(mktemp -d "$NGINX_DIR/baselines.stage.XXXXXX")"
diff_stage="$(mktemp -d "$NGINX_DIR/diffs.stage.XXXXXX")"
WAF_ROUTE_DIR="$NGINX_DIR/waf-routes"
waf_route_stage="$(mktemp -d "$NGINX_DIR/waf-routes.stage.XXXXXX")"
trap 'rm -rf "$stage" "$baseline_stage" "$diff_stage" "$waf_route_stage"' EXIT
shopt -s nullglob

HTTP_PORT="${LITEEDGE_HTTP_PORT:-80}"
HTTPS_PORT="${LITEEDGE_HTTPS_PORT:-443}"
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
[[ "$PUBLIC_HTTPS_PORT" =~ ^[0-9]+$ && "$PUBLIC_HTTPS_PORT" -ge 1 && "$PUBLIC_HTTPS_PORT" -le 65535 ]] || die "Invalid public HTTPS port."
valid_bind_address "$BIND_ADDRESS" || die "Invalid bind address."



emit_proxy_headers() {
  cat <<'CONF'
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
CONF
}

emit_websocket_headers() {
  cat <<'CONF'
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
CONF
}

emit_plugin_group() {
  local plugin_csv="$1" suffix="$2" plugin file
  local -a plugin_list=()
  IFS=',' read -r -a plugin_list <<< "$plugin_csv"
  for plugin in "${plugin_list[@]}"; do
    [[ -n "$plugin" ]] || continue
    validate_plugin_name "$plugin"
    [[ -d "$WAF_PLUGIN_DIR/$plugin/plugins" ]] || die "Selected CRS plugin is not installed: $plugin"
    shopt -s nullglob
    for file in "$WAF_PLUGIN_DIR/$plugin/plugins/"*-"$suffix".conf; do
      printf 'Include %s\n' "$file"
    done
  done
}

build_route_waf_config() {
  local host="$1" route_id="$2" pl="$3" plugin_csv="$4" disabled="$5"
  local slug out control_id rule_id item
  local -a route_rules=()

  validate_waf_pl "$pl"
  plugin_csv="$(normalize_plugin_csv "$plugin_csv")"
  disabled="$(normalize_rule_csv "$disabled")"
  slug="$(slug_for_host "$host")"
  out="$waf_route_stage/${slug}-${route_id}.conf"
  control_id=$((80000000 + (16#${route_id:0:6})))

  {
    printf 'Include %s/modsecurity.conf\n' "$NGINX_DIR"
    printf 'Include %s/crs-setup.conf\n' "$(active_crs_dir)"
    printf 'SecAction "id:%s,phase:1,nolog,pass,setvar:tx.paranoia_level=%s,setvar:tx.executing_paranoia_level=%s"\n' "$control_id" "$pl" "$pl"
    emit_plugin_group "$plugin_csv" config
    emit_plugin_group "$plugin_csv" before
    printf 'Include %s/rules/*.conf\n' "$(active_crs_dir)"
    emit_plugin_group "$plugin_csv" after
    printf 'Include %s/modsecurity-overrides.conf\n' "$NGINX_DIR"

    while IFS= read -r rule_id; do
      [[ -n "$rule_id" ]] && printf 'SecRuleRemoveById %s\n' "$rule_id"
    done < <(disabled_waf_rules "$host")

    IFS=',' read -r -a route_rules <<< "$disabled"
    for item in "${route_rules[@]}"; do
      [[ -n "$item" ]] && printf 'SecRuleRemoveById %s\n' "$item"
    done
  } > "$out"
  chmod 0644 "$out"
}

emit_location_waf() {
  local host="$1" route_id="$2" pl="$3" plugin_csv="$4" disabled="$5"
  local slug
  slug="$(slug_for_host "$host")"
  build_route_waf_config "$host" "$route_id" "$pl" "$plugin_csv" "$disabled"
  echo "        modsecurity on;"
  echo "        modsecurity_rules_file $WAF_ROUTE_DIR/${slug}-${route_id}.conf;"
}

route_value() {
  local route="$1" key="$2" fallback="$3" value
  value="$(kv_get "$route" "$key")"
  printf '%s' "${value:-$fallback}"
}

emit_route_values() {
  local host="$1" match="$2" path="$3" target="$4" websocket="$5"
  local timeout="$6" waf="$7" force_https="$8" waf_pl="$9" waf_plugins="${10}" waf_disabled="${11}" scheme="${12}" cert_exists="${13}"
  local location id

  case "$match" in
    exact) location="location = $path" ;;
    regex) location="location ~ $path" ;;
    *) location="location ^~ $path" ;;
  esac

  id="$(printf '%s\n%s\n%s' "$match" "$path" "$target" | sha256sum | cut -c1-16)"
  printf '    %s {\n' "$location"
  printf '        set $liteedge_route "%s";\n' "$match:$path"

  if [[ "$scheme" == http && "$force_https" == 1 && "$cert_exists" == 1 ]]; then
    echo "        return 301 https://\$host$HTTPS_REDIRECT_SUFFIX\$request_uri;"
    echo "    }"
    return 0
  fi

  if [[ "$waf" == 1 ]]; then
    emit_location_waf "$host" "$id" "$waf_pl" "$waf_plugins" "$waf_disabled"
  fi

  printf '        set $liteedge_route_%s "%s";\n' "$id" "$target"
  printf '        proxy_pass $liteedge_route_%s;\n' "$id"
  emit_proxy_headers
  printf '        proxy_connect_timeout %ss;\n' "$timeout"
  printf '        proxy_send_timeout %ss;\n' "$timeout"
  printf '        proxy_read_timeout %ss;\n' "$timeout"
  [[ "$websocket" == 1 ]] && emit_websocket_headers
  echo "    }"
}

emit_route() {
  local host="$1" route="$2" scheme="$3" cert_exists="$4"
  local match path target websocket timeout waf force_https waf_pl waf_plugins waf_disabled legacy_profile
  [[ "$(route_value "$route" ACTION proxy)" == custom ]] && return 0
  match="$(route_value "$route" MATCH prefix)"
  path="$(route_value "$route" PATH /)"
  target="$(route_value "$route" TARGET "")"
  websocket="$(route_value "$route" WEBSOCKET 1)"
  timeout="$(route_value "$route" TIMEOUT "$(server_setting_get DEFAULT_ROUTE_TIMEOUT 60)")"
  waf="$(route_value "$route" WAF 1)"
  force_https="$(route_value "$route" FORCE_HTTPS 1)"
  waf_pl="$(route_value "$route" WAF_PL "$(waf_setting_get PARANOIA_LEVEL 1)")"
  waf_plugins="$(route_value "$route" WAF_PLUGINS "")"
  waf_disabled="$(route_value "$route" WAF_DISABLED "")"

  legacy_profile="$(route_value "$route" PROFILE "")"
  if [[ -z "$waf_plugins" && "$legacy_profile" == wordpress && -d "$WAF_PLUGIN_DIR/wordpress-rule-exclusions" ]]; then
    waf_plugins=wordpress-rule-exclusions
  fi

  emit_route_values "$host" "$match" "$path" "$target" "$websocket" "$timeout" "$waf" "$force_https" "$waf_pl" "$waf_plugins" "$waf_disabled" "$scheme" "$cert_exists"
}

has_root_route() {
  local host="$1" route
  for route in "$(route_dir "$host")"/*.route; do
    [[ -e "$route" ]] || continue
    [[ "$(kv_get "$route" PATH)" == / ]] && return 0
  done
  return 1
}

emit_legacy_default() {
  local host="$1" file="$2" scheme="$3" cert_exists="$4"
  local mode upstream websocket waf force_https timeout waf_pl waf_plugins
  mode="$(kv_get "$file" MODE)"
  upstream="$(kv_get "$file" UPSTREAM)"
  [[ "$mode" == proxy || "$mode" == wordpress ]] || return 0
  [[ -n "$upstream" ]] || return 0
  has_root_route "$host" && return 0

  websocket="$(kv_get "$file" WEBSOCKET)"
  waf="$(kv_get "$file" WAF)"
  force_https="$(kv_get "$file" FORCE_HTTPS)"
  [[ "$websocket" =~ ^[01]$ ]] || websocket=1
  [[ "$waf" =~ ^[01]$ ]] || waf=1
  [[ "$force_https" =~ ^[01]$ ]] || force_https=1
  timeout="$(server_setting_get DEFAULT_ROUTE_TIMEOUT 60)"
  waf_pl="$(waf_setting_get PARANOIA_LEVEL 1)"
  waf_plugins=""
  if [[ "$mode" == wordpress && -d "$WAF_PLUGIN_DIR/wordpress-rule-exclusions" ]]; then
    waf_plugins=wordpress-rule-exclusions
  fi

  emit_route_values "$host" prefix / "$upstream" "$websocket" "$timeout" "$waf" "$force_https" "$waf_pl" "$waf_plugins" "" "$scheme" "$cert_exists"
}

emit_routes() {
  local host="$1" file="$2" scheme="$3" cert_exists="$4" route
  for route in "$(route_dir "$host")"/*.route; do
    [[ -e "$route" ]] || continue
    emit_route "$host" "$route" "$scheme" "$cert_exists"
  done
  emit_legacy_default "$host" "$file" "$scheme" "$cert_exists"
}

merge_manual_delta() {
  local host="$1" generated="$2" output="$3"
  local current baseline conflict delta merged
  current="$(site_nginx_file "$host")"
  baseline="$(site_nginx_baseline "$host")"
  conflict="$(site_nginx_conflict "$host")"
  rm -f "$conflict"

  if [[ -s "$baseline" && -s "$current" ]] && ! cmp -s "$baseline" "$current"; then
    command -v patch >/dev/null 2>&1 ||
      die "Manual NGINX edits exist for $host, but patch is unavailable. Install the Alpine patch package before regenerating this site."

    delta="$(mktemp)"
    merged="$(mktemp)"
    diff -U0 --label "generated baseline" --label "effective config" "$baseline" "$current" > "$delta" || true

    if command -v diff3 >/dev/null 2>&1 && diff3 -m "$current" "$baseline" "$generated" > "$merged"; then
      mv "$merged" "$output"
    else
      cp "$generated" "$output"
      if ! patch --batch --silent --fuzz=0 "$output" < "$delta"; then
        if [[ -s "$merged" ]]; then
          cp "$merged" "$conflict"
        else
          cp "$output" "$conflict"
        fi
        rm -f "$delta" "$merged"
        die "Manual NGINX edits for $host conflict with newly generated settings. Resolve the conflict from Advanced NGINX before retrying."
      fi
      rm -f "$merged"
    fi
    rm -f "$delta"
  elif [[ -s "$current" && ! -s "$baseline" ]]; then
    cp "$current" "$output"
  else
    cp "$generated" "$output"
  fi
}

record_generated_diff() {
  local host="$1" generated="$2" baseline diff_out
  baseline="$(site_nginx_baseline "$host")"
  diff_out="$diff_stage/$(slug_for_host "$host").diff"

  if [[ -s "$baseline" ]] && ! cmp -s "$baseline" "$generated"; then
    diff -u --label "previous generated" --label "new generated" "$baseline" "$generated" > "$diff_out" || true
  elif [[ -s "$(site_nginx_diff "$host")" ]]; then
    cp "$(site_nginx_diff "$host")" "$diff_out"
  fi
}

for file in "$SITE_DIR"/*.site; do
  host="$(kv_get "$file" HOST)"
  aliases="$(kv_get "$file" ALIASES)"
  slug="$(slug_for_host "$host")"
  out="$stage/$slug.conf"
  generated="$baseline_stage/$slug.conf"
  cdir="$(cert_dir "$host")"
  cert="$cdir/fullchain.pem"
  key="$cdir/privkey.pem"
  cert_exists=0
  [[ -s "$cert" && -s "$key" ]] && cert_exists=1

  {
    echo "server {"
    echo "    listen $BIND_ADDRESS:$HTTP_PORT;"
    echo "    server_name $host $aliases;"
    echo "    include /opt/liteedge/etc/nginx/security.conf;"
    cat <<CONF
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_DIR/challenges;
        auth_basic off;
        try_files \$uri =404;
    }
CONF
    emit_routes "$host" "$file" http "$cert_exists"
    echo "}"

    if [[ "$cert_exists" == 1 ]]; then
      echo
      echo "server {"
      echo "    listen $BIND_ADDRESS:$HTTPS_PORT ssl;"
      echo "    http2 on;"
      echo "    server_name $host $aliases;"
      echo "    ssl_certificate $cert;"
      echo "    ssl_certificate_key $key;"
      echo "    ssl_protocols TLSv1.2 TLSv1.3;"
      echo "    ssl_session_cache shared:SSL:10m;"
      echo "    ssl_session_timeout 10m;"
      echo "    ssl_session_tickets off;"
      echo '    add_header Strict-Transport-Security "max-age=31536000" always;'
      echo "    include /opt/liteedge/etc/nginx/security.conf;"
      emit_routes "$host" "$file" https "$cert_exists"
      echo "}"
    fi
  } > "$generated"

  # Imported sites use native server directives plus managed route records.
  # The preserved template is authoritative, not a second opaque conf overlay.
  if [[ -s "$DATA_DIR/imported/sites/$slug/template.conf" ]]; then
    /opt/liteedge/bin/render-imported.sh "$host" "$generated"
  fi

  record_generated_diff "$host" "$generated"
  merge_manual_delta "$host" "$generated" "$out"
done

backup="${NGINX_SITE_DIR}.backup"
waf_backup="${WAF_ROUTE_DIR}.backup"
rm -rf "$backup" "$waf_backup"
if [[ -d "$NGINX_SITE_DIR" ]]; then
  mv "$NGINX_SITE_DIR" "$backup"
fi
if [[ -d "$WAF_ROUTE_DIR" ]]; then
  mv "$WAF_ROUTE_DIR" "$waf_backup"
fi
mv "$stage" "$NGINX_SITE_DIR"
mv "$waf_route_stage" "$WAF_ROUTE_DIR"

if [[ "${SKIP_NGINX_TEST:-0}" != 1 ]] && ! "$NGINX_BIN" -t -c "$NGINX_CONF"; then
  rm -rf "$NGINX_SITE_DIR" "$WAF_ROUTE_DIR"
  [[ -d "$backup" ]] && mv "$backup" "$NGINX_SITE_DIR"
  [[ -d "$waf_backup" ]] && mv "$waf_backup" "$WAF_ROUTE_DIR"
  echo "Generated NGINX configuration failed validation; previous configuration restored." >&2
  exit 1
fi

rm -rf "$backup" "$waf_backup"

baseline_backup="${NGINX_BASELINE_DIR}.backup"
diff_backup="${NGINX_DIFF_DIR}.backup"
rm -rf "$baseline_backup" "$diff_backup"
[[ -d "$NGINX_BASELINE_DIR" ]] && mv "$NGINX_BASELINE_DIR" "$baseline_backup"
[[ -d "$NGINX_DIFF_DIR" ]] && mv "$NGINX_DIFF_DIR" "$diff_backup"
mv "$baseline_stage" "$NGINX_BASELINE_DIR"
mv "$diff_stage" "$NGINX_DIFF_DIR"
rm -rf "$baseline_backup" "$diff_backup"
trap - EXIT
