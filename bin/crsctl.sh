#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

RELEASE_API_URL="${LITEEDGE_CRS_RELEASE_API_URL:-https://api.github.com/repos/coreruleset/coreruleset/releases/latest}"
CHECK_MAX_AGE="${LITEEDGE_CRS_CHECK_MAX_AGE:-21600}"

validate_version() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid CRS version."
}

version_gt() {
  local a="$1" b="$2" first
  validate_version "$a"
  validate_version "$b"
  [[ "$a" != "$b" ]] || return 1
  first="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)"
  [[ "$first" == "$a" ]]
}

current_version() {
  active_crs_version
}

write_update_status() {
  local checked="$1" latest="$2" tag="$3" url="$4"
  cat > "$WAF_CRS_UPDATE_FILE.tmp" <<EOF
CHECKED_AT=$checked
LATEST_VERSION=$latest
TAG=$tag
DOWNLOAD_URL=$url
EOF
  chmod 0600 "$WAF_CRS_UPDATE_FILE.tmp"
  mv "$WAF_CRS_UPDATE_FILE.tmp" "$WAF_CRS_UPDATE_FILE"
}

check_update() {
  local raw latest tag url checked
  raw="$(mktemp)"
  trap 'rm -f "${raw:-}"' RETURN
  curl -fsSL --connect-timeout 5 --max-time 15 --proto '=https' --tlsv1.2 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: LiteEdge' \
    "$RELEASE_API_URL" -o "$raw"

  tag="$(jq -r '.tag_name // empty' "$raw")"
  [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
    die "The OWASP CRS release feed returned an invalid release tag."
  latest="${BASH_REMATCH[1]}"
  validate_version "$latest"
  [[ "$(jq -r '.draft // false' "$raw")" == false ]] || die "Latest CRS release is marked as a draft."
  [[ "$(jq -r '.prerelease // false' "$raw")" == false ]] || die "Latest CRS release is a prerelease."
  url="https://github.com/coreruleset/coreruleset/archive/refs/tags/${tag}.tar.gz"
  checked="$(date +%s)"
  write_update_status "$checked" "$latest" "$tag" "$url"
  printf '%s\n' "$latest"
  trap - RETURN
  rm -f "$raw"
}

check_if_stale() {
  local now checked=0
  now="$(date +%s)"
  if [[ -f "$WAF_CRS_UPDATE_FILE" ]]; then
    checked="$(kv_get "$WAF_CRS_UPDATE_FILE" CHECKED_AT)"
    [[ "$checked" =~ ^[0-9]+$ ]] || checked=0
  fi
  if (( now - checked >= CHECK_MAX_AGE )); then
    check_update >/dev/null
  fi
}

status() {
  local current latest="" checked="" update=0 source
  current="$(current_version)"
  source=bundled
  [[ "$(active_crs_dir)" == "$WAF_CRS_DIR" ]] && source=managed
  if [[ -f "$WAF_CRS_UPDATE_FILE" ]]; then
    latest="$(kv_get "$WAF_CRS_UPDATE_FILE" LATEST_VERSION)"
    checked="$(kv_get "$WAF_CRS_UPDATE_FILE" CHECKED_AT)"
    if [[ -n "$latest" ]] && version_gt "$latest" "$current"; then
      update=1
    fi
  fi
  printf 'CURRENT_VERSION=%s\n' "$current"
  printf 'SOURCE=%s\n' "$source"
  printf 'LATEST_VERSION=%s\n' "$latest"
  printf 'CHECKED_AT=%s\n' "$checked"
  printf 'UPDATE_AVAILABLE=%s\n' "$update"
}

safe_archive() {
  local archive="$1" name line type
  [[ -s "$archive" ]] || die "CRS archive is empty."
  tar -tzf "$archive" >/dev/null 2>&1 || die "CRS archive is not a valid .tar.gz file."
  while IFS= read -r name; do
    [[ "$name" != /* && "$name" != ../* && "$name" != *"/../"* && "$name" != *"/.." ]] ||
      die "CRS archive contains an unsafe path."
  done < <(tar -tzf "$archive")
  while IFS= read -r line; do
    type="${line:0:1}"
    case "$type" in -|d) ;; *) die "CRS archive contains an unsupported filesystem object." ;; esac
  done < <(tar -tvzf "$archive")
}

detect_root() {
  local dir="$1" candidate
  while IFS= read -r candidate; do
    if [[ -f "$candidate/crs-setup.conf.example" && -d "$candidate/rules" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 2 -type d | sort)
  return 1
}

detect_archive_version() {
  local root="$1" version
  version="$(
    grep -h -m1 -E "^# OWASP CRS ver\.[0-9]+\.[0-9]+\.[0-9]+" \
      "$root"/rules/*.conf "$root"/rules/*.conf.example 2>/dev/null |
      sed -n 's/^# OWASP CRS ver\.\([0-9][0-9.]*\).*$/\1/p' |
      head -n1
  )"
  validate_version "$version"
  printf '%s' "$version"
}

stage_crs() {
  local root="$1" version="$2" stage="$3" count
  validate_version "$version"
  mkdir -p "$stage/rules"
  install -m 0644 "$root/crs-setup.conf.example" "$stage/crs-setup.conf"
  cp -a "$root/rules/." "$stage/rules/"
  if [[ -f "$stage/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf.example" ]]; then
    cp "$stage/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf.example" \
       "$stage/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf"
  fi
  if [[ -f "$stage/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf.example" ]]; then
    cp "$stage/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf.example" \
       "$stage/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf"
  fi
  [[ -f "$stage/rules/REQUEST-901-INITIALIZATION.conf" ]] ||
    die "CRS archive is missing REQUEST-901-INITIALIZATION.conf."
  [[ -f "$stage/rules/REQUEST-949-BLOCKING-EVALUATION.conf" ]] ||
    die "CRS archive is missing REQUEST-949-BLOCKING-EVALUATION.conf."
  count="$(find "$stage/rules" -maxdepth 1 -type f -name '*.conf' | wc -l | tr -d ' ')"
  (( count >= 20 )) || die "CRS archive contains too few active rule files."
  cat > "$stage/.liteedge-crs" <<EOF
VERSION=$version
SOURCE=managed
EOF
}

apply_staged_crs() {
  local stage="$1" version="$2" backup="" meta_backup=""
  if [[ -d "$WAF_CRS_DIR" ]]; then
    backup="$(mktemp -d "$WAF_DIR/.crs-backup.XXXXXX")"
    cp -a "$WAF_CRS_DIR/." "$backup/"
  fi
  if [[ -f "$WAF_CRS_META_FILE" ]]; then
    meta_backup="$(mktemp "$WAF_DIR/.crs-meta-backup.XXXXXX")"
    cp "$WAF_CRS_META_FILE" "$meta_backup"
  fi

  rm -rf "$WAF_CRS_DIR"
  mv "$stage" "$WAF_CRS_DIR"
  stage=""
  cat > "$WAF_CRS_META_FILE" <<EOF
VERSION=$version
SOURCE=managed
EOF
  chmod 0600 "$WAF_CRS_META_FILE"

  if ! /opt/liteedge/bin/render-runtime.sh ||
     ! /opt/liteedge/bin/render-nginx.sh ||
     ! "$NGINX_BIN" -t -c "$NGINX_CONF" ||
     ! reload_nginx; then
    rm -rf "$WAF_CRS_DIR"
    if [[ -n "$backup" && -d "$backup" ]]; then
      mkdir -p "$WAF_CRS_DIR"
      cp -a "$backup/." "$WAF_CRS_DIR/"
    fi
    if [[ -n "$meta_backup" && -f "$meta_backup" ]]; then
      cp "$meta_backup" "$WAF_CRS_META_FILE"
    else
      rm -f "$WAF_CRS_META_FILE"
    fi
    /opt/liteedge/bin/render-runtime.sh >/dev/null 2>&1 || true
    /opt/liteedge/bin/render-nginx.sh >/dev/null 2>&1 || true
    reload_nginx >/dev/null 2>&1 || true
    if [[ -n "$backup" ]]; then rm -rf "$backup"; fi
    if [[ -n "$meta_backup" ]]; then rm -f "$meta_backup"; fi
    die "CRS update was rejected by NGINX/ModSecurity. The previous CRS was restored."
  fi

  if [[ -n "$backup" ]]; then rm -rf "$backup"; fi
  if [[ -n "$meta_backup" ]]; then rm -f "$meta_backup"; fi
  return 0
}

import_archive() {
  local archive="$1" expected="${2:-}" tmp root version stage
  [[ -f "$archive" ]] || die "CRS archive is required."
  safe_archive "$archive"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT
  tar -xzf "$archive" -C "$tmp"
  root="$(detect_root "$tmp")" || die "CRS archive does not contain a recognizable OWASP CRS source tree."
  version="$(detect_archive_version "$root")"
  if [[ -n "$expected" ]]; then
    validate_version "$expected"
    [[ "$version" == "$expected" ]] || die "Downloaded CRS archive version $version does not match expected version $expected."
  fi
  stage="$(mktemp -d "$WAF_DIR/.crs-stage.XXXXXX")"
  stage_crs "$root" "$version" "$stage"
  apply_staged_crs "$stage" "$version"
  rm -rf "$tmp"
  trap - EXIT
  printf '%s\n' "$version"
}

install_latest() {
  local latest url tmp
  latest="$(check_update)"
  url="$(kv_get "$WAF_CRS_UPDATE_FILE" DOWNLOAD_URL)"
  [[ "$url" == https://github.com/coreruleset/coreruleset/archive/refs/tags/v*.tar.gz ]] ||
    die "Invalid CRS download URL."
  tmp="$(mktemp)"
  trap 'rm -f "${tmp:-}"' EXIT
  curl -fL --retry 2 --connect-timeout 10 --max-time 120 --proto '=https' --tlsv1.2 \
    -o "$tmp" "$url"
  import_archive "$tmp" "$latest" >/dev/null
  trap - EXIT
  rm -f "$tmp"
  printf '%s\n' "$latest"
}

reset_bundled() {
  local backup="" meta_backup=""
  if [[ -d "$WAF_CRS_DIR" ]]; then
    backup="$(mktemp -d "$WAF_DIR/.crs-reset-backup.XXXXXX")"
    cp -a "$WAF_CRS_DIR/." "$backup/"
  fi
  if [[ -f "$WAF_CRS_META_FILE" ]]; then
    meta_backup="$(mktemp "$WAF_DIR/.crs-reset-meta.XXXXXX")"
    cp "$WAF_CRS_META_FILE" "$meta_backup"
  fi
  rm -rf "$WAF_CRS_DIR"
  rm -f "$WAF_CRS_META_FILE"
  if ! /opt/liteedge/bin/render-runtime.sh ||
     ! /opt/liteedge/bin/render-nginx.sh ||
     ! "$NGINX_BIN" -t -c "$NGINX_CONF" ||
     ! reload_nginx; then
    if [[ -n "$backup" ]]; then
      mkdir -p "$WAF_CRS_DIR"
      cp -a "$backup/." "$WAF_CRS_DIR/"
    fi
    if [[ -n "$meta_backup" ]]; then
      cp "$meta_backup" "$WAF_CRS_META_FILE"
    fi
    /opt/liteedge/bin/render-runtime.sh >/dev/null 2>&1 || true
    /opt/liteedge/bin/render-nginx.sh >/dev/null 2>&1 || true
    reload_nginx >/dev/null 2>&1 || true
    if [[ -n "$backup" ]]; then rm -rf "$backup"; fi
    if [[ -n "$meta_backup" ]]; then rm -f "$meta_backup"; fi
    die "Bundled CRS could not be activated. The managed CRS was restored."
  fi
  if [[ -n "$backup" ]]; then rm -rf "$backup"; fi
  if [[ -n "$meta_backup" ]]; then rm -f "$meta_backup"; fi
  return 0
}

cmd="${1:-}"
shift || true
case "$cmd" in
  current-version) current_version ;;
  status) status ;;
  check) check_update >/dev/null; status ;;
  check-if-stale) check_if_stale; status ;;
  install-latest) install_latest ;;
  import) import_archive "${1:-}" "${2:-}" ;;
  reset-bundled) reset_bundled ;;
  *)
    echo "Usage: crsctl.sh current-version | status | check | check-if-stale | install-latest | import ARCHIVE [EXPECTED_VERSION] | reset-bundled" >&2
    exit 2
    ;;
esac
