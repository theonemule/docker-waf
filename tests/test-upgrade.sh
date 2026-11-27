#!/usr/bin/env bash
# Safe upgrade regression: isolated Docker/Compose mocks, no live services.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mock" "$TMP/current/data"
cat > "$TMP/mock/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  'compose version'|'compose config -q'|'compose up -d --no-deps --pull never liteedge')
    if [[ "$*" == 'compose up -d --no-deps --pull never liteedge' && "${MOCK_FAIL_ACTIVATE:-0}" == 1 ]] &&
        grep -qx 'LITEEDGE_VERSION=v3.3.1' .env; then echo changed > data/sentinel; touch data/new-state; exit 8; fi
    ;;
  'pull ghcr.io/theonemule/docker-waf:v3.3.1')
    [[ "${MOCK_FAIL_PULL:-0}" != 1 ]] || exit 9 ;;
  'compose ps -aq liteedge'|'compose ps -q liteedge') echo fake-container ;;
  'inspect -f {{.Image}} fake-container')
    if grep -qx 'LITEEDGE_VERSION=v3.3.1' "$MOCK_DIR/.env"; then echo sha256:new; else echo sha256:old; fi ;;
  'run --rm --entrypoint cat sha256:old /opt/liteedge/VERSION') echo "LiteEdge=${MOCK_OLD_VERSION:-3.1.4}" ;;
  'image inspect -f {{.Id}} ghcr.io/theonemule/docker-waf:v3.3.1') echo sha256:new ;;
  'image inspect -f {{.Id}} ghcr.io/theonemule/docker-waf:v3.1.4'|'image inspect -f {{.Id}} ghcr.io/theonemule/docker-waf:latest') echo sha256:old ;;
  'compose stop liteedge') ;;
  'compose run --rm --no-deps -T --pull never --entrypoint tar liteedge -C /data --exclude=./logs --exclude=./run -cf - .') tar -C data --exclude=./logs --exclude=./run -cf - . ;;
  'compose run --rm --no-deps -T --pull never --entrypoint bash liteedge -ec '*)
    (cd data; find . -mindepth 1 -maxdepth 1 ! -name logs ! -name run -exec rm -rf -- {} +; tar -xf -) ;;
  'inspect -f {{.State.Running}} fake-container') echo true ;;
  'inspect -f {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} fake-container')
    if [[ "${MOCK_UNHEALTHY:-0}" == 1 ]]; then echo changed > data/sentinel; touch data/new-state; echo unhealthy; else echo healthy; fi ;;
  *) echo "Unexpected docker call: $*" >&2; exit 99 ;;
esac
MOCK
chmod +x "$TMP/mock/docker"
export MOCK_DIR="$TMP/current" MOCK_LOG="$TMP/docker.log" PATH="$TMP/mock:$PATH"
cp "$ROOT/docker-compose.yml" "$TMP/current/docker-compose.yml"
cat > "$TMP/current/.env" <<'ENV'
ADMIN_USER=admin
ADMIN_PASSWORD=keep-this-private
ACME_EMAIL=keep@example.com
LITEEDGE_VERSION=v3.1.4
LITEEDGE_REPO=theonemule/docker-waf
CUSTOM_SETTING=keep-me
ENV
chmod 600 "$TMP/current/.env"
echo 'persistent-data' > "$TMP/current/data/sentinel"
printf 'custom override\n' > "$TMP/current/docker-compose.override.yml"
cp "$TMP/current/.env" "$TMP/original.env"
: > "$MOCK_LOG"
bash "$ROOT/scripts/upgrade-liteedge.sh" --mode docker --compose-dir "$TMP/current"
grep -qx 'LITEEDGE_VERSION=v3.3.1' "$TMP/current/.env"
grep -qx 'ADMIN_PASSWORD=keep-this-private' "$TMP/current/.env"
grep -qx 'CUSTOM_SETTING=keep-me' "$TMP/current/.env"
grep -qx 'persistent-data' "$TMP/current/data/sentinel"
grep -qx 'custom override' "$TMP/current/docker-compose.override.yml"
if find "$TMP/current" -maxdepth 1 -name '.liteedge-upgrade.*' | grep -q .; then
  echo 'Temporary upgrade directory was not cleaned up' >&2; exit 1
