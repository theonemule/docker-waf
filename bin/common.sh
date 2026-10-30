#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/liteedge/bin:/opt/liteedge/sbin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export LD_LIBRARY_PATH="/opt/liteedge/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

DATA_DIR="${DATA_DIR:-/data}"
SITE_DIR="$DATA_DIR/sites"
CERT_DIR="$DATA_DIR/certs"
ACME_DIR="$DATA_DIR/acme"
NGINX_DIR="$DATA_DIR/nginx"
NGINX_SITE_DIR="${NGINX_SITE_DIR:-$NGINX_DIR/sites}"
NGINX_BASELINE_DIR="${NGINX_BASELINE_DIR:-$NGINX_DIR/baselines}"
NGINX_DIFF_DIR="${NGINX_DIFF_DIR:-$NGINX_DIR/diffs}"
NGINX_CONFLICT_DIR="${NGINX_CONFLICT_DIR:-$NGINX_DIR/conflicts}"
NGINX_CONF="${NGINX_CONF:-$NGINX_DIR/nginx.conf}"
NGINX_BIN="${NGINX_BIN:-/opt/liteedge/sbin/nginx}"
WAF_DIR="${WAF_DIR:-$DATA_DIR/waf}"
WAF_CUSTOM_DIR="${WAF_CUSTOM_DIR:-$WAF_DIR/custom}"
WAF_DISABLED_FILE="${WAF_DISABLED_FILE:-$WAF_DIR/disabled-rules}"
WAF_SETTINGS_FILE="${WAF_SETTINGS_FILE:-$WAF_DIR/settings.conf}"
WAF_REGISTRY_FILE="${WAF_REGISTRY_FILE:-$WAF_DIR/registry.tsv}"
WAF_PLUGIN_DIR="${WAF_PLUGIN_DIR:-$WAF_DIR/plugins}"
WAF_CRS_DIR="${WAF_CRS_DIR:-$WAF_DIR/crs}"
WAF_CRS_META_FILE="${WAF_CRS_META_FILE:-$WAF_DIR/crs-release.conf}"
WAF_CRS_UPDATE_FILE="${WAF_CRS_UPDATE_FILE:-$WAF_DIR/crs-update.conf}"
BUNDLED_CRS_DIR="${BUNDLED_CRS_DIR:-/opt/liteedge/etc/crs}"
SERVER_SETTINGS_FILE="${SERVER_SETTINGS_FILE:-$DATA_DIR/server-settings.conf}"
OBS_DIR="${OBS_DIR:-$DATA_DIR/observability}"

mkdir -p   "$SITE_DIR" "$CERT_DIR"   "$ACME_DIR/challenges/.well-known/acme-challenge" "$ACME_DIR/certs"   "$NGINX_SITE_DIR" "$NGINX_BASELINE_DIR" "$NGINX_DIFF_DIR" "$NGINX_CONFLICT_DIR"   "$WAF_DIR" "$WAF_CUSTOM_DIR" "$WAF_PLUGIN_DIR"

die() {
  echo "$*" >&2
  exit 1
}

slug_for_host() {
  local host="${1,,}"
  printf '%s' "$host" | sed 's/[^a-z0-9.-]/_/g'
}

site_file() { printf '%s/%s.site' "$SITE_DIR" "$(slug_for_host "$1")"; }
route_dir() { printf '%s/%s.routes' "$SITE_DIR" "$(slug_for_host "$1")"; }
cert_dir() { printf '%s/%s' "$CERT_DIR" "$(slug_for_host "$1")"; }
waf_rule_file() { printf '%s/%s.waf-disabled' "$SITE_DIR" "$(slug_for_host "$1")"; }
site_nginx_file() { printf '%s/%s.conf' "$NGINX_SITE_DIR" "$(slug_for_host "$1")"; }
site_nginx_baseline() { printf '%s/%s.conf' "$NGINX_BASELINE_DIR" "$(slug_for_host "$1")"; }
site_nginx_diff() { printf '%s/%s.diff' "$NGINX_DIFF_DIR" "$(slug_for_host "$1")"; }
site_nginx_conflict() { printf '%s/%s.conflict' "$NGINX_CONFLICT_DIR" "$(slug_for_host "$1")"; }

kv_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | head -n1
}

