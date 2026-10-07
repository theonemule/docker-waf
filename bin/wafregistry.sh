#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

REGISTRY_URL="${LITEEDGE_CRS_REGISTRY_URL:-https://raw.githubusercontent.com/coreruleset/plugin-registry/main/registry.json}"
SEED_FILE=/opt/liteedge/share/crs-plugin-registry.tsv

registry_ensure() {
  if [[ ! -s "$WAF_REGISTRY_FILE" && -s "$SEED_FILE" ]]; then
    cp "$SEED_FILE" "$WAF_REGISTRY_FILE"
  fi
}

registry_refresh() {
  local raw tmp line name repo type status category
  raw="$(mktemp)"
  tmp="$(mktemp)"
  trap 'rm -f "$raw" "$tmp"' RETURN

  curl -fsSL --connect-timeout 10 --max-time 30 --proto '=https' --tlsv1.2 "$REGISTRY_URL" -o "$raw"

  jq -e '
    .schema_version == 1
    and (.plugins | type == "array")
    and (.plugins | length > 0)
  ' "$raw" >/dev/null || die "The CRS plugin registry JSON is invalid or uses an unsupported schema."

  {
    printf 'NAME\tREPO\tTYPE\tSTATUS\tCATEGORY\n'
    jq -r '
      .plugins[]
      | select((.private // false) != true)
      | [
          .name,
          (.repository
            | sub("^https://github.com/"; "")
            | sub("/$"; "")),
          .type,
          .status,
          (if (.name | test("rule-exclusions")) then "application" else "plugin" end)
        ]
      | @tsv
    ' "$raw"
  } > "$tmp"

  while IFS=$'\t' read -r name repo type status category; do
    [[ "$name" == NAME ]] && continue
    validate_plugin_name "$name"
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
      die "The CRS plugin registry contains an invalid GitHub repository."
    case "$type" in official|3rd-party) ;; *) die "The CRS plugin registry contains an invalid plugin type." ;; esac
    case "$status" in tested|being-tested|untested|draft) ;; *) die "The CRS plugin registry contains an invalid plugin status." ;; esac
    case "$category" in plugin|application) ;; *) die "The CRS plugin registry contains an invalid plugin category." ;; esac
  done < "$tmp"

  (( $(wc -l < "$tmp") > 5 )) || die "The CRS plugin registry did not contain a usable plugin catalog."
  mv "$tmp" "$WAF_REGISTRY_FILE"
  trap - RETURN
  rm -f "$raw"
}

registry_row() {
  local name="$1"
  registry_ensure
  awk -F '\t' -v name="$name" 'NR > 1 && $1 == name {print; exit}' "$WAF_REGISTRY_FILE"
}

