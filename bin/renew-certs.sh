#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

shopt -s nullglob
status=0

for mode_file in "$CERT_DIR"/*/mode; do
  [[ "$(cat "$mode_file" 2>/dev/null)" == letsencrypt ]] || continue
  slug="$(basename "$(dirname "$mode_file")")"
  site="$SITE_DIR/$slug.site"
  [[ -f "$site" ]] || continue
  host="$(kv_get "$site" HOST)"
  if ! /opt/liteedge/bin/certctl.sh letsencrypt "$host"; then
    echo "Renewal failed for $host" >&2
    status=1
  fi
done

exit "$status"
