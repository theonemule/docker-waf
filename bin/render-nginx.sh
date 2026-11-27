#!/usr/bin/env bash
set -euo pipefail
if [[ "${LITEEDGE_CONFIG_LOCK_HELD:-0}" != 1 ]]; then
  exec python3 /opt/liteedge/bin/configlock.py "$0" "$@"
fi
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh
# shellcheck disable=SC1091
source /opt/liteedge/bin/poolctl.sh
# shellcheck disable=SC1091
source /opt/liteedge/bin/managed-headers.sh

mkdir -p "$NGINX_DIR" "$NGINX_BASELINE_DIR" "$NGINX_DIFF_DIR" "$NGINX_CONFLICT_DIR"
stage="$(mktemp -d "$NGINX_DIR/sites.stage.XXXXXX")"
baseline_stage="$(mktemp -d "$NGINX_DIR/baselines.stage.XXXXXX")"
diff_stage="$(mktemp -d "$NGINX_DIR/diffs.stage.XXXXXX")"
WAF_ROUTE_DIR="$NGINX_DIR/waf-routes"
waf_route_stage="$(mktemp -d "$NGINX_DIR/waf-routes.stage.XXXXXX")"
trap 'rm -rf "$stage" "$baseline_stage" "$diff_stage" "$waf_route_stage"' EXIT
# An upstream is declared in the http context before vhost locations refer to it.
pool_staged="$(mktemp "$NGINX_DIR/.upstreams.XXXXXXXX")"
pool_previous="$(mktemp "$NGINX_DIR/.upstreams.previous.XXXXXXXX")"
zone_staged="$(mktemp "$NGINX_DIR/.route-limits.staged.XXXXXXXX")"
zone_previous="$(mktemp "$NGINX_DIR/.route-limits.previous.XXXXXXXX")"
stream_staged="$(mktemp "$NGINX_DIR/.streams.staged.XXXXXXXX")"
stream_previous="$(mktemp "$NGINX_DIR/.streams.previous.XXXXXXXX")"
stream_existed=0
if [[ -f "$NGINX_DIR/streams.conf" ]];then cp "$NGINX_DIR/streams.conf" "$stream_previous";stream_existed=1;fi
zone_existed=0
if [[ -f "$NGINX_DIR/route-limits.conf" ]]; then
  cp "$NGINX_DIR/route-limits.conf" "$zone_previous"
  zone_existed=1
fi
[[ -f "$NGINX_DIR/upstreams.conf" ]] && cp "$NGINX_DIR/upstreams.conf" "$pool_previous"
pool_render_upstreams "$pool_staged"
emit_managed_header_maps >> "$pool_staged"
python3 /opt/liteedge/bin/managed-dispatch.py "$DATA_DIR" >> "$pool_staged"
cp "$pool_staged" "$NGINX_DIR/upstreams.conf"
cleanup() {
  local code=$?
  if (( code != 0 )); then
    if [[ -s "$pool_previous" ]]; then cp "$pool_previous" "$NGINX_DIR/upstreams.conf"; else rm -f "$NGINX_DIR/upstreams.conf"; fi
    if [[ "$stream_existed" == 1 ]];then cp "$stream_previous" "$NGINX_DIR/streams.conf";else rm -f "$NGINX_DIR/streams.conf";fi
    if [[ "$zone_existed" == 1 ]]; then cp "$zone_previous" "$NGINX_DIR/route-limits.conf"; else rm -f "$NGINX_DIR/route-limits.conf"; fi
  fi
  rm -rf "$stage" "$baseline_stage" "$diff_stage" "$waf_route_stage" "$pool_staged" "$pool_previous" "$zone_staged" "$zone_previous" "$stream_staged" "$stream_previous"
}
trap cleanup EXIT

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
  echo '        proxy_http_version 1.1;'
  if [[ -n "${MANAGED_REWRITE_HOST:-}" ]]; then
    printf '        proxy_set_header Host %s;\n' "$MANAGED_REWRITE_HOST"
  elif [[ -n "${MANAGED_ROUTE_ID:-}" ]]; then
    echo '        proxy_set_header Host $http_host;'
  else
    echo '        proxy_set_header Host $host;'
  fi
  cat <<'CONF'
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $liteedge_external_port;
        proxy_set_header Forwarded "";
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

