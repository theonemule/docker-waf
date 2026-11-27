#!/usr/bin/env bash
# Real Compose lifecycle against disposable local aliases, without a registry push.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
candidate="${1:?candidate image required}"
previous="${2:?previous image required}"
tmp="$(mktemp -d)"
suffix="$(openssl rand -hex 5)"
export COMPOSE_PROJECT_NAME="leup$suffix"
export FIXTURE_REPO="lightedge-upgrade-$suffix/docker-waf"
export FIXTURE_IMAGE="ghcr.io/$FIXTURE_REPO:v3.3.1"
export FIXTURE_PREVIOUS="ghcr.io/$FIXTURE_REPO:v3.1.6"
export REAL_DOCKER="$(command -v docker)"
password=upgrade-compose-fixture-only
cleanup(){
 rc=$?
 if ((rc));then (cd "$tmp" && "$REAL_DOCKER" compose logs --tail 60) >&2 || true;fi
 (cd "$tmp" && "$REAL_DOCKER" compose down -v --remove-orphans) >/dev/null 2>&1 || true
 "$REAL_DOCKER" image rm "$FIXTURE_IMAGE" "$FIXTURE_PREVIOUS" >/dev/null 2>&1 || true
 rm -rf "$tmp";exit "$rc"
}
trap cleanup EXIT
docker compose version >/dev/null
docker tag "$previous" "$FIXTURE_PREVIOUS"
docker tag "$candidate" "$FIXTURE_IMAGE"
mkdir -p "$tmp/mock" "$tmp/data"
cat >"$tmp/mock/docker" <<'MOCK'
#!/usr/bin/env bash
set -e
if [[ "$*" == "pull $FIXTURE_IMAGE" ]];then
  # The exact local candidate represents the unpublished versioned release.
  "$REAL_DOCKER" image inspect "$FIXTURE_IMAGE" >/dev/null
  exit
fi
exec "$REAL_DOCKER" "$@"
MOCK
chmod +x "$tmp/mock/docker"
cat >"$tmp/docker-compose.yml" <<'YAML'
services:
  liteedge:
    image: "ghcr.io/${LITEEDGE_REPO}:${LITEEDGE_VERSION}"
    environment:
      ADMIN_PASSWORD: "${ADMIN_PASSWORD}"
    ports:
      - "127.0.0.1::9443"
    volumes:
      - state:/data
    stop_grace_period: 2s
    healthcheck:
      test: ["CMD-SHELL", "test \"$(curl -ks -o /dev/null -w '%{http_code}' https://127.0.0.1:9443/)\" = 401"]
      interval: 1s
      timeout: 2s
      retries: 10
volumes:
  state: {}
YAML
printf 'LITEEDGE_REPO=%s\nLITEEDGE_VERSION=v3.1.6\nADMIN_PASSWORD=%s\nCUSTOM_SETTING=retained\n' "$FIXTURE_REPO" "$password" >"$tmp/.env"
chmod 600 "$tmp/.env"
compose(){ (cd "$tmp" && "$REAL_DOCKER" compose "$@"); }
ready(){
  admin="https://$(compose port liteedge 9443)"
  for i in $(seq 1 60);do
    if curl -ksf --max-time 2 -u "admin:$password" "$admin/api/v1/sites" >/dev/null;then return;fi
    [[ "$i" -lt 60 ]];sleep .25
  done
}
compose up -d --no-deps --pull never liteedge >/dev/null
ready
curl -ksSf -u "admin:$password" -H 'X-LiteEdge-API: 1' -d host=upgrade-compose.test "$admin/api/v1/actions/site/save" | jq -e '.ok' >/dev/null
compose exec -T liteedge sh -c 'printf "keep\n" >/data/logs/upgrade-fixture.log; sha256sum /data/auth/.htpasswd /data/certs/_admin/fullchain.pem' >"$tmp/before"
cp "$tmp/.env" "$tmp/old.env"
# Exercise successful upgrade and ensure the prior auth remains operational.
PATH="$tmp/mock:$PATH" bash "$ROOT/scripts/upgrade-liteedge.sh" --mode docker --compose-dir "$tmp"
grep -qx LITEEDGE_VERSION=v3.3.1 "$tmp/.env"
grep -qx CUSTOM_SETTING=retained "$tmp/.env"
ready
curl -ksSf -u "admin:$password" "$admin/api/v1/site-inventory" | jq -e '.sites|any(.host=="upgrade-compose.test")' >/dev/null
compose exec -T liteedge sh -c 'grep -qx keep /data/logs/upgrade-fixture.log; sha256sum /data/auth/.htpasswd /data/certs/_admin/fullchain.pem' >"$tmp/after"
cmp "$tmp/before" "$tmp/after"
echo 'PASS real Compose upgrade: pinned images, preserved state, health and authentication'
