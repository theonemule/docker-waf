#!/usr/bin/env bash
# Inventory of hostnames, aliases and route patterns. No site secrets are returned.
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh
shopt -s nullglob
hosts_tmp="$(mktemp)"
routes_tmp="$(mktemp)"
trap 'rm -f "$hosts_tmp" "$routes_tmp"' EXIT
for site_file_path in "$SITE_DIR"/*.site; do
  primary="$(kv_get "$site_file_path" HOST)"
  [[ -n "$primary" ]] || continue
  jq -cn --arg name "$primary" --arg site "$primary" --arg kind site '{name:$name,site:$site,kind:$kind}' >> "$hosts_tmp"
  aliases="$(kv_get "$site_file_path" ALIASES)"
  aliases="${aliases//,/ }"
  for alias in $aliases; do
    [[ "$alias" != "$primary" ]] || continue
    jq -cn --arg name "$alias" --arg site "$primary" --arg kind alias '{name:$name,site:$site,kind:$kind}' >> "$hosts_tmp"
  done
  for route_file_path in "$(route_dir "$primary")"/*.route; do
    match="$(kv_get "$route_file_path" MATCH)"
    path="$(kv_get "$route_file_path" PATH)"
    [[ "$match" == prefix || "$match" == exact || "$match" == regex ]] || continue
    [[ "$path" == /* ]] || continue
    jq -cn --arg site "$primary" --arg route "$match:$path" '{site:$site,route:$route}' >> "$routes_tmp"
  done
  migrated="$DATA_DIR/migration/sites/$(slug_for_host "$primary").conf"
  if [[ -f "$migrated" ]]; then
    while IFS= read -r route; do
      [[ -n "$route" ]] || continue
      jq -cn --arg site "$primary" --arg route "$route" '{site:$site,route:$route}' >> "$routes_tmp"
    done < <(awk '
      $1 == "location" {
        if ($2 == "=") print "exact:" $3
        else if ($2 == "^~") print "prefix:" $3
        else if ($2 == "~" || $2 == "~*") print "regex:" $3
        else print "prefix:" $2
      }' "$migrated")
  fi
done
jq -sn --slurpfile hosts "$hosts_tmp" --slurpfile routes "$routes_tmp" \
  '{hosts:($hosts | unique_by([.site,.name]) | sort_by(.site,.kind,.name)), routes:($routes | unique_by([.site,.route]) | sort_by(.site,.route))}'