fi
grep -qF 'pull ghcr.io/theonemule/docker-waf:v3.3.1' "$MOCK_LOG"
# New container fails to activate: .env must roll back and Compose must restart.
cp "$TMP/original.env" "$TMP/current/.env"
: > "$MOCK_LOG"
if MOCK_FAIL_ACTIVATE=1 bash "$ROOT/scripts/upgrade-liteedge.sh" --mode docker --compose-dir "$TMP/current" >/dev/null 2>&1; then
  echo 'Failed upgrade incorrectly succeeded' >&2; exit 1
fi
cmp "$TMP/original.env" "$TMP/current/.env"
grep -qx persistent-data "$TMP/current/data/sentinel"
test ! -e "$TMP/current/data/new-state"
[[ "$(grep -c 'compose up -d --no-deps --pull never liteedge' "$MOCK_LOG")" == 2 ]]
# Pull errors must leave the .env untouched and never call Compose up.
: > "$MOCK_LOG"
if MOCK_FAIL_PULL=1 bash "$ROOT/scripts/upgrade-liteedge.sh" --mode docker --compose-dir "$TMP/current" >/dev/null 2>&1; then
  echo 'Pull failure incorrectly succeeded' >&2; exit 1
fi
cmp "$TMP/original.env" "$TMP/current/.env"
if grep -q 'compose up -d --no-deps --pull never liteedge' "$MOCK_LOG"; then
  echo 'Compose was started despite failed image pull' >&2; exit 1
fi
# Bad health status must roll back.
: > "$MOCK_LOG"
if MOCK_UNHEALTHY=1 bash "$ROOT/scripts/upgrade-liteedge.sh" --mode docker --compose-dir "$TMP/current" >/dev/null 2>&1; then
  echo 'Unhealthy container accepted' >&2; exit 1
fi
cmp "$TMP/original.env" "$TMP/current/.env"
grep -qx persistent-data "$TMP/current/data/sentinel"
test ! -e "$TMP/current/data/new-state"
[[ "$(grep -c 'compose up -d --no-deps --pull never liteedge' "$MOCK_LOG")" == 2 ]]
# Never downgrade or perform an implicit first-time installation.
if MOCK_OLD_VERSION=3.4.0 bash "$ROOT/scripts/upgrade-liteedge.sh" --mode docker --compose-dir "$TMP/current" >/dev/null 2>&1; then
  echo 'Downgrade was accepted' >&2; exit 1
fi
# Older supported branches and mutable aliases resolve actual installed version.
for previous in 3.0.0 3.1.6 3.2.0-rc.1; do
  cp "$TMP/original.env" "$TMP/current/.env"
  MOCK_OLD_VERSION="$previous" bash "$ROOT/scripts/upgrade-liteedge.sh" --mode docker --compose-dir "$TMP/current" >/dev/null
done
cp "$TMP/original.env" "$TMP/current/.env"
sed -i 's/LITEEDGE_VERSION=v3.1.4/LITEEDGE_VERSION=latest/' "$TMP/current/.env"
MOCK_OLD_VERSION=3.1.6 bash "$ROOT/scripts/upgrade-liteedge.sh" --mode docker --compose-dir "$TMP/current" >/dev/null
rm -f "$TMP/current/.env"
if bash "$ROOT/scripts/upgrade-liteedge.sh" --mode docker --compose-dir "$TMP/current" >/dev/null 2>&1; then
  echo 'Uninitialized installation was accepted' >&2; exit 1
fi
echo 'PASS v3.3.1 upgrade: Docker state retention, rollback on activation/pull/health errors, downgrade/new-install protection'