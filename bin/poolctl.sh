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
  local url="$1" re='^(http|https)://([A-Za-z0-9._-]+)(:([0-9]{1,5}))?(/[A-Za-z0-9._~/-]*)?$'
  [[ "$url" =~ $re ]] || die 'Backend pools require plain http://host:port URLs, with matching optional base paths.'
  POOL_SCHEME="${BASH_REMATCH[1]}"
  local default_port=80
  [[ "$POOL_SCHEME" == https ]] && default_port=443
  POOL_AUTHORITY="${BASH_REMATCH[2]}:${BASH_REMATCH[4]:-$default_port}"
  POOL_PATH="${BASH_REMATCH[5]:-}"
  local port="${BASH_REMATCH[4]:-$default_port}"
  (( 10#$port >= 1 && 10#$port <= 65535 )) || die 'Invalid backend port.'
}
pool_validate() {
  local primary="$1" extras="$2" mode="$3" max_fails="$4" fail_timeout="$5" value suffix="" count=0 verified="${6:-0}"
  [[ "$mode" == round_robin || "$mode" == least_conn || "$mode" == ip_hash || "$mode" == cookie ]] || die 'Invalid load balancing algorithm.'
  if ! [[ "$max_fails" =~ ^[0-9]+$ ]] || (( max_fails < 1 || max_fails > 20 )); then die 'Failure threshold must be 1-20.'; fi
  if ! [[ "$fail_timeout" =~ ^[0-9]+$ ]] || (( fail_timeout < 1 || fail_timeout > 3600 )); then die 'Failure window must be 1-3600 seconds.'; fi
  [[ "$extras" != *$'\n'* && "$extras" != *$'\r'* ]] || die 'Backend list must be comma-separated URLs.'
  IFS=',' read -r -a items <<< "$primary,$extras"
  for value in "${items[@]}"; do
    [[ -n "$value" ]] || die 'Empty backend URL.'
    pool_url_parts "$value"
    if [[ "$verified" == 1 ]];then [[ "$POOL_SCHEME" == https && -z "$POOL_PATH" ]] || die "Verified TLS pools require HTTPS origins."; else [[ "$POOL_SCHEME" == http ]] || die "HTTPS pools require verified backend TLS.";fi
    if (( count == 0 )); then suffix="$POOL_PATH"; else [[ "$POOL_PATH" == "$suffix" ]] || die 'All pool backends must have the same base path.'; fi
    count=$((count+1))
  done
  (( count <= 16 )) || die 'Backend pools support up to 16 endpoints.'
}
pool_effective_target() {
  local host="$1" file="$2" extras primary
  extras="$(kv_get "$file" BACKENDS)"
  primary="$(kv_get "$file" TARGET)"
  if [[ -z "$extras" && "$primary" != invalid && "$primary" != unavailable ]]; then printf '%s' "$primary"; return; fi
  if [[ "$(kv_get "$file" PROVIDER_ROUTE)" == 1 && ( "$primary" == invalid || "$primary" == unavailable || ",$extras," == *,invalid,* || ",$extras," == *,unavailable,* ) ]]; then
    printf 'http://%s' "$(pool_group "$host" "$file")"; return
  fi
  pool_url_parts "$primary"
  printf '%s://%s%s' "$POOL_SCHEME" "$(pool_group "$host" "$file")" "$POOL_PATH"
}
pool_render_upstreams() {
  local out="$1" site host route extras mode fails timeout value weights weight index
  local -a weight_items
  local managed invalid_pool have_invalid=0 have_unavailable=0 have_grpc_invalid=0
  printf '%s\n' '# Managed LiteEdge backend pools.' > "$out"
  for site in "$SITE_DIR"/*.site; do
    [[ -f "$site" ]] || continue
    host="$(kv_get "$site" HOST)"
    for route in "$(route_dir "$host")"/*.route; do
      [[ -f "$route" ]] || continue
      # Deadline routes balance in the private worker, not in NGINX.
      if [[ -n "$(kv_get "$route" GW_DEADLINES_B64)" || -n "$(kv_get "$route" GW_RETRY_B64)" || -n "$(kv_get "$route" GW_BACKEND_TLS_PEERS_B64)" ]];then
        local deadline_config
        deadline_config="$(python3 /opt/liteedge/bin/route_features.py deadline-config "$route")" || die 'Invalid deadline policy.'
        [[ -z "$deadline_config" ]] || continue
      fi
      extras="$(kv_get "$route" BACKENDS)"
      managed="$(kv_get "$route" PROVIDER_ROUTE)"
      invalid_pool=0
      if [[ "$managed" == 1 && ( "$(kv_get "$route" TARGET)" == invalid || ",$extras," == *,invalid,* ) ]]; then
        invalid_pool=1
        have_invalid=1
      fi
      if [[ "$managed" == 1 && ( "$(kv_get "$route" TARGET)" == unavailable || ",$extras," == *,unavailable,* ) ]];then
        invalid_pool=1;have_unavailable=1
      fi
      [[ -n "$extras" || "$invalid_pool" == 1 ]] || continue
      mode="$(kv_get "$route" LB_MODE)"; mode="${mode:-round_robin}"
      fails="$(kv_get "$route" MAX_FAILS)"; fails="${fails:-3}"
      timeout="$(kv_get "$route" FAIL_TIMEOUT)"; timeout="${timeout:-30}"
      if [[ "$invalid_pool" == 0 ]]; then
        local verified=0; [[ -n "$(kv_get "$route" GW_BACKEND_TLS_B64)" ]] && verified=1
        pool_validate "$(kv_get "$route" TARGET)" "$extras" "$mode" "$fails" "$timeout" "$verified"
      fi
      printf 'upstream %s {\n' "$(pool_group "$host" "$route")" >> "$out"
      # Share weighted balancing and passive failure state across workers.
      printf '    zone %s 64k;\n' "$(pool_group "$host" "$route")" >> "$out"
      case "$mode" in
        least_conn) printf '    least_conn;\n' >> "$out" ;;
        ip_hash) printf '    ip_hash;\n' >> "$out" ;;
        cookie) printf '    hash $liteedge_affinity_key consistent;\n' >> "$out" ;;
      esac
      weights="$(kv_get "$route" BACKEND_WEIGHTS)"
      weight_items=()
      if [[ -n "$weights" ]]; then
        IFS=',' read -r -a weight_items <<< "$weights"
        [[ "${#weight_items[@]}" == "$(pool_urls "$route" | wc -l | tr -d ' ')" ]] || die 'Invalid backend weight count.'
      fi
      index=0
      while IFS= read -r value; do
        if [[ "$invalid_pool" == 1 && ( "$value" == invalid || "$value" == unavailable ) && "$(kv_get "$route" GW_GRPC)" == 1 ]];then
          POOL_AUTHORITY="unix:${LITEEDGE_RUN_DIR:-/tmp/liteedge-run}/grpc-invalid.sock";have_grpc_invalid=1
        elif [[ "$invalid_pool" == 1 && "$value" == invalid ]]; then POOL_AUTHORITY="unix:${LITEEDGE_RUN_DIR:-/tmp/liteedge-run}/invalid-backend.sock"
        elif [[ "$invalid_pool" == 1 && "$value" == unavailable ]];then POOL_AUTHORITY="unix:${LITEEDGE_RUN_DIR:-/tmp/liteedge-run}/unavailable-backend.sock"
        else pool_url_parts "$value"; fi
        weight="${weight_items[$index]:-1}"
        [[ "$weight" =~ ^[1-9][0-9]{0,6}$ ]] && (( weight <= 1000000 )) || die 'Invalid backend weight.'
        if [[ -n "$weights" ]]; then
          printf '    server %s weight=%s max_fails=%s fail_timeout=%ss;\n' "$POOL_AUTHORITY" "$weight" "$fails" "$timeout" >> "$out"
        else
          printf '    server %s max_fails=%s fail_timeout=%ss;\n' "$POOL_AUTHORITY" "$fails" "$timeout" >> "$out"
        fi
        index=$((index+1))
      done < <(pool_urls "$route")
      printf '}\n' >> "$out"
    done
  done
  if [[ "$have_grpc_invalid" == 1 ]];then
    printf 'server { listen unix:%s/grpc-invalid.sock; http2 on; location / { default_type application/grpc; add_header grpc-status 14 always; return 200 ""; } }\n' "${LITEEDGE_RUN_DIR:-/tmp/liteedge-run}" >> "$out"
  fi
  if [[ "$have_unavailable" == 1 ]];then
    printf 'server { listen unix:%s/unavailable-backend.sock; location / { return 503; } }\n' "${LITEEDGE_RUN_DIR:-/tmp/liteedge-run}" >> "$out"
  fi
  if [[ "$have_invalid" == 1 ]]; then
    printf 'server { listen unix:%s/invalid-backend.sock; location / { return 500; } }\n' "${LITEEDGE_RUN_DIR:-/tmp/liteedge-run}" >> "$out"
  fi
}