bool_value() {
  case "${1:-}" in 1|on|true|yes) echo 1 ;; *) echo 0 ;; esac
}

validate_host() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] ||
    die "Invalid host: $1"
}

validate_aliases() {
  local aliases="${1//,/ }" item
  for item in $aliases; do validate_host "$item"; done
}

validate_mode() {
  case "$1" in proxy|wordpress|static) ;; *) die "Invalid site mode: $1" ;; esac
}

validate_upstream() {
  local re='^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._~:/?@!$&()*+,=%-]*)?$'
  [[ "$1" =~ $re ]] || die "Upstream must be an http:// or https:// URL using safe URL characters."
}

validate_root() {
  local value="$1"
  [[ "$value" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Unsafe static root."
  case "$value" in
    "$DATA_DIR"/www/*|/srv/*) ;;
    *) die "Static root must be under $DATA_DIR/www or /srv." ;;
  esac
}

validate_waf_profile() {
  case "$1" in generic|wordpress|"") ;; *) die "Invalid legacy WAF application profile." ;; esac
}

validate_waf_pl() {
  [[ "${1:-}" =~ ^[1-4]$ ]] || die "OWASP protection level must be PL1, PL2, PL3, or PL4."
}

validate_plugin_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid CRS plugin name."
}

validate_route_match() {
  case "$1" in prefix|exact|regex) ;; *) die "Invalid route match type." ;; esac
}

validate_route_path() {
  local value="$1"
  [[ "$value" == /* ]] || die "Route must begin with /."
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *[[:space:]]* && "$value" != *'{'* && "$value" != *'}'* && "$value" != *';'* && "$value" != *'"'* && "$value" != *"'"* ]] ||
    die "Unsafe route pattern."
}

validate_rule_id() {
  [[ "${1:-}" =~ ^[0-9]{1,9}$ ]] || die "ModSecurity rule ID must contain digits only."
}

validate_timeout() {
  if [[ ! "${1:-}" =~ ^[0-9]+$ ]] || (( 10#${1} < 1 || 10#${1} > 86400 )); then
    die "Timeout must be between 1 and 86400 seconds."
  fi
}

csv_contains() {
  local csv="${1:-}" wanted="${2:-}" item
  local -a items=()
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}

normalize_plugin_csv() {
  local csv="${1:-}" item out=""
  local -a items=()
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || continue
    validate_plugin_name "$item"
    [[ -d "$WAF_PLUGIN_DIR/$item" ]] || die "CRS plugin is not installed: $item"
    if [[ -z "$out" ]]; then out="$item"; else out="$out,$item"; fi
  done
  printf '%s' "$out"
}

normalize_rule_csv() {
  local csv="${1:-}" item out=""
  local -a items=()
  csv="${csv// /,}"
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || continue
    validate_rule_id "$item"
    if [[ -z "$out" ]]; then out="$item"; else out="$out,$item"; fi
  done
  printf '%s' "$out"
}

disabled_waf_rules() {
  local file
  file="$(waf_rule_file "$1")"
  [[ -f "$file" ]] || return 0
  grep -E '^[0-9]{1,9}$' "$file" | sort -n -u
}

server_setting_get() {
  local key="$1" default="${2:-}" value=""
  if [[ -f "$SERVER_SETTINGS_FILE" ]]; then
    value="$(kv_get "$SERVER_SETTINGS_FILE" "$key")"
  fi
  printf '%s' "${value:-$default}"
}

waf_setting_get() {
  local key="$1" default="${2:-}" value=""
  if [[ -f "$WAF_SETTINGS_FILE" ]]; then
    value="$(kv_get "$WAF_SETTINGS_FILE" "$key")"
  fi
  printf '%s' "${value:-$default}"
}

global_disabled_waf_rules() {
  [[ -f "$WAF_DISABLED_FILE" ]] || return 0
  grep -E '^[0-9]{1,9}$' "$WAF_DISABLED_FILE" | sort -n -u
}

custom_waf_rule_file() {
  validate_rule_id "$1"
  printf '%s/%s.conf' "$WAF_CUSTOM_DIR" "$1"
}

bundled_crs_version() {
  sed -n 's/^CRS=//p' /opt/liteedge/VERSION 2>/dev/null | head -n1
}

active_crs_dir() {
  if [[ -f "$WAF_CRS_DIR/crs-setup.conf" && -d "$WAF_CRS_DIR/rules" ]]; then
    printf '%s' "$WAF_CRS_DIR"
  else
    printf '%s' "$BUNDLED_CRS_DIR"
  fi
}

active_crs_version() {
  local value
  value="$(kv_get "$WAF_CRS_META_FILE" VERSION)"
  if [[ -n "$value" && "$(active_crs_dir)" == "$WAF_CRS_DIR" ]]; then
    printf '%s' "$value"
  else
    bundled_crs_version
  fi
}

crs_rule_rows() {
  local awk_file crs_dir
  awk_file=/opt/liteedge/share/crs-rule-parser.awk
  [[ -f "$awk_file" ]] || return 0
  crs_dir="$(active_crs_dir)"
  awk -f "$awk_file" "$crs_dir"/rules/*.conf 2>/dev/null | sort -t $'\t' -k1,1n -u
}

installed_plugin_rows() {
  local dir meta name repo type status category
  shopt -s nullglob
  for dir in "$WAF_PLUGIN_DIR"/*; do
    [[ -d "$dir" ]] || continue
    meta="$dir/.liteedge-plugin"
    name="$(basename "$dir")"
    repo="$(kv_get "$meta" REPO)"
    type="$(kv_get "$meta" TYPE)"
    status="$(kv_get "$meta" STATUS)"
    category="$(kv_get "$meta" CATEGORY)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$repo" "$type" "$status" "${category:-plugin}"
  done | sort
}

reload_nginx() {
  "$NGINX_BIN" -s reload -c "$NGINX_CONF"
}

# Route feature validation. Never interpolate unchecked values into NGINX directives.
validate_route_methods() {
  local methods="$1" item
  [[ "$methods" == ALL ]] && return 0
  [[ "$methods" =~ ^(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS|TRACE|CONNECT)(,(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS|TRACE|CONNECT))*$ ]] || die 'Invalid HTTP method selection.'
  local -A seen=()
  local -a items=()
  IFS=',' read -r -a items <<< "$methods"
  for item in "${items[@]}"; do
    [[ ! -v seen[$item] ]] || die 'Duplicate HTTP method.'
    seen[$item]=1
  done
}
validate_route_rewrite() {
  local enabled="$1" pattern="$2" replacement="$3"
  [[ "$enabled" == 0 || "$enabled" == 1 ]] || die 'Invalid rewrite toggle.'
  [[ "$enabled" == 1 ]] || return 0
  [[ "${#pattern}" -le 256 && "$pattern" == '^/'* ]] || die 'Rewrite regex must start with ^/ and be <=256 characters.'
  [[ "${#replacement}" -le 512 && "$replacement" == /* ]] || die 'Rewrite destination must begin with / and be <=512 characters.'
  # NGINX validates regex syntax on config test; this denies directive delimiters.
  if printf %s "$pattern" | LC_ALL=C grep -Eq '[[:space:];#{}]'; then die 'Unsafe rewrite regex.'; fi
  case "$pattern" in *\"*|*\'*|*\`*) die "Unsafe rewrite regex quoting.";; esac
  printf '%s' "$replacement" | LC_ALL=C grep -Eq '^/[a-zA-Z0-9_./$?&=%+-]+$' || die 'Unsafe rewrite replacement.'
}
validate_route_headers() {
  local value="$1" line key val count=0
  [[ "${#value}" -le 4096 ]] || die 'Headers too long.'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    ((count+=1)); ((count<=20)) || die 'Maximum 20 headers.'
    [[ "$line" == *:* ]] || die 'Headers must be X-Name: value.'
    key="${line%%:*}"; val="${line#*:}"; val="${val# }"
    [[ "$key" =~ ^X-[a-zA-Z0-9-]+$ && -n "$val" && "${#val}" -le 256 ]] || die 'Invalid X-header name/value.'
    case "${key,,}" in x-real-ip|x-forwarded-for|x-forwarded-proto|x-forwarded-host|x-liteedge-*) die 'Cannot override protected forwarding headers.';; esac
    printf '%s' "$val" | LC_ALL=C grep -Eq '^[a-zA-Z0-9_.,:/@+=% -]+$' || die 'Unsafe request header value.'
  done <<< "$value"
}
