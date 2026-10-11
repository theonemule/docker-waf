#!/usr/bin/env bash
# Shell functions shared by site renderer and imported site renderer.
# Requires bin/common.sh to be sourced first.
pool_group() {
  local host="$1" file="$2" id
  id="$(kv_get "$file" ID)"
  printf 'liteedge_lb_%s' "$(printf '%s/%s' "$host" "$id" | sha256sum | cut -c1-16)"
}
pool_urls() {
  local file="$1" primary extras
  primary="$(kv_get "$file" TARGET)"
  printf '%s\n' "$primary"
  extras="$(kv_get "$file" BACKENDS)"
  if [[ -n "$extras" ]]; then
    tr ',' '\n' <<< "$extras" | sed '/^$/d'
  fi
}
pool_url_parts() {
  local url="$1" re='^http://([A-Za-z0-9._-]+)(:([0-9]{1,5}))?(/[A-Za-z0-9._~/-]*)?$'
  [[ "$url" =~ $re ]] || die 'Backend pools require plain http://host:port URLs, with matching optional base paths.'
  POOL_AUTHORITY="${BASH_REMATCH[1]}:${BASH_REMATCH[3]:-80}"
  POOL_PATH="${BASH_REMATCH[4]:-}"
  local port="${BASH_REMATCH[3]:-80}"
  (( 10#$port >= 1 && 10#$port <= 65535 )) || die 'Invalid backend port.'
}
pool_validate() {
  local primary="$1" extras="$2" mode="$3" max_fails="$4" fail_timeout="$5" value suffix="" count=0
  [[ "$mode" == round_robin || "$mode" == least_conn || "$mode" == ip_hash || "$mode" == cookie ]] || die 'Invalid load balancing algorithm.'
  if ! [[ "$max_fails" =~ ^[0-9]+$ ]] || (( max_fails < 1 || max_fails > 20 )); then die 'Failure threshold must be 1-20.'; fi
  if ! [[ "$fail_timeout" =~ ^[0-9]+$ ]] || (( fail_timeout < 1 || fail_timeout > 3600 )); then die 'Failure window must be 1-3600 seconds.'; fi
  [[ "$extras" != *$'\n'* && "$extras" != *$'\r'* ]] || die 'Backend list must be comma-separated URLs.'
  IFS=',' read -r -a items <<< "$primary,$extras"
  for value in "${items[@]}"; do
    [[ -n "$value" ]] || die 'Empty backend URL.'
    pool_url_parts "$value"
    if (( count == 0 )); then suffix="$POOL_PATH"; else [[ "$POOL_PATH" == "$suffix" ]] || die 'All pool backends must have the same base path.'; fi
    count=$((count+1))
  done
  (( count <= 16 )) || die 'Backend pools support up to 16 endpoints.'
}
pool_effective_target() {
  local host="$1" file="$2" extras primary
  extras="$(kv_get "$file" BACKENDS)"
  primary="$(kv_get "$file" TARGET)"
  if [[ -z "$extras" ]]; then printf '%s' "$primary"; return; fi
  pool_url_parts "$primary"
  printf 'http://%s%s' "$(pool_group "$host" "$file")" "$POOL_PATH"
}
pool_render_upstreams() {
  local out="$1" site host route extras mode fails timeout value
  printf '%s\n' '# Managed LiteEdge backend pools.' > "$out"
  for site in "$SITE_DIR"/*.site; do
    [[ -f "$site" ]] || continue
    host="$(kv_get "$site" HOST)"
    for route in "$(route_dir "$host")"/*.route; do
      [[ -f "$route" ]] || continue
      extras="$(kv_get "$route" BACKENDS)"
      [[ -n "$extras" ]] || continue
      mode="$(kv_get "$route" LB_MODE)"; mode="${mode:-round_robin}"
      fails="$(kv_get "$route" MAX_FAILS)"; fails="${fails:-3}"
      timeout="$(kv_get "$route" FAIL_TIMEOUT)"; timeout="${timeout:-30}"
      pool_validate "$(kv_get "$route" TARGET)" "$extras" "$mode" "$fails" "$timeout"
      printf 'upstream %s {\n' "$(pool_group "$host" "$route")" >> "$out"
      case "$mode" in
        least_conn) printf '    least_conn;\n' >> "$out" ;;
        ip_hash) printf '    ip_hash;\n' >> "$out" ;;
        cookie) printf '    hash $liteedge_affinity_key consistent;\n' >> "$out" ;;
      esac
      while IFS= read -r value; do
        pool_url_parts "$value"
        printf '    server %s max_fails=%s fail_timeout=%ss;\n' "$POOL_AUTHORITY" "$fails" "$timeout" >> "$out"
      done < <(pool_urls "$route")
      printf '}\n' >> "$out"
    done
  done
}
