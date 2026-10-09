#!/usr/bin/env bash
# Compile an imported NGINX site from its preserved server directives and
# LiteEdge-managed route records. This replaces the old opaque conf overlay.
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh
host="${1:?site hostname required}"
output="${2:?output config required}"
slug="$(slug_for_host "$host")"
base="$DATA_DIR/imported/sites/$slug"
template="$base/template.conf"
[[ -s "$template" ]] || exit 0
shopt -s nullglob
declare -A route_keys=()
route_files=("$(route_dir "$host")"/*.route)
for file in "${route_files[@]}"; do
  [[ -f "$file" ]] || continue
  key="$(kv_get "$file" IMPORT_KEY)"
  [[ -n "$key" ]] || continue
  [[ "$key" =~ ^[a-f0-9]{16}$ ]] || die 'Bad imported route key.'
  route_keys[$key]="$file"
done

emit_route_snippet() {
  local file="$1" snippet="$2" action="$3" match="$4" path="$5" target="$6" waf="$7" key="$8"
  local original_target original_timeout timeout websocket modified_timeout route_id
  [[ -s "$snippet" ]] || die "Imported route snippet missing for $host."
  validate_route_match "$match"
  validate_route_path "$path"
  case "$action" in
    proxy) validate_upstream "$target" ;;
    custom) ;;
    *) die 'Invalid imported route action.' ;;
  esac
  # The preserved location body retains all original auth, rate-limit,
  # WebSocket, rewrite, timeout and nonproxy directives. Only managed fields
  # (location selector and proxy target) are substituted.
  original_target="$(kv_get "$file" IMPORT_ORIGINAL_TARGET)"
  original_timeout="$(kv_get "$file" IMPORT_ORIGINAL_TIMEOUT)"
  timeout="$(kv_get "$file" TIMEOUT)"
  websocket="$(kv_get "$file" WEBSOCKET)"
  validate_timeout "$timeout"
  route_id="$(printf '%s\n%s\n%s' "$match" "$path" "$target" | sha256sum | cut -c1-16)"
  modified_timeout=0
  [[ -z "$original_timeout" || "$timeout" == "$original_timeout" ]] || modified_timeout=1
  awk -v kind="$match" -v path="$path" -v target="$target" -v original="$original_target" -v action="$action" \
      -v waf="$waf" -v sslhost="$slug" -v rkey="$route_id" -v data="$DATA_DIR" \
      -v timeout="$timeout" -v newtimeout="$modified_timeout" -v websocket="$websocket" '
    BEGIN { first=1 }
    {
      if (first) {
        first=0
        prefix=""
        if (kind=="exact") prefix="= "
        else if (kind=="regex") prefix="~ "
        sub(/^([ \t]*)location.*$/, "    location " prefix path " {")
        print
        if (action=="proxy") {
          printf "        set $liteedge_route \"%s:%s\";\n", kind, path
          if (waf=="1") {
            print "        modsecurity on;"
            printf "        modsecurity_rules_file %s/nginx/waf-routes/%s-%s.conf;\n", data, sslhost, rkey
          }
        }
        next
      }
      if (action=="proxy" && websocket=="0" && $0 ~ /^[ \t]*proxy_set_header[ \t]+(Upgrade|Connection)[ \t]/) next
      if (action=="proxy" && newtimeout=="1" && $0 ~ /^[ \t]*proxy_(connect|send|read)_timeout[ \t]/) {
        if ($0 ~ /proxy_connect_timeout/) sub(/proxy_connect_timeout[ \t]+[0-9]+s;/, "proxy_connect_timeout " timeout "s;")
        if ($0 ~ /proxy_send_timeout/) sub(/proxy_send_timeout[ \t]+[0-9]+s;/, "proxy_send_timeout " timeout "s;")
        if ($0 ~ /proxy_read_timeout/) sub(/proxy_read_timeout[ \t]+[0-9]+s;/, "proxy_read_timeout " timeout "s;")
      }
      if (action=="proxy" && $0 ~ /^[ \t]*proxy_pass[ \t]/ && original != target) {
        sub(/proxy_pass[ \t]+[^;]+;/, "proxy_pass " target ";")
      }
      print
    }
  ' "$snippet"
}

emit_extra_route() {
  local file="$1" scheme="$2" match path target websocket timeout waf force_https id
  match="$(kv_get "$file" MATCH)"
  path="$(kv_get "$file" PATH)"
  target="$(kv_get "$file" TARGET)"
  websocket="$(kv_get "$file" WEBSOCKET)"
  timeout="$(kv_get "$file" TIMEOUT)"
  waf="$(kv_get "$file" WAF)"
  force_https="$(kv_get "$file" FORCE_HTTPS)"
  validate_route_match "$match"
  validate_route_path "$path"
  validate_upstream "$target"
  validate_timeout "$timeout"
  id="$(printf '%s\n%s\n%s' "$match" "$path" "$target" | sha256sum | cut -c1-16)"
  case "$match" in
    exact) printf '    location = %s {\n' "$path" ;;
    regex) printf '    location ~ %s {\n' "$path" ;;
    *) printf '    location ^~ %s {\n' "$path" ;;
  esac
  printf '        set $liteedge_route "%s:%s";\n' "$match" "$path"
  if [[ "$scheme" == http && "$force_https" == 1 ]]; then
    printf '        return 301 https://$host$request_uri;\n    }\n'
    return
  fi
  if [[ "$waf" == 1 ]]; then
    printf '        modsecurity on;\n'
    printf '        modsecurity_rules_file %s/nginx/waf-routes/%s-%s.conf;\n' "$DATA_DIR" "$slug" "$id"
  fi
  printf '        set $liteedge_route_%s "%s";\n' "$id" "$target"
  printf '        proxy_pass $liteedge_route_%s;\n' "$id"
  cat <<'CONF'
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
CONF
  printf '        proxy_connect_timeout %ss;\n        proxy_send_timeout %ss;\n        proxy_read_timeout %ss;\n' "$timeout" "$timeout" "$timeout"
  if [[ "$websocket" == 1 ]]; then
    printf '        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection $connection_upgrade;\n'
  fi
  echo '    }'
}

# Create output atomically, and preserve existing imported config on errors.
tmp="$(mktemp "$(dirname "$output")/.imported.XXXXXXXX")"
trap 'rm -f "$tmp"' EXIT
aliases="$(kv_get "$(site_file "$host")" ALIASES)"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^[[:space:]]*#[[:space:]]LITEEDGE_IMPORTED_LOCATION:([a-f0-9]{16})$ ]]; then
    key="${BASH_REMATCH[1]}"
    file="${route_keys[$key]:-}"
    [[ -z "$file" ]] && continue
    action="$(kv_get "$file" ACTION)"; [[ -n "$action" ]] || action=proxy
    match="$(kv_get "$file" MATCH)"
    path="$(kv_get "$file" PATH)"
    target="$(kv_get "$file" TARGET)"
    waf="$(kv_get "$file" WAF)"
    emit_route_snippet "$file" "$base/locations/$key.conf" "$action" "$match" "$path" "$target" "$waf" "$key" >> "$tmp"
  elif [[ "$line" =~ ^[[:space:]]*#[[:space:]]LITEEDGE_EXTRA_ROUTES:(http|https)$ ]]; then
    scheme="${BASH_REMATCH[1]}"
    for file in "${route_files[@]}"; do
      [[ -s "$file" ]] || continue
      [[ -z "$(kv_get "$file" IMPORT_KEY)" ]] || continue
      emit_extra_route "$file" "$scheme" >> "$tmp"
    done
  elif [[ "$line" =~ ^([[:space:]]*)server_name[[:space:]] ]]; then
    printf '%sserver_name %s %s;\n' "${BASH_REMATCH[1]}" "$host" "$aliases" >> "$tmp"
  else
    printf '%s\n' "$line" >> "$tmp"
  fi
done < "$template"
mv "$tmp" "$output"
trap - EXIT
