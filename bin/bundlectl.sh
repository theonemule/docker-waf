#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

cmd="${1:-}"
shift || true

BUNDLE_FORMAT="liteedge-site-bundle"
BUNDLE_VERSION="1"

usage() {
  cat >&2 <<'USAGE'
Usage:
  bundlectl.sh export-site HOST INCLUDE_CERTIFICATES OUTPUT
  bundlectl.sh export-all INCLUDE_CERTIFICATES OUTPUT
  bundlectl.sh import BUNDLE IMPORT_CERTIFICATES [EXPECTED_SCOPE] [EXPECTED_HOST]
USAGE
  exit 2
}

copy_if_file() {
  local source="$1" destination="$2"
  [[ -f "$source" ]] || return 0
  mkdir -p "$(dirname "$destination")"
  cp "$source" "$destination"
}

validate_known_site_for_bundle() {
  validate_host "$1"
  [[ -f "$(site_file "$1")" ]] || die "Unknown site: $1"
}

write_manifest() {
  local root="$1" scope="$2" include_certs="$3"
  cat > "$root/manifest" <<EOF
FORMAT=$BUNDLE_FORMAT
VERSION=$BUNDLE_VERSION
SCOPE=$scope
CERTIFICATES=$include_certs
EOF
}

export_one_site() {
  local host="$1" root="$2" include_certs="$3"
  local slug site routes waf baseline current certs
  validate_known_site_for_bundle "$host"
  slug="$(slug_for_host "$host")"
  site="$(site_file "$host")"
  routes="$(route_dir "$host")"
  waf="$(waf_rule_file "$host")"
  baseline="$(site_nginx_baseline "$host")"
  current="$(site_nginx_file "$host")"
  certs="$(cert_dir "$host")"

  mkdir -p "$root/sites" "$root/routes" "$root/waf" "$root/manual" "$root/certs"
  cp "$site" "$root/sites/$slug.site"
  site_root="$(kv_get "$site" ROOT)"
  if [[ -n "$site_root" && "$site_root" == "$DATA_DIR/"* ]]; then
    portable_root="${site_root#"$DATA_DIR/"}"
    sed -i "s#^ROOT=.*#ROOT=@DATA_DIR@/$portable_root#" "$root/sites/$slug.site"
  fi

  if [[ -d "$routes" ]]; then
    mkdir -p "$root/routes/$slug"
    cp -a "$routes/." "$root/routes/$slug/"
  fi
  copy_if_file "$waf" "$root/waf/$slug.waf-disabled"

  if [[ -s "$baseline" && -s "$current" ]] && ! cmp -s "$baseline" "$current"; then
    baseline_portable="$(mktemp)"
    current_portable="$(mktemp)"
    sed "s#$DATA_DIR#@DATA_DIR@#g" "$baseline" > "$baseline_portable"
    sed "s#$DATA_DIR#@DATA_DIR@#g" "$current" > "$current_portable"
    diff -u --label generated --label effective "$baseline_portable" "$current_portable" > "$root/manual/$slug.patch" || true
    rm -f "$baseline_portable" "$current_portable"
  fi

  if [[ "$include_certs" == 1 && -d "$certs" ]]; then
    mkdir -p "$root/certs/$slug"
    for name in fullchain.pem privkey.pem mode domains; do
      copy_if_file "$certs/$name" "$root/certs/$slug/$name"
    done
  fi
}