safe_archive() {
  local archive="$1" line type name
  tar -tzf "$archive" >/dev/null 2>&1 || die "Plugin download is not a valid tar.gz archive."
  while IFS= read -r name; do
    [[ "$name" != /* && "$name" != ../* && "$name" != *"/../"* && "$name" != *"/.." ]] ||
      die "Plugin archive contains an unsafe path."
  done < <(tar -tzf "$archive")
  while IFS= read -r line; do
    type="${line:0:1}"
    case "$type" in -|d) ;; *) die "Plugin archive contains an unsupported filesystem object." ;; esac
  done < <(tar -tvzf "$archive")
}

restore_plugin() {
  local name="$1" backup="${2:-}"
  rm -rf "${WAF_PLUGIN_DIR:?}/$name"
  if [[ -n "$backup" && -d "$backup" ]]; then
    mv "$backup" "$WAF_PLUGIN_DIR/$name"
  fi
  /opt/liteedge/bin/render-nginx.sh >/dev/null 2>&1 || true
  reload_nginx >/dev/null 2>&1 || true
}

plugin_install() {
  local name="$1" row repo type status category api branch archive tmp root stage backup=""
  validate_plugin_name "$name"
  row="$(registry_row "$name")"
  [[ -n "$row" ]] || die "Plugin is not present in the current CRS registry catalog."
  IFS=$'\t' read -r _ repo type status category <<< "$row"

  api="$(mktemp)"
  archive="$(mktemp)"
  tmp="$(mktemp -d)"
  stage="$(mktemp -d "$WAF_PLUGIN_DIR/.${name}.stage.XXXXXX")"
  trap 'rm -rf "$api" "$archive" "$tmp" "$stage"' RETURN

  curl -fsSL --connect-timeout 10 --max-time 30 --proto '=https' --tlsv1.2 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$repo" -o "$api"
  branch="$(jq -r '.default_branch // empty' "$api")"
  [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Could not determine the plugin repository default branch."

  curl -fL --retry 2 --connect-timeout 10 --max-time 60 --proto '=https' --tlsv1.2 \
    -o "$archive" "https://github.com/$repo/archive/refs/heads/$branch.tar.gz"
  safe_archive "$archive"
  tar -xzf "$archive" -C "$tmp"

  root="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "$root" && -d "$root/plugins" ]] || die "Plugin bundle does not contain a plugins directory."
  find "$root/plugins" -type f -name '*.conf' -print -quit | grep -q . ||
    die "Plugin bundle does not contain ModSecurity plugin configuration files."

  cp -a "$root/." "$stage/"
  cat > "$stage/.liteedge-plugin" <<META
NAME=$name
REPO=$repo
TYPE=$type
STATUS=$status
CATEGORY=$category
BRANCH=$branch
META

  if [[ -d "$WAF_PLUGIN_DIR/$name" ]]; then
    backup="$WAF_PLUGIN_DIR/.${name}.backup.$$"
    mv "$WAF_PLUGIN_DIR/$name" "$backup"
  fi
  mv "$stage" "$WAF_PLUGIN_DIR/$name"
  stage=""

  if ! /opt/liteedge/bin/render-nginx.sh || ! reload_nginx; then
    restore_plugin "$name" "$backup"
    die "Plugin installation was rejected by NGINX/ModSecurity. The previous plugin version was restored."
  fi

  [[ -z "$backup" ]] || rm -rf "$backup"
  trap - RETURN
  rm -rf "$api" "$archive" "$tmp"
}

plugin_remove() {
  local name="$1" route backup
  validate_plugin_name "$name"
  [[ -d "$WAF_PLUGIN_DIR/$name" ]] || die "Plugin is not installed."
  shopt -s nullglob
  for route in "$SITE_DIR"/*.routes/*.route; do
    if csv_contains "$(kv_get "$route" WAF_PLUGINS)" "$name"; then
      die "Plugin is still selected by route $(kv_get "$route" PATH) for $(basename "$(dirname "$route")" .routes). Remove it from that route first."
    fi
  done

  backup="$WAF_PLUGIN_DIR/.${name}.remove.$$"
  mv "$WAF_PLUGIN_DIR/$name" "$backup"
  if ! /opt/liteedge/bin/render-nginx.sh || ! reload_nginx; then
    mv "$backup" "$WAF_PLUGIN_DIR/$name"
    /opt/liteedge/bin/render-nginx.sh >/dev/null 2>&1 || true
    reload_nginx >/dev/null 2>&1 || true
    die "Plugin removal was rejected by NGINX/ModSecurity. The plugin was restored."
  fi
  rm -rf "$backup"
}


plugin_config_path() {
  local name="$1" file="$2" base
  validate_plugin_name "$name"
  [[ "$file" =~ ^[A-Za-z0-9._-]+-config\.conf$ ]] ||
    die "Invalid plugin configuration filename."
  base="$WAF_PLUGIN_DIR/$name/plugins"
  [[ -d "$base" ]] || die "Plugin is not installed."
  [[ -f "$base/$file" ]] || die "Plugin configuration file does not exist."
  printf '%s' "$base/$file"
}

plugin_config_save() {
  local name="$1" file="$2" source_file="$3" target backup
  [[ -f "$source_file" ]] || die "Plugin configuration content is required."
  target="$(plugin_config_path "$name" "$file")"
  backup="$(mktemp)"
  cp "$target" "$backup"
  install -m 0644 "$source_file" "$target"

  if ! /opt/liteedge/bin/render-nginx.sh || ! reload_nginx; then
    cp "$backup" "$target"
    /opt/liteedge/bin/render-nginx.sh >/dev/null 2>&1 || true
    reload_nginx >/dev/null 2>&1 || true
    rm -f "$backup"
    die "Plugin configuration was rejected by NGINX/ModSecurity. The previous configuration was restored."
  fi
  rm -f "$backup"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  ensure) registry_ensure ;;
  refresh) registry_refresh ;;
  install) plugin_install "${1:-}" ;;
  remove) plugin_remove "${1:-}" ;;
  config-save) plugin_config_save "${1:-}" "${2:-}" "${3:-}" ;;
  *)
    echo "Usage: wafregistry.sh ensure | refresh | install NAME | remove NAME | config-save NAME FILE SOURCE" >&2
    exit 2
    ;;
esac
