#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export DATA_DIR="$TMP/data" SITE_DIR="$TMP/data/sites" EVENTS_FILE="$TMP/data/logs/events.jsonl"
mkdir -p "$SITE_DIR/qa.test.routes" "$TMP/mock" "$TMP/data/logs"
cat > "$TMP/mock-common.sh" <<'COMMON'
DATA_DIR="${DATA_DIR:?}"
SITE_DIR="${SITE_DIR:?}"
route_dir() { printf '%s/%s.routes' "$SITE_DIR" "$1"; }
kv_get() { sed -n "s/^$2=//p" "$1" | head -1; }
die() { echo "$*" >&2; exit 1; }
COMMON
cat > "$SITE_DIR/qa.test.site" <<'SITE'
HOST=qa.test
ENABLED=1
SITE
cat > "$SITE_DIR/qa.test.routes/1234567890abcdef.route" <<'ROUTE'
ID=1234567890abcdef
MATCH=prefix
PATH=/
TARGET=http://127.0.0.1:18081
BACKENDS=http://127.0.0.1:18082
LB_MODE=least_conn
MAX_FAILS=2
FAIL_TIMEOUT=15
HEALTH_ENABLED=1
HEALTH_PATH=/health
HEALTH_EXPECT=200
HEALTH_INTERVAL=10
HEALTH_TIMEOUT=2
HEALTH_FALL=2
HEALTH_RISE=2
HEALTH_COOLDOWN=30
ROUTE
source "$TMP/mock-common.sh"
source "$ROOT/bin/poolctl.sh"
pool_render_upstreams "$TMP/upstreams.conf"
grep -q 'least_conn;' "$TMP/upstreams.conf"
[[ "$(grep -c 'server 127.0.0.1:' "$TMP/upstreams.conf")" == 2 ]]
grep -q 'max_fails=2 fail_timeout=15s' "$TMP/upstreams.conf"
[[ "$(pool_effective_target qa.test "$SITE_DIR/qa.test.routes/1234567890abcdef.route")" == http://liteedge_lb_* ]]
! (pool_validate http://a:80 'http://b:80/other' least_conn 2 15) >/dev/null 2>&1
! (pool_validate http://a:80 'http://b:80;return' least_conn 2 15) >/dev/null 2>&1
cat > "$TMP/mock/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s' "${MOCK_PROBE_CODE:-000}"
MOCK
chmod +x "$TMP/mock/curl"
sed -e 's@source /opt/liteedge/bin/common.sh@source "$TEST_MOCK_COMMON"@' \
    -e 's@source /opt/liteedge/bin/poolctl.sh@source "$TEST_POOL_LIB"@' \
    "$ROOT/bin/health-worker.sh" > "$TMP/health-worker.sh"
chmod +x "$TMP/health-worker.sh"
export TEST_MOCK_COMMON="$TMP/mock-common.sh" TEST_POOL_LIB="$ROOT/bin/poolctl.sh"
export PATH="$TMP/mock:$PATH"
reset_next() {
  for f in "$DATA_DIR/observability/health/"*.json; do
    [[ -f "$f" ]] || continue
    jq '.next=0' "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
  done
}
MOCK_PROBE_CODE=000 "$TMP/health-worker.sh" tick
[[ ! -s "$EVENTS_FILE" ]]
reset_next
MOCK_PROBE_CODE=000 "$TMP/health-worker.sh" tick
[[ "$(jq -s '[.[] | select(.action=="down")] | length' "$EVENTS_FILE")" == 2 ]]
reset_next
MOCK_PROBE_CODE=200 "$TMP/health-worker.sh" tick
[[ "$(wc -l < "$EVENTS_FILE")" == 2 ]]
reset_next
MOCK_PROBE_CODE=200 "$TMP/health-worker.sh" tick
[[ "$(jq -s '[.[] | select(.action=="up")] | length' "$EVENTS_FILE")" == 2 ]]
[[ "$(jq -s '[.[] | select(.type=="health" and .status==200)]|length' "$EVENTS_FILE")" == 2 ]]
# The runtime format must not log backend URL credentials or request URI.
python3 - "$ROOT/nginx/nginx.conf" <<'PY_FORMAT'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
assert 'include @DATA_DIR@/nginx/upstreams.conf;' in s
assert 'map $cookie_liteedge_affinity $liteedge_affinity_key' in s
PY_FORMAT
echo 'PASS backend pool configuration and health down/up threshold events'