safe_archive() {
  local archive="$1" line type name
  [[ -s "$archive" ]] || die "Bundle is empty."
  tar -tzf "$archive" >/dev/null 2>&1 || die "Bundle is not a valid gzip-compressed tar archive."

  while IFS= read -r name; do
    [[ "$name" == liteedge-bundle || "$name" == liteedge-bundle/* ]] ||
      die "Bundle contains an unexpected path: $name"
    [[ "$name" != /* && "$name" != *"/../"* && "$name" != ../* && "$name" != *"/.." ]] ||
      die "Bundle contains an unsafe path: $name"
  done < <(tar -tzf "$archive")

  while IFS= read -r line; do
    type="${line:0:1}"
    case "$type" in
      -|d) ;;
      *) die "Bundle contains an unsupported filesystem object." ;;
    esac
  done < <(tar -tvzf "$archive")
}

materialize_portable_root() {
  local file="$1" root relative
  root="$(kv_get "$file" ROOT)"
  [[ "$root" == '@DATA_DIR@/'* ]] || return 0
  relative="${root#@DATA_DIR@/}"
  [[ "$relative" == www/* && "$relative" != *"/../"* && "$relative" != ../* && "$relative" != *"/.." ]] ||
    die "Invalid portable static root in bundle."
  sed -i "s#^ROOT=.*#ROOT=$DATA_DIR/$relative#" "$file"
}

validate_site_state_file() {
  local file="$1" expected_slug="$2"
  local host aliases slug mode upstream root force_https waf websocket
  host="$(kv_get "$file" HOST)"
  validate_host "$host"
  slug="$(slug_for_host "$host")"
  [[ "$slug" == "$expected_slug" ]] || die "Site filename does not match its host: $host"

  aliases="$(kv_get "$file" ALIASES)"
  validate_aliases "$aliases"

  # Backward compatibility for pre-route-model bundles.
  mode="$(kv_get "$file" MODE)"
  if [[ -n "$mode" ]]; then
    upstream="$(kv_get "$file" UPSTREAM)"
    root="$(kv_get "$file" ROOT)"
    force_https="$(kv_get "$file" FORCE_HTTPS)"
    waf="$(kv_get "$file" WAF)"
    websocket="$(kv_get "$file" WEBSOCKET)"
    validate_mode "$mode"
    [[ "$force_https" =~ ^[01]$ && "$waf" =~ ^[01]$ && "$websocket" =~ ^[01]$ ]] ||
      die "Invalid legacy boolean setting in bundle for $host."
    if [[ "$mode" == static ]]; then
      validate_root "$root"
    else
      validate_upstream "$upstream"
    fi
  fi

  printf '%s\n' "$host"
}

validate_routes_for_slug() {
  local root="$1" slug="$2" route id match path target websocket timeout waf force_https profile expected_id
  [[ -d "$root/routes/$slug" ]] || return 0
  shopt -s nullglob
  for route in "$root/routes/$slug"/*.route; do
    id="$(kv_get "$route" ID)"
    match="$(kv_get "$route" MATCH)"
    path="$(kv_get "$route" PATH)"
    target="$(kv_get "$route" TARGET)"
    websocket="$(kv_get "$route" WEBSOCKET)"
    timeout="$(kv_get "$route" TIMEOUT)"
    waf="$(kv_get "$route" WAF)"
    force_https="$(kv_get "$route" FORCE_HTTPS)"
    profile="$(kv_get "$route" PROFILE)"

    validate_route_match "$match"
    validate_route_path "$path"
    validate_upstream "$target"
    [[ -z "$websocket" || "$websocket" =~ ^[01]$ ]] || die "Invalid WebSocket route setting."
    [[ -z "$timeout" ]] || validate_timeout "$timeout"
    [[ -z "$waf" || "$waf" =~ ^[01]$ ]] || die "Invalid WAF route setting."
    [[ -z "$force_https" || "$force_https" =~ ^[01]$ ]] || die "Invalid HTTPS redirect route setting."
    [[ -z "$profile" ]] || validate_waf_profile "$profile"

    expected_id="$(printf '%s\n%s\n%s' "$match" "$path" "$target" | sha256sum | cut -c1-16)"
    [[ "$id" == "$expected_id" && "$(basename "$route")" == "$id.route" ]] ||
      die "Invalid route identifier in bundle."
  done
}

validate_waf_for_slug() {
  local root="$1" slug="$2" id
  [[ -f "$root/waf/$slug.waf-disabled" ]] || return 0
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    validate_rule_id "$id"
  done < "$root/waf/$slug.waf-disabled"
}

validate_certificate_for_site() {
  local root="$1" slug="$2" host="$3" site="$4"
  local cdir cert key cert_pub key_pub aliases alias
  cdir="$root/certs/$slug"
  [[ -d "$cdir" ]] || return 0
  cert="$cdir/fullchain.pem"
  key="$cdir/privkey.pem"
  [[ -s "$cert" && -s "$key" ]] || die "Certificate bundle for $host is incomplete."
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "Invalid certificate for $host."
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || die "Invalid private key for $host."

  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
  key_pub="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
  [[ "$cert_pub" == "$key_pub" ]] || die "Certificate and private key do not match for $host."

  openssl x509 -in "$cert" -noout -checkhost "$host" >/dev/null 2>&1 || die "Certificate does not cover $host."
  aliases="$(kv_get "$site" ALIASES)"
  for alias in $aliases; do
    openssl x509 -in "$cert" -noout -checkhost "$alias" >/dev/null 2>&1 || die "Certificate does not cover alias $alias."
  done
}

snapshot_import_state() {
  local backup="$1" name path pair
  mkdir -p "$backup"
  for pair in \
    "sites:$SITE_DIR" \
    "certs:$CERT_DIR" \
    "nginx-sites:$NGINX_SITE_DIR" \
    "nginx-baselines:$NGINX_BASELINE_DIR" \
    "nginx-diffs:$NGINX_DIFF_DIR" \
    "nginx-conflicts:$NGINX_CONFLICT_DIR"; do
    name="${pair%%:*}"
    path="${pair#*:}"
    mkdir -p "$backup/$name"
    [[ -d "$path" ]] && cp -a "$path/." "$backup/$name/" 2>/dev/null || true
  done
}

restore_import_state() {
  local backup="$1"
  rm -rf "$SITE_DIR" "$CERT_DIR" "$NGINX_SITE_DIR" "$NGINX_BASELINE_DIR" "$NGINX_DIFF_DIR" "$NGINX_CONFLICT_DIR"
  mkdir -p "$SITE_DIR" "$CERT_DIR" "$NGINX_SITE_DIR" "$NGINX_BASELINE_DIR" "$NGINX_DIFF_DIR" "$NGINX_CONFLICT_DIR"
  cp -a "$backup/sites/." "$SITE_DIR/" 2>/dev/null || true
  cp -a "$backup/certs/." "$CERT_DIR/" 2>/dev/null || true
  cp -a "$backup/nginx-sites/." "$NGINX_SITE_DIR/" 2>/dev/null || true
  cp -a "$backup/nginx-baselines/." "$NGINX_BASELINE_DIR/" 2>/dev/null || true
  cp -a "$backup/nginx-diffs/." "$NGINX_DIFF_DIR/" 2>/dev/null || true
  cp -a "$backup/nginx-conflicts/." "$NGINX_CONFLICT_DIR/" 2>/dev/null || true
  reload_nginx >/dev/null 2>&1 || true
}

import_bundle() {
  local archive="$1" import_certs="$2" expected_scope="${3:-}" expected_host="${4:-}"
  local tmp root manifest format version scope bundled_certs backup
  local site_file_path slug host patch_file current
  local -a hosts=()

  [[ -f "$archive" ]] || die "Bundle file is required."
  import_certs="$(bool_value "$import_certs")"
  safe_archive "$archive"

  tmp="$(mktemp -d)"
  backup="$(mktemp -d)"
  trap 'rm -rf "$tmp" "$backup"' EXIT
  tar -xzf "$archive" -C "$tmp"
  root="$tmp/liteedge-bundle"
  manifest="$root/manifest"
  [[ -f "$manifest" ]] || die "Bundle manifest is missing."

  format="$(kv_get "$manifest" FORMAT)"
  version="$(kv_get "$manifest" VERSION)"
  scope="$(kv_get "$manifest" SCOPE)"
  bundled_certs="$(kv_get "$manifest" CERTIFICATES)"
  [[ "$format" == "$BUNDLE_FORMAT" && "$version" == "$BUNDLE_VERSION" ]] || die "Unsupported LiteEdge bundle format."
  [[ "$scope" == site || "$scope" == all ]] || die "Invalid bundle scope."
  [[ "$bundled_certs" =~ ^[01]$ ]] || die "Invalid bundle certificate flag."
  [[ -z "$expected_scope" || "$scope" == "$expected_scope" ]] ||
    die "This import expects a $expected_scope bundle, but the selected bundle is $scope."

  shopt -s nullglob
  local site_files=("$root/sites"/*.site)
  [[ ${#site_files[@]} -gt 0 ]] || die "Bundle contains no sites."

  for site_file_path in "${site_files[@]}"; do
    materialize_portable_root "$site_file_path"
    slug="$(basename "$site_file_path" .site)"
    host="$(validate_site_state_file "$site_file_path" "$slug")"
    validate_routes_for_slug "$root" "$slug"
    validate_waf_for_slug "$root" "$slug"
    if [[ "$import_certs" == 1 && "$bundled_certs" == 1 ]]; then
      validate_certificate_for_site "$root" "$slug" "$host" "$site_file_path"
    fi
    [[ -z "$expected_host" || "$host" == "$expected_host" ]] ||
      die "This import expects site $expected_host, but the bundle contains $host."
    hosts+=("$host")
  done
  [[ "$scope" != site || ${#hosts[@]} -eq 1 ]] || die "A site bundle must contain exactly one site."

  snapshot_import_state "$backup"

  if [[ "$scope" == all ]]; then
    rm -rf "$SITE_DIR" "$NGINX_SITE_DIR" "$NGINX_BASELINE_DIR" "$NGINX_DIFF_DIR" "$NGINX_CONFLICT_DIR"
    mkdir -p "$SITE_DIR" "$NGINX_SITE_DIR" "$NGINX_BASELINE_DIR" "$NGINX_DIFF_DIR" "$NGINX_CONFLICT_DIR"
    if [[ "$import_certs" == 1 && "$bundled_certs" == 1 ]]; then
      find "$CERT_DIR" -mindepth 1 -maxdepth 1 ! -name _admin -exec rm -rf {} +
    fi
  fi

  for host in "${hosts[@]}"; do
    slug="$(slug_for_host "$host")"
    rm -f "$(site_file "$host")" "$(waf_rule_file "$host")" \
      "$(site_nginx_file "$host")" "$(site_nginx_baseline "$host")" \
      "$(site_nginx_diff "$host")" "$(site_nginx_conflict "$host")"
    rm -rf "$(route_dir "$host")"

    cp "$root/sites/$slug.site" "$(site_file "$host")"
    if [[ -d "$root/routes/$slug" ]]; then
      mkdir -p "$(route_dir "$host")"
      cp -a "$root/routes/$slug/." "$(route_dir "$host")/"
    fi
    copy_if_file "$root/waf/$slug.waf-disabled" "$(waf_rule_file "$host")"

    if [[ "$import_certs" == 1 && "$bundled_certs" == 1 && -d "$root/certs/$slug" ]]; then
      rm -rf "$(cert_dir "$host")"
      mkdir -p "$(cert_dir "$host")"
      for name in fullchain.pem privkey.pem mode domains; do
        copy_if_file "$root/certs/$slug/$name" "$(cert_dir "$host")/$name"
      done
      [[ -f "$(cert_dir "$host")/privkey.pem" ]] && chmod 600 "$(cert_dir "$host")/privkey.pem"
      [[ -f "$(cert_dir "$host")/fullchain.pem" ]] && chmod 644 "$(cert_dir "$host")/fullchain.pem"
    fi
  done

  if ! /opt/liteedge/bin/render-nginx.sh; then
    restore_import_state "$backup"
    die "Imported settings could not generate a valid NGINX configuration. The previous state was restored."
  fi

  for host in "${hosts[@]}"; do
    slug="$(slug_for_host "$host")"
    patch_file="$root/manual/$slug.patch"
    [[ -s "$patch_file" ]] || continue
    materialized_patch="$(mktemp)"
    sed "s#@DATA_DIR@#$DATA_DIR#g" "$patch_file" > "$materialized_patch"
    current="$(site_nginx_file "$host")"
    if ! patch --batch --silent --fuzz=0 "$current" < "$materialized_patch"; then
      rm -f "$materialized_patch"
      restore_import_state "$backup"
      die "The manual NGINX delta for $host could not be applied. The previous state was restored."
    fi
    rm -f "$materialized_patch"
  done

  if ! "$NGINX_BIN" -t -c "$NGINX_CONF"; then
    restore_import_state "$backup"
    die "Imported configuration failed NGINX validation. The previous state was restored."
  fi
  if ! reload_nginx; then
    restore_import_state "$backup"
    die "NGINX reload failed after import. The previous state was restored."
  fi

  rm -rf "$backup" "$tmp"
  trap - EXIT
  printf 'Imported %s site(s).\n' "${#hosts[@]}"
}

case "$cmd" in
  export-site)
    host="${1:-}"
    include_certs="$(bool_value "${2:-0}")"
    output="${3:-}"
    [[ -n "$host" && -n "$output" ]] || usage
    validate_known_site_for_bundle "$host"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    root="$tmp/liteedge-bundle"
    mkdir -p "$root"
    write_manifest "$root" site "$include_certs"
    export_one_site "$host" "$root" "$include_certs"
    tar -C "$tmp" -czf "$output" liteedge-bundle
    chmod 600 "$output"
    ;;

  export-all)
    include_certs="$(bool_value "${1:-0}")"
    output="${2:-}"
    [[ -n "$output" ]] || usage
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    root="$tmp/liteedge-bundle"
    mkdir -p "$root"
    write_manifest "$root" all "$include_certs"
    shopt -s nullglob
    files=("$SITE_DIR"/*.site)
    [[ ${#files[@]} -gt 0 ]] || die "There are no sites to export."
    for file in "${files[@]}"; do
      export_one_site "$(kv_get "$file" HOST)" "$root" "$include_certs"
    done
    tar -C "$tmp" -czf "$output" liteedge-bundle
    chmod 600 "$output"
    ;;

  import)
    import_bundle "${1:-}" "${2:-0}" "${3:-}" "${4:-}"
    ;;

  *)
    usage
    ;;
esac