# Use sharing only where moving the route controls before stock CRS
# initialization is equivalent. Arbitrary plugin/custom rules and operator
# CRS replacements may depend on original order; retain their full ruleset.
can_share_waf() {
  local host="$1" plugins="$2" current baseline
  [[ -z "$(normalize_plugin_csv "$plugins")" ]] || return 1
  [[ "$(active_crs_dir)" == /opt/liteedge/etc/crs ]] || return 1
  local custom
  for custom in "$WAF_CUSTOM_DIR"/*.conf; do [[ ! -f "$custom" ]] || return 1; done
  [[ ! -s "$DATA_DIR/imported/sites/$(slug_for_host "$host")/template.conf" ]] || return 1
  if [[ -z "$(kv_get "$(site_file "$host")" PROVIDER)" ]];then
    current="$(site_nginx_file "$host")";baseline="$(site_nginx_baseline "$host")"
    # Never rewrite a manually edited or opaque site configuration's WAF
    # semantics. Its legacy route file remains available.
    if [[ -s "$current" && ! -s "$baseline" ]];then return 1;fi
    if [[ -s "$current" && -s "$baseline" ]] && ! cmp -s "$current" "$baseline";then return 1;fi
  fi
  return 0
}

emit_waf_controls() {
  local control_id="$1" pl="$2"
  # Preserve the existing paranoia controls exactly. Changing CRS 4
  # variable names alters deployed policy behavior and is a separate change.
  printf 'SecAction "id:%s,phase:1,nolog,pass,setvar:tx.paranoia_level=%s,setvar:tx.executing_paranoia_level=%s"\n' "$control_id" "$pl" "$pl"
}

emit_grpc_waf_exception() {
  if [[ "${MANAGED_GRPC:-0}" == 1 ]];then
    printf 'SecRule REQUEST_HEADERS:Content-Type "@rx (?i)^application/grpc(?:[+]proto|[+]json)?(?:;.*)?$" "id:79999999,phase:1,pass,nolog,ctl:ruleRemoveById=920420"\n'
  fi
}

emit_waf_exclusions() {
  local host="$1" disabled="$2" rule_id item
  local -a route_rules=()
  while IFS= read -r rule_id; do
    [[ -n "$rule_id" ]] && printf 'SecRuleRemoveById %s\n' "$rule_id"
  done < <(disabled_waf_rules "$host")
  IFS=',' read -r -a route_rules <<< "$disabled"
  for item in "${route_rules[@]}"; do
    [[ -n "$item" ]] && printf 'SecRuleRemoveById %s\n' "$item"
  done
  return 0
}

build_route_waf_config() {
  local host="$1" route_id="$2" pl="$3" plugin_csv="$4" disabled="$5"
  local slug out control_id

  validate_waf_pl "$pl"
  plugin_csv="$(normalize_plugin_csv "$plugin_csv")"
  disabled="$(normalize_rule_csv "$disabled")"
  slug="$(slug_for_host "$host")"
  out="$waf_route_stage/${slug}-${route_id}.conf"
  control_id=$((80000000 + (16#${route_id:0:6})))

  {
    printf 'Include %s/modsecurity.conf\n' "$NGINX_DIR"
    printf 'Include %s/crs-setup.conf\n' "$(active_crs_dir)"
    emit_waf_controls "$control_id" "$pl"
    emit_plugin_group "$plugin_csv" config
    emit_grpc_waf_exception
    emit_plugin_group "$plugin_csv" before
    printf 'Include %s/rules/*.conf\n' "$(active_crs_dir)"
    emit_plugin_group "$plugin_csv" after
    printf 'Include %s/modsecurity-overrides.conf\n' "$NGINX_DIR"

    emit_waf_exclusions "$host" "$disabled"
  } > "$out"
  chmod 0644 "$out"
}

emit_location_waf() {
  local host="$1" route_id="$2" pl="$3" plugin_csv="$4" disabled="$5"
  local slug
  slug="$(slug_for_host "$host")"
  build_route_waf_config "$host" "$route_id" "$pl" "$plugin_csv" "$disabled"
  echo "        modsecurity on;"
  if can_share_waf "$host" "$plugin_csv";then
    # Shared base is compiled once per NGINX configuration cycle, lazily
    # on first protected route. No global inheritance or stream WAF.
    {
      printf 'Include %s/modsecurity.conf\n' "$NGINX_DIR"
      printf 'Include %s/crs-setup.conf\n' "$(active_crs_dir)"
      printf 'Include %s/rules/*.conf\n' "$(active_crs_dir)"
      printf 'Include %s/modsecurity-overrides.conf\n' "$NGINX_DIR"
    } > "$waf_route_stage/_shared-crs.conf"
    {
      emit_waf_controls "$((80000000 + (16#${route_id:0:6})))" "$pl"
      emit_grpc_waf_exception
      emit_waf_exclusions "$host" "$(normalize_rule_csv "$disabled")"
    } > "$waf_route_stage/${slug}-${route_id}.local.conf"
    echo "        modsecurity_rules_file $WAF_ROUTE_DIR/${slug}-${route_id}.local.conf;"
    echo "        modsecurity_rules_file_shared $WAF_ROUTE_DIR/_shared-crs.conf;"
  else
    # Legacy complete rule configuration preserves exact load order.
    echo "        modsecurity_rules_file $WAF_ROUTE_DIR/${slug}-${route_id}.conf;"
  fi
}

route_value() {
  local route="$1" key="$2" fallback="$3" value
  value="$(kv_get "$route" "$key")"
  printf '%s' "${value:-$fallback}"
}

emit_route_values() {
  local host="$1" match="$2" path="$3" target="$4" websocket="$5"
  local timeout="$6" waf="$7" force_https="$8" waf_pl="$9" waf_plugins="${10}" waf_disabled="${11}" scheme="${12}" cert_exists="${13}"
  local listener_key="$scheme"
  scheme="${scheme%%:*}"
  local location id methods rewrite_enabled rewrite_pattern rewrite_replacement header_blob header_line header_name header_value header_text
  local allow_ips="${14:-}" rate_count="${15:-0}" rate_unit="${16:-m}" max_body="${17:-}" zone="${18:-}" address
  allow_ips="$(normalize_allow_ips "$allow_ips")"
  validate_route_rate "$rate_count" "$rate_unit"
  validate_route_body_size "$max_body"

  case "$match" in
    exact) location="location = $path" ;;
    regex) location="location ~ $path" ;;
    *) location="location ^~ $path" ;;
  esac

  id="$(printf '%s\n%s\n%s' "$match" "$path" "$target" | sha256sum | cut -c1-16)"
  id="${MANAGED_ROUTE_ID:-$id}"
  if [[ "${MANAGED_DISPATCH:-0}" == 1 ]]; then location="location @le_route_$id"; fi
  printf '    %s {\n' "$location"
  # MCP token URLs are bearer credentials. Never write the URL or the
  # route label into ordinary WAF access logs. The predeclared sanitized
  # format retains status, method and timing without the token.
  if [[ "$match" == prefix && "$path" == /mcp/ ]]; then
    echo '        access_log /data/logs/events.jsonl liteedge_mcp_json;'
    echo '        error_log /dev/null crit;'
  fi
  printf '        set $liteedge_route "%s";\n' "$match:$path"
  if [[ -n "$allow_ips" ]]; then
    local -a addresses=()
    IFS=',' read -r -a addresses <<< "$allow_ips"
    for address in "${addresses[@]}"; do printf '        allow %s;\n' "$address"; done
    echo '        deny all;'
  fi
  if [[ "$rate_count" != 0 ]]; then
    [[ -n "$zone" ]] || zone="$(route_limit_zone "$host" "$id")"
    printf '        limit_req zone=%s;\n' "$zone"
    echo '        limit_req_status 429;'
  fi
  [[ -z "$max_body" ]] || printf '        client_max_body_size %s;\n' "$max_body"

  if [[ "${MANAGED_GRPC:-0}" == 1 ]];then
    emit_response_headers "${MANAGED_RESPONSE_HEADERS_B64:-}" "$scheme" 0 | sed "s/proxy_hide_header/grpc_hide_header/"
  else
    emit_response_headers "${MANAGED_RESPONSE_HEADERS_B64:-}" "$scheme" "${POOL_COOKIE_AFFINITY:-0}"
  fi

  if [[ "$scheme" == http && "$force_https" == 1 && "$cert_exists" == 1 ]]; then
    echo "        return 301 https://\$host$HTTPS_REDIRECT_SUFFIX\$request_uri;"
    echo "    }"
    return 0
  fi

  if [[ -n "${MANAGED_REDIRECT_B64:-}" ]]; then
    local redirect_json redirect_scheme redirect_host redirect_port redirect_code redirect_suffix="" redirect_path='$request_uri'
    redirect_json="$(printf '%s' "$MANAGED_REDIRECT_B64" | base64 -d)"
    redirect_scheme="$(jq -r '.scheme' <<< "$redirect_json")"
    redirect_host="$(jq -r '.hostname' <<< "$redirect_json")"
    redirect_port="$(jq -r '.port' <<< "$redirect_json")"
    redirect_code="$(jq -r '.status_code' <<< "$redirect_json")"
    if [[ "$redirect_port" == 0 && -z "$redirect_scheme" && "$listener_key" == *:* ]]; then redirect_port="${listener_key#*:}"; fi
    redirect_scheme="${redirect_scheme:-$scheme}"
    redirect_host="${redirect_host:-\$host}"
    if [[ "$redirect_port" != 0 && ! ( "$redirect_scheme" == http && "$redirect_port" == 80 ) && ! ( "$redirect_scheme" == https && "$redirect_port" == 443 ) ]]; then
      redirect_suffix=":$redirect_port"
    fi
    [[ "$waf" != 1 ]] || emit_location_waf "$host" "$id" "$waf_pl" "$waf_plugins" "$waf_disabled"
    if jq -e '.path!=null' <<< "$redirect_json" >/dev/null; then
      local redirect_var
      redirect_var="le_path_$(printf '%s/%s' "$host" "$id" | sha256sum | cut -c1-24)"
      printf '        if ($%s = "") { return 400; }\n' "$redirect_var"
      redirect_path="\$$redirect_var\$is_args\$args"
    fi
    printf '        error_page 418 =%s %s://%s%s%s;\n' "$redirect_code" "$redirect_scheme" "$redirect_host" "$redirect_suffix" "$redirect_path"
    echo '        root /dev/null;'
    echo '        try_files /.__liteedge_dispatch__ =418;'
    echo '    }'
    return 0
  fi
  printf '        set $liteedge_route_%s "%s";\n' "$id" "$target"

  methods="${ROUTE_METHODS:-ALL}"
  validate_route_methods "$methods"
  if [[ "$methods" != ALL ]]; then
    printf '        if ($request_method !~ ^(%s)$) {\n' "${methods//,/|}"
    echo '            return 405;'
    echo '        }'
  fi
  rewrite_enabled="${ROUTE_REWRITE_ENABLED:-0}"
  rewrite_pattern="${ROUTE_REWRITE_PATTERN:-}"
  rewrite_replacement="${ROUTE_REWRITE_REPLACEMENT:-}"
  validate_route_rewrite "$rewrite_enabled" "$rewrite_pattern" "$rewrite_replacement"
  if [[ "$rewrite_enabled" == 1 ]]; then
    printf '        rewrite %s %s break;\n' "$rewrite_pattern" "$rewrite_replacement"
  fi
  if [[ "$waf" == 1 ]]; then
    emit_location_waf "$host" "$id" "$waf_pl" "$waf_plugins" "$waf_disabled"
  fi

  if [[ "${MANAGED_GRPC:-0}" == 1 ]];then
    [[ "$target" =~ ^https?://[A-Za-z0-9._:-]+$ ]] || die 'gRPC requires origin-only backends.'
    local grpc_target="grpc://${target#*://}"
    [[ "$target" != https://* ]] || grpc_target="grpcs://${target#*://}"
    echo '        if ($content_type !~* "^application/grpc([+]proto|[+]json)?(;.*)?$") { return 415; }'
    printf '        set $liteedge_grpc_%s "%s";\n' "$id" "$grpc_target"
    printf '        grpc_pass $liteedge_grpc_%s;\n' "$id"
    echo '        grpc_set_header Host $http_host;'
    echo '        grpc_set_header X-Real-IP $remote_addr;'
    echo '        grpc_set_header X-Forwarded-For $remote_addr;'
    echo '        grpc_set_header X-Forwarded-Proto $scheme;'
    echo '        grpc_set_header X-Forwarded-Host $host;'
    echo '        grpc_set_header X-Forwarded-Port $liteedge_external_port;'
    echo '        grpc_set_header Forwarded "";'
    emit_managed_headers "$host" "$id" "${MANAGED_HEADERS_B64:-}" | sed "s/proxy_set_header/grpc_set_header/"
    if [[ -n "${MANAGED_BACKEND_TLS_CA:-}" ]];then
      echo '        grpc_ssl_server_name on;'
      printf '        grpc_ssl_name %s;\n' "$MANAGED_BACKEND_TLS_NAME"
      echo '        grpc_ssl_verify on;'
      echo '        grpc_ssl_verify_depth 8;'
      echo '        grpc_ssl_protocols TLSv1.2 TLSv1.3;'
      printf '        grpc_ssl_trusted_certificate %s;\n' "$MANAGED_BACKEND_TLS_CA"
    elif [[ "$target" == https://* ]];then die 'gRPC over TLS requires verified identity';fi
    echo '        grpc_next_upstream off;'
    printf '        grpc_connect_timeout %ss;\n        grpc_send_timeout %ss;\n        grpc_read_timeout %ss;\n' "$timeout" "$timeout" "$timeout"
    echo '        error_page 502 503 504 = @le_grpc_unavailable;'
    echo '    }'
    return 0
  elif [[ -n "${MANAGED_DEADLINE_CONFIG:-}" ]];then
    echo '        set $liteedge_deadline_enabled 1;'
    echo '        proxy_hide_header X-LiteEdge-Deadline-Backend;'
    echo '        proxy_hide_header X-LiteEdge-Deadline-Attempts;'
    if [[ -n "${MANAGED_REWRITE_PATH:-}" ]];then
      printf '        if ($%s = "") { return 400; }\n' "$MANAGED_REWRITE_PATH"
      printf '        proxy_pass http://unix:%s/deadline.sock:$%s$is_args$args;\n' "${LITEEDGE_RUN_DIR:-/tmp/liteedge-run}" "$MANAGED_REWRITE_PATH"
    else
      printf '        proxy_pass http://unix:%s/deadline.sock:$request_uri;\n' "${LITEEDGE_RUN_DIR:-/tmp/liteedge-run}"
    fi
    printf '        proxy_set_header X-LiteEdge-Deadline-Config "%s";\n' "$MANAGED_DEADLINE_CONFIG"
    echo '        proxy_set_header Connection close;'
    echo '        proxy_set_header Upgrade $http_upgrade;'
  elif [[ -n "${MANAGED_REWRITE_PATH:-}" ]]; then
    printf '        if ($%s = "") { return 400; }\n' "$MANAGED_REWRITE_PATH"
    printf '        proxy_pass $liteedge_route_%s$%s$is_args$args;\n' "$id" "$MANAGED_REWRITE_PATH"
  elif [[ "$rewrite_enabled" == 1 || "$methods" != ALL ]]; then
    # A literal upstream survives conditional method checks and rewrite-phase exits.
    printf '        proxy_pass %s;\n' "$target"
  else
    printf '        proxy_pass $liteedge_route_%s;\n' "$id"
  fi
  emit_proxy_headers
  emit_managed_headers "$host" "$id" "${MANAGED_HEADERS_B64:-}"
  header_blob="${ROUTE_X_HEADERS_B64:-}"
  if [[ -n "$header_blob" ]]; then
    header_text="$(printf '%s' "$header_blob" | base64 -d 2>/dev/null)" || die 'Invalid headers encoding.'
    validate_route_headers "$header_text"
    while IFS= read -r header_line || [[ -n "$header_line" ]]; do
      [[ -n "$header_line" ]] || continue
      header_name="${header_line%%:*}"; header_value="${header_line#*:}"; header_value="${header_value# }"
      printf '        proxy_set_header %s "%s";\n' "$header_name" "$header_value"
    done <<< "$header_text"
  fi
  if [[ -n "${MANAGED_MIRRORS_B64:-}" ]]; then
    local mirror_index=0 mirror_rows mirror_destination
    mirror_rows="$(printf '%s' "$MANAGED_MIRRORS_B64" | base64 -d | jq -r '.[].target')"
    while IFS= read -r mirror_destination; do
      [[ -n "$mirror_destination" ]] || continue
      printf '        mirror /.liteedge-internal/mirror/%s/%s;\n' "$id" "$mirror_index"
      ((mirror_index+=1))
    done <<< "$mirror_rows"
    echo '        mirror_request_body on;'
  fi
  if [[ -z "${MANAGED_DEADLINE_CONFIG:-}" && -n "${MANAGED_BACKEND_TLS_CA:-}" ]];then
    echo '        proxy_ssl_server_name on;'
    printf '        proxy_ssl_name %s;\n' "$MANAGED_BACKEND_TLS_NAME"
    echo '        proxy_ssl_verify on;'
    echo '        proxy_ssl_verify_depth 8;'
    echo '        proxy_ssl_protocols TLSv1.2 TLSv1.3;'
    printf '        proxy_ssl_trusted_certificate %s;\n' "$MANAGED_BACKEND_TLS_CA"
  elif [[ "$target" == https://* && "${LITEEDGE_ALLOW_UNVERIFIED_BACKEND_TLS:-0}" != 1 ]];then
    echo '        proxy_ssl_server_name on;'
    echo '        proxy_ssl_verify on;'
    echo '        proxy_ssl_verify_depth 8;'
    echo '        proxy_ssl_protocols TLSv1.2 TLSv1.3;'
    echo '        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;'
  fi
  if [[ -n "${MANAGED_DEADLINE_CONFIG:-}" ]];then
    echo '        proxy_next_upstream off;'
    timeout=3605
    websocket=0
  elif [[ -n "${MANAGED_RETRY_B64:-}" ]];then
    local retry_json retry_attempts retry_budget retry_codes
    retry_json="$(printf '%s' "$MANAGED_RETRY_B64"|base64 -d)"
    retry_attempts="$(jq -r '.attempts' <<< "$retry_json")"
    retry_budget="$(jq -r '.budget_ms' <<< "$retry_json")"
    retry_codes="$(jq -r '.codes|map("http_"+tostring)|join(" ")' <<< "$retry_json")"
    if ((retry_attempts==0));then
      echo '        proxy_next_upstream off;'
    else
      printf '        proxy_next_upstream error timeout%s;\n' "${retry_codes:+ $retry_codes}"
      printf '        proxy_next_upstream_tries %s;\n' "$((retry_attempts+1))"
      if ((retry_budget>0));then printf '        proxy_next_upstream_timeout %sms;\n' "$retry_budget";fi
    fi
  fi
  printf '        proxy_connect_timeout %ss;\n' "$timeout"
  printf '        proxy_send_timeout %ss;\n' "$timeout"
  printf '        proxy_read_timeout %ss;\n' "$timeout"
  [[ "$websocket" == 1 ]] && emit_websocket_headers
  [[ "${POOL_COOKIE_AFFINITY:-0}" == 1 ]] && echo '        add_header Set-Cookie "liteedge_affinity=$liteedge_affinity_key; Path=/; Secure; HttpOnly; SameSite=Lax" always;'
  echo "    }"
}

emit_route() {
  local host="$1" route="$2" scheme="$3" cert_exists="$4"
  local match path target websocket timeout waf force_https waf_pl waf_plugins waf_disabled legacy_profile
  local allow_ips rate_count rate_unit max_body route_id guard_zone schemes
  [[ "$(route_value "$route" ACTION proxy)" == custom ]] && return 0
  schemes="$(route_value "$route" SCHEMES http,https)"
  [[ ",$schemes," == *",$scheme,"* ]] || return 0
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
  allow_ips="$(route_value "$route" ALLOW_IPS "")"
  rate_count="$(route_value "$route" RATE_COUNT 0)"
  rate_unit="$(route_value "$route" RATE_UNIT m)"
  max_body="$(route_value "$route" MAX_BODY "")"
  route_id="$(route_value "$route" ID "")"
  if [[ ! "$route_id" =~ ^[a-f0-9]{16}$ ]]; then
    route_id="$(printf '%s\n%s\n%s' "$match" "$path" "$target" | sha256sum | cut -c1-16)"
  fi
  guard_zone="$(route_limit_zone "$host" "$route_id")"
  if ! provider_route_pinned "$route";then
    # Old DNS-based configuration is blocked until the owning controller
    # resubmits it for scoped IP pinning. Preserve dispatch and other sites.
    local blocked_location
    if [[ "${MANAGED_DISPATCH:-0}" == 1 ]];then blocked_location="@le_route_$route_id"
    else
      case "$match" in exact) blocked_location="= $path";; regex) blocked_location="~ $path";; *) blocked_location="^~ $path";; esac
    fi
    printf '    location %s { return 503; }\n' "$blocked_location"
    return 0
  fi

  legacy_profile="$(route_value "$route" PROFILE "")"
  if [[ -z "$waf_plugins" && "$legacy_profile" == wordpress && -d "$WAF_PLUGIN_DIR/wordpress-rule-exclusions" ]]; then
    waf_plugins=wordpress-rule-exclusions
  fi

  unset MANAGED_ROUTE_ID MANAGED_HEADERS_B64 MANAGED_REDIRECT_B64 MANAGED_REWRITE_HOST MANAGED_REWRITE_PATH MANAGED_RESPONSE_HEADERS_B64
  if [[ "$(kv_get "$route" PROVIDER_ROUTE)" == 1 || "$(kv_get "$route" TYPED_ROUTE)" == 1 || "${MANAGED_DISPATCH:-0}" == 1 ]]; then
    MANAGED_ROUTE_ID="$route_id"
    MANAGED_HEADERS_B64="$(kv_get "$route" GW_HEADERS_B64)"
    MANAGED_RESPONSE_HEADERS_B64="$(kv_get "$route" GW_RESPONSE_HEADERS_B64)"
    MANAGED_REDIRECT_B64="$(kv_get "$route" GW_REDIRECT_B64)"
    local rewrite_blob rewrite_json
    rewrite_blob="$(kv_get "$route" GW_REWRITE_B64)"
    if [[ -n "$rewrite_blob" ]]; then
      rewrite_json="$(printf '%s' "$rewrite_blob" | base64 -d)"
      MANAGED_REWRITE_HOST="$(jq -r '.hostname // ""' <<< "$rewrite_json")"
      if jq -e '.path!=null' <<< "$rewrite_json" >/dev/null; then
        MANAGED_REWRITE_PATH="le_path_$(printf '%s/%s' "$host" "$route_id" | sha256sum | cut -c1-24)"
      fi
    fi
  fi
  unset MANAGED_BACKEND_TLS_CA MANAGED_BACKEND_TLS_NAME
  if [[ -n "$(kv_get "$route" GW_BACKEND_TLS_B64)" ]];then
    local tls_features tls_ca_id
    tls_features="$(python3 /opt/liteedge/bin/route_features.py read "$route")" || die 'Invalid verified backend TLS configuration.'
    [[ "$(kv_get "$route" TYPED_ROUTE)" == 1 || "$(kv_get "$route" PROVIDER_ROUTE)" == 1 ]] || die 'Backend TLS requires a typed route.'
    printf '%s' "$tls_features" | python3 /opt/liteedge/bin/route_features.py validate-tls-targets "$target" "$(kv_get "$route" BACKENDS)" "$(route_value "$route" HEALTH_ENABLED 0)" || die 'Invalid backend TLS targets.'
    MANAGED_BACKEND_TLS_NAME="$(jq -r '.backend_tls.hostname' <<< "$tls_features")"
    tls_ca_id="$(jq -r '.backend_tls.ca_certificate' <<< "$tls_features" | sha256sum | cut -c1-64)"
    jq -r '.backend_tls.ca_certificate' <<< "$tls_features" > "$waf_route_stage/backend-ca-$tls_ca_id.pem"
    chmod 0644 "$waf_route_stage/backend-ca-$tls_ca_id.pem"
    MANAGED_BACKEND_TLS_CA="$WAF_ROUTE_DIR/backend-ca-$tls_ca_id.pem"
  fi
  MANAGED_GRPC=0
  if [[ "$(kv_get "$route" GW_GRPC)" == 1 ]];then
    python3 /opt/liteedge/bin/route_features.py read "$route" >/dev/null || die 'Invalid gRPC route.'
    [[ "$(kv_get "$route" TYPED_ROUTE)" == 1 || "$(kv_get "$route" PROVIDER_ROUTE)" == 1 ]] || die 'gRPC requires typed route.'
    [[ "$(kv_get "$route" LB_MODE)" != cookie && "$force_https" == 0 && "$(route_value "$route" REWRITE_ENABLED 0)" == 0 && -z "$(kv_get "$route" X_HEADERS_B64)" ]] || die 'Invalid gRPC legacy transformations.'
    MANAGED_GRPC=1
  fi
  MANAGED_DEADLINE_CONFIG=""
  if [[ -n "$(kv_get "$route" GW_DEADLINES_B64)" || -n "$(kv_get "$route" GW_RETRY_B64)" || -n "$(kv_get "$route" GW_BACKEND_TLS_PEERS_B64)" ]];then
    MANAGED_DEADLINE_CONFIG="$(python3 /opt/liteedge/bin/route_features.py deadline-config "$route")" || die 'Invalid deadline policy.'
    if [[ -n "$MANAGED_DEADLINE_CONFIG" ]];then
      [[ -x /opt/liteedge/bin/deadline-proxy ]] || die 'Deadline proxy binary not installed.'
      [[ "$(kv_get "$route" TYPED_ROUTE)" == 1 || "$(kv_get "$route" PROVIDER_ROUTE)" == 1 ]] || die 'Deadlines require a typed route.'
    fi
  fi
  MANAGED_RETRY_B64=""
  if [[ -n "$(kv_get "$route" GW_RETRY_B64)" ]];then
    local retry_features
    retry_features="$(python3 /opt/liteedge/bin/route_features.py read "$route")" || die 'Invalid retry configuration.'
    [[ "$(kv_get "$route" TYPED_ROUTE)" == 1 || "$(kv_get "$route" PROVIDER_ROUTE)" == 1 ]] || die 'Retries require a typed route.'
    if [[ -z "$MANAGED_DEADLINE_CONFIG" ]] && jq -e '.retry.attempts>0' <<< "$retry_features" >/dev/null;then
      local retry_targets
      retry_targets="$(pool_urls "$route")"
      if [[ -z "$(kv_get "$route" BACKENDS)" ]] || grep -Eq "^(invalid|unavailable)$" <<< "$retry_targets"; then die 'Retries require multiple valid HTTP backends.'; fi
      [[ "$(sort -u <<< "$retry_targets"|wc -l)" == "$(wc -l <<< "$retry_targets")" ]] || die 'Retry backends must be distinct.'
    fi
    MANAGED_RETRY_B64="$(jq -r 'if .retry==null then "" else .retry|@base64 end' <<< "$retry_features")"
  fi
  MANAGED_MIRRORS_B64=""
  if [[ -n "$(kv_get "$route" GW_MIRRORS_B64)" ]]; then
    local mirror_features
    mirror_features="$(python3 /opt/liteedge/bin/route_features.py read "$route")" || die 'Invalid mirror configuration.'
    [[ "$(kv_get "$route" TYPED_ROUTE)" == 1 || "$(kv_get "$route" PROVIDER_ROUTE)" == 1 ]] || die 'Mirrors require a typed route.'
    [[ "$(route_value "$route" REWRITE_ENABLED 0)" == 0 && -z "$(kv_get "$route" X_HEADERS_B64)" && "$force_https" == 0 ]] || die 'Mirrors cannot be combined with legacy request transformations.'
    MANAGED_MIRRORS_B64="$(jq -r 'if .mirrors==[] then "" else .mirrors|@base64 end' <<< "$mirror_features")"
  fi
  target="$(pool_effective_target "$host" "$route")"
  ROUTE_METHODS="$(route_value "$route" METHODS ALL)"
  ROUTE_REWRITE_ENABLED="$(route_value "$route" REWRITE_ENABLED 0)"
  ROUTE_REWRITE_PATTERN="$(route_value "$route" REWRITE_PATTERN "")"
  ROUTE_REWRITE_REPLACEMENT="$(route_value "$route" REWRITE_REPLACEMENT "")"
  ROUTE_X_HEADERS_B64="$(route_value "$route" X_HEADERS_B64 "")"
  POOL_COOKIE_AFFINITY=0
  [[ -n "$(kv_get "$route" BACKENDS)" && "$(kv_get "$route" LB_MODE)" == cookie ]] && POOL_COOKIE_AFFINITY=1
  emit_route_values "$host" "$match" "$path" "$target" "$websocket" "$timeout" "$waf" "$force_https" "$waf_pl" "$waf_plugins" "$waf_disabled" "$scheme" "$cert_exists" "$allow_ips" "$rate_count" "$rate_unit" "$max_body" "$guard_zone"
  # Internal subrequests keep the original method, body, URI and query. A
  # mirror is emitted only by the selected primary route's precontent phase
  # (after access controls), and its response never replaces the primary.
  if [[ -n "$MANAGED_MIRRORS_B64" ]]; then
    local mirror_index=0 mirror_rows mirror_destination mirror_points mirror_salt
    mirror_rows="$(printf '%s' "$MANAGED_MIRRORS_B64" | base64 -d | jq -r '.[]|[.target,.basis_points]|@tsv')"
    while IFS=$'\t' read -r mirror_destination mirror_points; do
      [[ -n "$mirror_destination" ]] || continue
      printf '    location = /.liteedge-internal/mirror/%s/%s {\n' "$route_id" "$mirror_index"
      echo '        internal;'
      echo '        modsecurity off;'
      if ((mirror_points<10000)); then
        mirror_salt="$(printf '%s/%s/%s' "$host" "$route_id" "$mirror_index" | sha256sum | cut -c1-24)"
        printf '        if ($le_mirror_%s = 0) { return 204; }\n' "$mirror_salt"
      fi
      printf '        proxy_pass %s$request_uri;\n' "$mirror_destination"
      emit_proxy_headers
      emit_managed_headers "$host" "$route_id" "${MANAGED_HEADERS_B64:-}"
      echo '        proxy_connect_timeout 5s;'
      echo '        proxy_send_timeout 5s;'
      echo '        proxy_read_timeout 5s;'
      echo '        proxy_next_upstream off;'
      echo '    }'
      ((mirror_index+=1))
    done <<< "$mirror_rows"
  fi
  unset MANAGED_GRPC MANAGED_DEADLINE_CONFIG MANAGED_MIRRORS_B64 MANAGED_RETRY_B64 MANAGED_BACKEND_TLS_CA MANAGED_BACKEND_TLS_NAME
  POOL_COOKIE_AFFINITY=0
  unset MANAGED_BACKEND_TLS_CA MANAGED_BACKEND_TLS_NAME ROUTE_METHODS ROUTE_REWRITE_ENABLED ROUTE_REWRITE_PATTERN ROUTE_REWRITE_REPLACEMENT ROUTE_X_HEADERS_B64 MANAGED_ROUTE_ID MANAGED_HEADERS_B64 MANAGED_REDIRECT_B64 MANAGED_REWRITE_HOST MANAGED_REWRITE_PATH MANAGED_RESPONSE_HEADERS_B64
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

  unset MANAGED_BACKEND_TLS_CA MANAGED_BACKEND_TLS_NAME ROUTE_METHODS ROUTE_REWRITE_ENABLED ROUTE_REWRITE_PATTERN ROUTE_REWRITE_REPLACEMENT ROUTE_X_HEADERS_B64 MANAGED_ROUTE_ID MANAGED_HEADERS_B64 MANAGED_REDIRECT_B64 MANAGED_REWRITE_HOST MANAGED_REWRITE_PATH MANAGED_RESPONSE_HEADERS_B64
  emit_route_values "$host" prefix / "$upstream" "$websocket" "$timeout" "$waf" "$force_https" "$waf_pl" "$waf_plugins" "" "$scheme" "$cert_exists"
}

emit_routes() {
  local host="$1" file="$2" scheme="$3" cert_exists="$4" route
  local managed_root=0
  if grep -qs '^GW_GRPC=1$' "$(route_dir "$host")"/*.route; then
    echo '    location @le_grpc_unavailable { default_type application/grpc; add_header grpc-status 14 always; return 200 ""; }'
  fi
  if [[ "$(kv_get "$file" GW_DISPATCH)" == 1 ]] || { [[ -z "$(kv_get "$file" PROVIDER)" ]] && grep -qs "^TYPED_ROUTE=1$" "$(route_dir "$host")"/*.route; }; then
    local selector
    selector="liteedge_select_$(printf '%s/%s' "$host" "$scheme" | sha256sum | cut -c1-24)"
    printf '    location / { root /dev/null; try_files /.__liteedge_dispatch__ $%s; }\n' "$selector"
    echo '    location @le_not_found { return 404; }'
    MANAGED_DISPATCH=1
  fi
  for route in "$(route_dir "$host")"/*.route; do
    [[ -e "$route" ]] || continue
    if [[ "$(kv_get "$route" PATH)" == / && "$(kv_get "$route" MATCH)" == prefix && ",$(route_value "$route" SCHEMES http,https)," == *",$scheme,"* ]]; then managed_root=1; fi
    emit_route "$host" "$route" "$scheme" "$cert_exists"
  done
  if [[ -n "$(kv_get "$file" PROVIDER)" && "${MANAGED_DISPATCH:-0}" != 1 && "$managed_root" == 0 ]]; then
    echo '    location / { return 404; }'
  fi
  unset MANAGED_DISPATCH
  if [[ "$scheme" == http || "$scheme" == https ]];then emit_legacy_default "$host" "$file" "$scheme" "$cert_exists"; fi
}

emit_route_limit_zones() {
  local file host route rate_count rate_unit route_id match path target zone
  for file in "$SITE_DIR"/*.site; do
    host="$(kv_get "$file" HOST)"
    for route in "$(route_dir "$host")"/*.route; do
      [[ -e "$route" ]] || continue
      [[ "$(route_value "$route" ACTION proxy)" != custom ]] || continue
      rate_count="$(route_value "$route" RATE_COUNT 0)"
      rate_unit="$(route_value "$route" RATE_UNIT m)"
      validate_route_rate "$rate_count" "$rate_unit"
      [[ "$rate_count" != 0 ]] || continue
      route_id="$(route_value "$route" ID "")"
      if [[ ! "$route_id" =~ ^[a-f0-9]{16}$ ]]; then
        match="$(route_value "$route" MATCH prefix)"
        path="$(route_value "$route" PATH /)"
        target="$(route_value "$route" TARGET "")"
        route_id="$(printf '%s\n%s\n%s' "$match" "$path" "$target" | sha256sum | cut -c1-16)"
      fi
      zone="$(route_limit_zone "$host" "$route_id")"
      printf '    limit_req_zone $binary_remote_addr zone=%s:1m rate=%sr/%s;\n' "$zone" "$rate_count" "$rate_unit"
    done
  done
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

# Extra listeners default to 404 rather than exposing the first site when the
# Host does not match. The mapping is operator-controlled, never route input.
extra_rows="$(python3 /opt/liteedge/bin/listener_ports.py)" || die 'Invalid extra listener mapping.'
declare -A extra_binds=()
if [[ -n "$extra_rows" ]]; then
  while read -r listener bind; do
    extra_binds["$listener"]="$bind"
    if [[ "$listener" == https:* ]];then
      printf 'server { listen %s:%s ssl default_server; server_name _; ssl_reject_handshake on; return 421; }\n' "$BIND_ADDRESS" "$bind"
    else
      printf 'server { listen %s:%s default_server; http2 on; server_name _; include /opt/liteedge/etc/nginx/security.conf; return 404; }\n' "$BIND_ADDRESS" "$bind"
    fi
  done <<< "$extra_rows" > "$stage/_extra-listeners.conf"
fi
listener_server_name() {
  local file="$1" host="$2" aliases="$3" listener="$4" candidate suffix escaped exclusions="" candidate_listeners
  if [[ "$host" == "*" && -n "$(kv_get "$file" PROVIDER)" ]]; then
    for candidate in "$SITE_DIR"/*.site; do
      [[ "$(kv_get "$candidate" GW_WILDCARD_SINGLE)" == 1 && -n "$(kv_get "$candidate" PROVIDER)" ]] || continue
      suffix="$(kv_get "$candidate" HOST)"
      suffix="${suffix:2}"
      escaped="${suffix//./\\.}"
      candidate_listeners="$(kv_get "$candidate" GW_LISTENERS)"
      if [[ ",$candidate_listeners," == *",$listener,"* ]];then exclusions+="${exclusions:+|}[^.]+\.$escaped";fi
    done
    if [[ -n "$exclusions" ]]; then printf '%s' "~^(?!(?:$exclusions)\$).+\$"; else printf '%s' '~^.+$'; fi
  elif [[ "$(kv_get "$file" GW_WILDCARD_SINGLE)" == 1 && -n "$(kv_get "$file" PROVIDER)" ]]; then
    suffix="${host:2}"
    escaped="${suffix//./\\.}"
    printf '%s' "~^[^.]+\.$escaped\$"
  else
    printf '%s %s' "$host" "$aliases"
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

  listeners="$(kv_get "$file" GW_LISTENERS)"
  listeners="${listeners:-http,https}"
  if [[ -z "$(kv_get "$file" PROVIDER)" ]];then
    for route in "$(route_dir "$host")"/*.route; do
      [[ -f "$route" ]] || continue
      IFS=, read -r -a route_listeners <<< "$(route_value "$route" SCHEMES http,https)"
      for listener in "${route_listeners[@]}"; do
        if [[ "$listener" == *:* && ",$listeners," != *",$listener,"* ]];then listeners+=",$listener";fi
      done
    done
  fi
  {
    IFS=, read -r -a site_listener_keys <<< "$listeners"
    for listener in "${site_listener_keys[@]}";do
      [[ "$listener" == http || "$listener" == http:* ]] || continue
      bind="$HTTP_PORT"
      if [[ "$listener" != http ]];then
        [[ -n "${extra_binds[$listener]:-}" ]] || die 'Extra HTTP listener not provisioned.'
        bind="${extra_binds[$listener]}"
      fi
    echo "server {"
    echo "    listen $BIND_ADDRESS:$bind;"
    echo "    http2 on;"
    echo "    server_name $(listener_server_name "$file" "$host" "$aliases" "$listener");"
    echo "    include /opt/liteedge/etc/nginx/security.conf;"
    if [[ "$listener" == http ]];then
    cat <<CONF
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_DIR/challenges;
        auth_basic off;
        try_files \$uri =404;
    }
CONF
    fi
    emit_routes "$host" "$file" "$listener" "$cert_exists"
    echo "}"
    done

    for listener in "${site_listener_keys[@]}";do
      [[ "$listener" == https || "$listener" == https:* ]] || continue
      bind="$HTTPS_PORT";listener_cert="$cert";listener_key="$key"
      reject=0
      if [[ "$listener" == https ]];then
        [[ "$(kv_get "$file" GW_TLS_REJECT)" == 1 ]] && reject=1
      else
        [[ -n "${extra_binds[$listener]:-}" ]] || die 'Extra HTTPS listener not provisioned.'
        bind="${extra_binds[$listener]}"
        if [[ -n "$(kv_get "$file" PROVIDER)" ]];then
          listener_cert="$cdir/listeners/${listener/:/-}/fullchain.pem"
          listener_key="$cdir/listeners/${listener/:/-}/privkey.pem"
          [[ ",$(kv_get "$file" GW_TLS_REJECT_LISTENERS)," == *",$listener,"* ]] && reject=1
        fi
      fi
      server_name_tls="$(listener_server_name "$file" "$host" "$aliases" "$listener")"
      if [[ "$reject" == 1 && -n "$(kv_get "$file" PROVIDER)" ]];then
        echo "server {"
        echo "    listen $BIND_ADDRESS:$bind ssl;"
        echo "    server_name $server_name_tls;"
        echo "    ssl_reject_handshake on;"
        echo "    return 421;"
        echo "}"
      elif [[ -s "$listener_cert" && -s "$listener_key" ]];then
        echo
        echo "server {"
        echo "    listen $BIND_ADDRESS:$bind ssl;"
        echo "    http2 on;"
        echo "    server_name $server_name_tls;"
        echo "    ssl_certificate $listener_cert;"
        echo "    ssl_certificate_key $listener_key;"
        echo "    ssl_protocols TLSv1.2 TLSv1.3;"
        echo "    ssl_session_cache shared:SSL:10m;"
        echo "    ssl_session_timeout 10m;"
        echo "    ssl_session_tickets off;"
        echo '    add_header Strict-Transport-Security "max-age=31536000" always;'
        echo "    include /opt/liteedge/etc/nginx/security.conf;"
        emit_routes "$host" "$file" "$listener" 1
        echo "}"
      elif [[ -n "$(kv_get "$file" PROVIDER)" ]];then
        die 'Provider HTTPS listener is missing its certificate.'
      fi
    done
  } > "$generated"

  # Imported sites use native server directives plus managed route records.
  # The preserved template is authoritative, not a second opaque conf overlay.
  if [[ -z "$(kv_get "$file" PROVIDER)" && -s "$DATA_DIR/imported/sites/$slug/template.conf" ]]; then
    /opt/liteedge/bin/render-imported.sh "$host" "$generated"
  fi

  # Disabled sites retain their configuration and certificates. NGINX responds
  # 503 for both HTTP and HTTPS until the site is enabled again.
  if [[ "$(kv_get "$file" ENABLED)" == 0 ]]; then
    # Exact, prefix, and regex locations must also return 503.
    awk '/^[[:space:]]*server_name[[:space:]]/ {print; print "    return 503;"; next}
         /^[[:space:]]*location[[:space:]].*\{[[:space:]]*$/ {print; print "        return 503;"; next}
         {print}' "$generated" > "$generated.disabled"
    mv "$generated.disabled" "$generated"
  fi

  record_generated_diff "$host" "$generated"
  if [[ -n "$(kv_get "$file" PROVIDER)" ]]; then
    cp "$generated" "$out"
  else
    merge_manual_delta "$host" "$generated" "$out"
  fi
done

python3 /opt/liteedge/bin/stream_routes.py render > "$stream_staged" || die 'Invalid transport configuration.'
if [[ -s "$stream_staged" ]];then
  "$NGINX_BIN" -V 2>&1 | grep -q -- '--with-stream_ssl_preread_module' || die 'NGINX stream support is not installed.'
fi
cp "$stream_staged" "$NGINX_DIR/streams.conf"
emit_route_limit_zones > "$zone_staged"
cp "$zone_staged" "$NGINX_DIR/route-limits.conf"

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
  if [[ -s "$pool_previous" ]]; then cp "$pool_previous" "$NGINX_DIR/upstreams.conf"; else rm -f "$NGINX_DIR/upstreams.conf"; fi
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