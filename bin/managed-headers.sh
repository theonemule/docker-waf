#!/usr/bin/env bash
# Managed request-header transformations. The provider validates all literals.
managed_header_var() {
  printf 'liteedge_hdr_%s' "$(printf '%s/%s/%s' "$1" "$2" "$3" | sha256sum | cut -c1-24)"
}
managed_header_rows() {
  local blob="$1" decoded
  [[ -n "$blob" ]] || return 0
  decoded="$(printf '%s' "$blob" | base64 -d)" || die 'Invalid managed headers'
  jq -r '.[] | [.op,.name,.value] | @tsv' <<< "$decoded"
}
emit_managed_header_maps() {
  local site host route blob rows op name value input var id
  for site in "$SITE_DIR"/*.site; do
    [[ -f "$site" ]] || continue
    host="$(kv_get "$site" HOST)"
    for route in "$(route_dir "$host")"/*.route; do
      [[ -f "$route" ]] || continue
      [[ "$(kv_get "$route" PROVIDER_ROUTE)" == 1 || "$(kv_get "$route" TYPED_ROUTE)" == 1 ]] || continue
      blob="$(kv_get "$route" GW_HEADERS_B64)"
      [[ -n "$blob" ]] || continue
      rows="$(managed_header_rows "$blob")"
      id="$(kv_get "$route" ID)"
      while IFS=$'\t' read -r op name value; do
        [[ "$op" == add ]] || continue
        input="${name//-/_}"
        var="$(managed_header_var "$host" "$id" "$name")"
        printf 'map $http_%s $%s { "" "%s"; default "$http_%s,%s"; }\n' "$input" "$var" "$value" "$input" "$value"
      done <<< "$rows"
    done
  done
}
emit_managed_headers() {
  local host="$1" id="$2" blob="$3" rows op name value variable
  [[ -n "$blob" ]] || return 0
  rows="$(managed_header_rows "$blob")"
  while IFS=$'\t' read -r op name value; do
    case "$op" in
      set) printf '        proxy_set_header %s "%s";\n' "$name" "$value" ;;
      remove) printf '        proxy_set_header %s "";\n' "$name" ;;
      add) variable="$(managed_header_var "$host" "$id" "$name")"
        printf '        proxy_set_header %s $%s;\n' "$name" "$variable" ;;
      *) die 'Invalid managed header operation' ;;
    esac
  done <<< "$rows"
}

# NGINX proxy_hide_header removes upstream instances; add_header appends
# a separate field. Explicitly preserve server security-header inheritance
# when any location-level add_header is emitted (also for affinity cookies).
emit_response_headers() {
  local blob="$1" scheme="$2" cookie="$3" rows op name value
  if [[ -z "$blob" && "$cookie" != 1 ]]; then return 0; fi
  if [[ -n "$blob" ]]; then rows="$(managed_header_rows "$blob")"; else rows=""; fi
  # Adding a header at location scope replaces all inherited add_header
  # directives on older NGINX versions. Preserve the appliance baseline.
  if [[ "$cookie" == 1 ]] || grep -Eq '^(set|add)[[:space:]]' <<< "$rows"; then
    sed -n 's/^add_header /        add_header /p' /opt/liteedge/etc/nginx/security.conf
    if [[ "$scheme" == https ]]; then echo '        add_header Strict-Transport-Security "max-age=31536000" always;'; fi
  fi
  while IFS=$'\t' read -r op name value; do
    [[ -n "$op" ]] || continue
    case "$op" in
      set) printf '        proxy_hide_header %s;\n        add_header %s "%s" always;\n' "$name" "$name" "$value";;
      add) printf '        add_header %s "%s" always;\n' "$name" "$value";;
      remove) printf '        proxy_hide_header %s;\n' "$name";;
      *) die 'Invalid response header operation';;
    esac
  done <<< "$rows"
}
