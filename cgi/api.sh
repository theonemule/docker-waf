#!/usr/bin/env bash
# JSON API for the standalone LiteEdge browser application. Basic authentication
# is enforced independently by NGINX for every request, including read calls.
api_headers() {
  local code="${1:-200}"
  printf 'Status: %s\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n' "$code"
}
api_success() {
  api_headers 200
  printf '%s\n' "${1:-'{\"ok\":true}'}"
  exit 0
}
api_failure() {
  local code="${1:-400}" message="${2:-Request failed}"
  api_headers "$code"
  jq -cn --arg message "$message" '{ok:false,error:$message}'
  exit 0
}
api_json_file() {
  local file="$1"
  if [[ -s "$file" ]]; then cat "$file"; else printf '{}\n'; fi
}
api_route_json() {
  local file="$1" key value out='{}'
  for key in ID MATCH PATH TARGET BACKENDS ACTION WEBSOCKET TIMEOUT WAF FORCE_HTTPS WAF_PL WAF_PLUGINS WAF_DISABLED LB_MODE MAX_FAILS FAIL_TIMEOUT HEALTH_ENABLED HEALTH_PATH HEALTH_EXPECT HEALTH_INTERVAL HEALTH_TIMEOUT HEALTH_FALL HEALTH_RISE HEALTH_COOLDOWN; do
    value="$(kv_get "$file" "$key")"
    out="$(jq -cn --argjson obj "$out" --arg key "${key,,}" --arg value "$value" '$obj + {($key):$value}')"
  done
  printf '%s\n' "$out"
}
api_site_json() {
  local file="$1" host aliases enabled mode
  host="$(kv_get "$file" HOST)"
  aliases="$(kv_get "$file" ALIASES)"
  enabled="$(kv_get "$file" ENABLED)"
  [[ "$enabled" == 0 ]] || enabled=1
  mode="$(cert_mode "$host")"
  local cert_email=""
  [[ -f "$(cert_dir "$host")/acme-email" ]] && cert_email="$(head -n1 "$(cert_dir "$host")/acme-email")"
  [[ -n "$cert_email" ]] || cert_email="${ACME_EMAIL:-}"
  local routes='[]' route
  shopt -s nullglob
  for route in "$(route_dir "$host")"/*.route; do
    routes="$(jq -cn --argjson arr "$routes" --argjson element "$(api_route_json "$route")" '$arr+[$element]')"
  done
  jq -cn --arg host "$host" --arg aliases "$aliases" --argjson enabled "$enabled" \
    --arg tls "$mode" --arg cert_email "$cert_email" --argjson routes "$routes" \
    '{host:$host,aliases:$aliases,enabled:($enabled==1),tls:$tls,cert_email:$cert_email,routes:$routes,route_count:($routes|length)}'
}
api_site_detail() {
  local host="${PARAM[host]:-}" file base
  [[ -n "$host" ]] || api_failure 400 'Specify a hostname.'
  validate_host "$host" 2>/dev/null || api_failure 400 'Invalid hostname.'
  file="$(site_file "$host")"
  [[ -s "$file" ]] || api_failure 404 'Site not found.'
  base="$(api_site_json "$file")"
  local configuration="" baseline="" conflict="" delta="" disabled=''
  [[ -f "$(site_nginx_file "$host")" ]] && configuration="$(cat "$(site_nginx_file "$host")")"
  [[ -f "$(site_nginx_baseline "$host")" ]] && baseline="$(cat "$(site_nginx_baseline "$host")")"
  [[ -f "$(site_nginx_conflict "$host")" ]] && conflict="$(cat "$(site_nginx_conflict "$host")")"
  [[ -f "$(site_nginx_diff "$host")" ]] && delta="$(cat "$(site_nginx_diff "$host")")"
  disabled="$(disabled_waf_rules "$host" 2>/dev/null || true)"
  api_headers
  jq -cn --argjson site "$base" --arg configuration "$configuration" --arg baseline "$baseline" \
    --arg conflict "$conflict" --arg delta "$delta" --arg disabled "$disabled" \
    '{ok:true,site:($site+{configuration:$configuration,baseline:$baseline,conflict:$conflict,delta:$delta,disabled_rules:($disabled|split("\n")|map(select(length>0)))})}'
}
api_sites() {
  local sites='[]' site
  shopt -s nullglob
  for site in "$SITE_DIR"/*.site; do
    sites="$(jq -cn --argjson arr "$sites" --argjson item "$(api_site_json "$site")" '$arr+[$item]')"
  done
  jq -cn --argjson sites "$sites" '{ok:true,sites:($sites|sort_by(.host))}'
}
api_server() {
  local keys='{}' key v
  for key in WORKER_CONNECTIONS KEEPALIVE_TIMEOUT CLIENT_HEADER_TIMEOUT CLIENT_BODY_TIMEOUT SEND_TIMEOUT DEFAULT_ROUTE_TIMEOUT RESOLVER; do
    case "$key" in
      WORKER_CONNECTIONS) v="$(server_setting_get "$key" 1024)" ;;
      KEEPALIVE_TIMEOUT) v="$(server_setting_get "$key" 65)" ;;
      CLIENT_HEADER_TIMEOUT|CLIENT_BODY_TIMEOUT) v="$(server_setting_get "$key" 15)" ;;
      SEND_TIMEOUT) v="$(server_setting_get "$key" 30)" ;;
      DEFAULT_ROUTE_TIMEOUT) v="$(server_setting_get "$key" 60)" ;;
      *) v="$(server_setting_get "$key" "")" ;;
    esac
    keys="$(jq -cn --argjson old "$keys" --arg key "${key,,}" --arg v "$v" '$old+{($key):$v}')"
  done
  local collector
  collector="$(/opt/liteedge/bin/obsctl.sh collector)"
  jq -cn --argjson settings "$keys" --argjson collector "$collector" '{ok:true,settings:$settings,collector:$collector}'
}
api_alerts() {
  local rules catalog
  rules="$(/opt/liteedge/bin/obsctl.sh alerts)"
  catalog="$(/opt/liteedge/bin/alert-catalog.sh)"
  jq -cn --argjson rules "$rules" --argjson catalog "$catalog" '{ok:true,rules:$rules,catalog:$catalog}'
}
api_owasp() {
  local pl crs_status installed='[]' custom='[]' disabled='[]' file name kind category _repo _status configs='[]' config
  /opt/liteedge/bin/wafregistry.sh ensure >/dev/null 2>&1 || true
  pl="$(waf_setting_get PARANOIA_LEVEL 1)"
  crs_status="$(/opt/liteedge/bin/crsctl.sh status 2>/dev/null || true)"
  while IFS=$'\t' read -r name _repo kind _status category; do
    [[ -n "$name" ]] || continue
    installed="$(jq -cn --argjson list "$installed" --arg name "$name" --arg category "$category" --arg kind "$kind" '$list+[{name:$name,category:$category,kind:$kind}]')"
  done < <(installed_plugin_rows 2>/dev/null || true)
  shopt -s nullglob
  for file in "$WAF_CUSTOM_DIR"/*.conf "$WAF_CUSTOM_DIR"/*.conf.disabled; do
    name="$(basename "$file")"
    local rule_id="${name%%.conf*}" state=enabled
    [[ "$name" == *.disabled ]] && state=disabled
    custom="$(jq -cn --argjson list "$custom" --arg id "$rule_id" --arg state "$state" --arg content "$(cat "$file")" '$list+[{id:$id,state:$state,content:$content}]')"
  done
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    disabled="$(jq -cn --argjson list "$disabled" --arg id "$id" '$list+[$id]')"
  done < <(global_disabled_waf_rules 2>/dev/null || true)
  for file in "$WAF_PLUGIN_DIR"/*/plugins/*-config.conf; do
    [[ -f "$file" ]] || continue
    name="$(basename "$(dirname "$(dirname "$file")")")"
    config="$(basename "$file")"
    configs="$(jq -cn --argjson arr "$configs" --arg plugin "$name" --arg file "$config" --arg content "$(cat "$file")" '$arr+[{plugin:$plugin,file:$file,content:$content}]')"
  done
  local registry='[]'
  if [[ -s "$WAF_REGISTRY_FILE" ]]; then
    registry="$(awk -F '\t' 'NR>1 {printf "%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,$4,$5}' "$WAF_REGISTRY_FILE" | jq -Rn '[inputs | split("\t") | select(length>=5)|{name:.[0],repo:.[1],type:.[2],status:.[3],category:.[4]}]')"
  fi
  jq -cn --arg pl "$pl" --arg crs "$crs_status" --argjson installed "$installed" \
    --argjson custom "$custom" --argjson disabled "$disabled" --argjson registry "$registry" --argjson configs "$configs" \
    '{ok:true,pl:$pl,crs:($crs|split("\n")|map(select(length>0)|split("="))|map({key:.[0],value:(.[1:]|join("="))})|from_entries),installed:$installed,custom:$custom,disabled:$disabled,registry:$registry,plugin_configs:$configs}'
}
# Query the upstream release metadata and cache its version only. This
# command never downloads a CRS archive, installs rules, or reloads NGINX.
api_crs_check() {
  local result
  if ! result="$(/opt/liteedge/bin/crsctl.sh check 2>/dev/null)"; then
    api_failure 502 'Unable to check the OWASP CRS release feed. Please retry.'
  fi
  api_headers
  printf '%s
' "$result" | jq -Rn '
    [inputs | select(length>0) | capture("^(?<key>[^=]+)=(?<value>.*)$")] |
    reduce .[] as $item ({}; .[$item.key]=$item.value) |
    {ok:true,crs:.}'
}
api_crs_rules() {
  crs_rule_rows | jq -Rn '{ok:true,rules:[inputs | split("\t") | select(length>=4) |
    {id:.[0],source:.[1],pl:.[2],message:.[3]}]}'
}
api_logs() {
  local kind="${PARAM[type]:-all}" host="${PARAM[host]:-}" route="${PARAM[route]:-}"
  local port="${PARAM[port]:-}" method="${PARAM[method]:-}" status="${PARAM[status]:-}"
  local search="${PARAM[search]:-}" limit="${PARAM[limit]:-100}" since="${PARAM[since]:-0}" scopes="${PARAM[scopes_json]:-}"
  log_has_filter || api_failure 400 'Choose at least one log filter before searching.'
  local output
  if ! output="$(/opt/liteedge/bin/obsctl.sh query "$kind" "$host" "$route" "$port" "$method" "$status" "$search" "$limit" "$since" "$scopes" 2>&1)"; then
    api_failure 400 "$output"
  fi
  api_headers
  printf '%s\n' "$output" | jq -sc '{ok:true,events:.}'
}
api_full_backup_export() {
  local temp filename
  temp="$(mktemp -d "$DATA_DIR/.liteedge-backup-export.XXXXXXXX")" || api_failure 500 'Unable to stage backup.'
  chmod 700 "$temp"
  filename="liteedge-full-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  if ! /opt/liteedge/bin/backupctl.py backup "$temp/$filename" > "$temp/result.json" 2> "$temp/error"; then
    rm -rf "$temp"
    api_failure 500 'Unable to create full backup.'
  fi
  printf 'Content-Type: application/gzip\r\n'
  printf 'Content-Disposition: attachment; filename="%s"\r\n' "$filename"
  printf 'Content-Length: %s\r\n' "$(wc -c < "$temp/$filename" | tr -d ' ')"
  printf 'Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'
  cat "$temp/$filename"
  rm -rf "$temp"
  exit 0
}
api_full_backup_restore() {
  local length="${CONTENT_LENGTH:-0}" temp result error
  [[ "$length" =~ ^[0-9]+$ ]] || api_failure 400 'Invalid Content-Length.'
  (( length > 0 && length <= 268435456 )) || api_failure 413 'Backup must be no larger than 256 MiB.'
  temp="$(mktemp -d "$DATA_DIR/.liteedge-backup-upload.XXXXXXXX")" || api_failure 500 'Unable to stage upload.'
  chmod 700 "$temp"
  head -c "$length" > "$temp/archive.tar.gz"
  if [[ "$(wc -c < "$temp/archive.tar.gz" | tr -d ' ')" != "$length" ]]; then
    rm -rf "$temp"
    api_failure 400 'Incomplete backup upload.'
  fi
  if ! result="$(/opt/liteedge/bin/backupctl.py restore "$temp/archive.tar.gz" 2> "$temp/error")"; then
    error="$(head -c 600 "$temp/error")"
    rm -rf "$temp"
    api_failure 400 "Restore failed: $error"
  fi
  rm -rf "$temp"
  api_success "$result"
}
api_authz_mutation() {
  [[ "${HTTP_X_LITEEDGE_API:-}" == 1 ]] || api_failure 403 'Mutation requires X-LiteEdge-API: 1.'
  case "${HTTP_SEC_FETCH_SITE:-same-origin}" in same-origin|none) ;; *) api_failure 403 'Cross-site mutation denied.' ;; esac
  if [[ -n "${HTTP_ORIGIN:-}" ]]; then
    local origin="$HTTP_ORIGIN" expected="https://${HTTP_HOST:-}"
    [[ "$origin" == "$expected" || "$origin" == "http://${HTTP_HOST:-}" ]] || api_failure 403 'Cross-origin mutation denied.'
  fi
}
# Translate the existing binary import handlers' plain-text HTTP output into
# a stable JSON result. Each handler runs in a subshell so its exit cannot
# bypass the versioned API response contract; stdin streams the raw archive.
api_import_json() {
  local importer="$1" result body status=200
  if ! result="$("$importer")"; then
    api_failure 500 'Import handler failed unexpectedly.'
  fi
  local first_line="${result%%$'\r\n'*}"
  if [[ "$first_line" =~ ^Status:[[:space:]]([0-9]{3}) ]]; then
    status="${BASH_REMATCH[1]}"
  fi
  if [[ "$result" == *$'\r\n\r\n'* ]]; then
    body="${result#*$'\r\n\r\n'}"
  else
    api_failure 500 'Import handler did not provide an HTTP response.'
  fi
  if [[ "$status" == 200 ]]; then
    api_headers 200
    jq -cn --arg message "$body" '{ok:true,message:$message}'
  else
    api_failure "$status" "$body"
  fi
}
api_entry() {
  local endpoint="${1:-}" method="${REQUEST_METHOD:-GET}"
  # Reuse the validated command handlers but replace HTML/redirect semantics
  # with JSON statuses. Clients never parse HTML or follow mutation redirects.
  # Called dynamically by the sourced legacy handler, rather than in this file.
  # shellcheck disable=SC2317,SC2329
  error_page() { api_failure 400 "$1"; }
  # shellcheck disable=SC2317,SC2329
  redirect() { api_success '{"ok":true}'; }
  case "$endpoint" in
    /api/v1/sites|/api/v1/site|/api/v1/server|/api/v1/alerts|/api/v1/owasp|/api/v1/catalog|/api/v1/logs|/api/v1/owasp/rules|/api/v1/owasp/crs/check)
      [[ "$method" == GET ]] || api_failure 405 'GET required.'
      case "$endpoint" in
        /api/v1/sites) api_headers; api_sites ;;
        /api/v1/site) api_site_detail ;;
        /api/v1/server) api_headers; api_server ;;
        /api/v1/alerts) api_headers; api_alerts ;;
        /api/v1/owasp) api_headers; api_owasp ;;
        /api/v1/owasp/rules) api_headers; api_crs_rules ;;
        /api/v1/owasp/crs/check) api_crs_check ;;
        /api/v1/catalog) api_headers; /opt/liteedge/bin/alert-catalog.sh ;;
        /api/v1/logs) api_logs ;;
      esac
      ;;
    /api/v1/actions/*)
      [[ "$method" == POST ]] || api_failure 405 'POST required.'
      api_authz_mutation
      # Read by the sourced admin.sh password-change handler.
      # shellcheck disable=SC2034
      API_MODE=1
      handle_post "/admin/${endpoint#/api/v1/actions/}"
      api_failure 500 'Handler returned without an API result.'
      ;;
    /api/v1/backup/export)
      [[ "$method" == GET ]] || api_failure 405 'GET required.'
      api_full_backup_export ;;
    /api/v1/backup/restore)
      [[ "$method" == POST ]] || api_failure 405 'POST required.'
      api_authz_mutation
      api_full_backup_restore ;;
    /api/v1/export)
      [[ "$method" == GET ]] || api_failure 405 'GET required.'
      handle_export ;;
    /api/v1/logs/export)
      [[ "$method" == GET ]] || api_failure 405 'GET required.'
      logs_export ;;
    /api/v1/owasp/export)
      [[ "$method" == GET ]] || api_failure 405 'GET required.'
      handle_owasp_export ;;
    /api/v1/import|/api/v1/owasp/import|/api/v1/owasp/crs/import)
      [[ "$method" == POST ]] || api_failure 405 'POST required.'
      api_authz_mutation
      case "$endpoint" in
        /api/v1/import) api_import_json handle_raw_import ;;
        /api/v1/owasp/import) api_import_json handle_owasp_raw_import ;;
        /api/v1/owasp/crs/import) api_import_json handle_crs_raw_import ;;
      esac
      ;;
    *) api_failure 404 'Unknown API resource.' ;;
  esac
}
