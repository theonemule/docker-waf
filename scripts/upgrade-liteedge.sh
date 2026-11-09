#!/usr/bin/env bash
# LiteEdge v3.1.5 in-place upgrade for Docker Compose or native Alpine/OpenRC.
# Stateful directories and administrator credentials are never replaced.
set -Eeuo pipefail
umask 077

VERSION=v3.1.5
REPO="${LITEEDGE_REPO:-theonemule/docker-waf}"
MODE=auto
COMPOSE_DIR="$PWD"
START=1
TMP=""
ROLLBACK=0
OLD_RUNNING=0
BACKUP=""
INIT_BACKUP=""
OLD_VERSION=""

usage() {
  cat <<'USAGE'
LiteEdge v3.1.5 in-place upgrade
Usage: upgrade-liteedge.sh [--mode auto|docker|alpine] [--compose-dir DIR]
                           [--repo OWNER/REPO] [--no-start]

Docker mode (non-root): Run from the existing Compose directory or specify
--compose-dir. Preserves the current Compose file, .env values, and ./data.
Alpine mode (root): Replaces /opt/liteedge only after archive verification and
staging; preserves /var/lib/liteedge and /etc/conf.d/liteedge. On failure, the
previous executable tree is restored and the service is restarted if possible.

Downloads only the pinned v3.1.5 release. No downgrades or new installs.
USAGE
}
die() { echo "LiteEdge upgrade: $*" >&2; exit 1; }
notice() { echo "LiteEdge upgrade: $*"; }
while (($#)); do
  case "$1" in
    --mode) (($# >= 2)) || die 'Missing --mode value'; MODE="$2"; shift 2 ;;
    --compose-dir) (($# >= 2)) || die 'Missing --compose-dir value'; COMPOSE_DIR="$2"; shift 2 ;;
    --repo) (($# >= 2)) || die 'Missing --repo value'; REPO="$2"; shift 2 ;;
    --no-start) START=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ "$MODE" == auto || "$MODE" == alpine || "$MODE" == docker ]] || die 'Invalid mode.'
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Invalid repository.'
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required.'
command -v mktemp >/dev/null 2>&1 || die 'mktemp is required.'

# Releases have immutable version tags; never pull "latest" as an upgrade.
compare_versions() {
  local old="$1"
  [[ "$old" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  [[ "v${old#v}" != "$VERSION" ]] || die "Already at $VERSION."
  local first
  first="$(printf '%s\n' "${old#v}" "${VERSION#v}" | sort -V | head -n1)"
  [[ "$first" == "${old#v}" ]] || die "Refusing downgrade from $old to $VERSION."
}
cleanup() {
  local code=$?
  trap - EXIT
  if [[ "$ROLLBACK" == 1 ]]; then
    notice 'Upgrade failed; attempting rollback.'
    if [[ "$MODE" == docker ]]; then
      if [[ -n "$TMP" && -f "$TMP/original.env" ]]; then
        cp -p "$TMP/original.env" "$COMPOSE_DIR/.env"
        (cd "$COMPOSE_DIR" && docker compose up -d) || echo 'Rollback restart failed; inspect Docker Compose.' >&2
      fi
    elif [[ "$MODE" == alpine ]]; then
      if command -v rc-service >/dev/null 2>&1; then
        rc-service liteedge stop >/dev/null 2>&1 || true
      fi
      if [[ -n "$BACKUP" && -d "$BACKUP" ]]; then
        rm -rf /opt/liteedge
        mv "$BACKUP" /opt/liteedge
        if [[ -n "$INIT_BACKUP" && -f "$INIT_BACKUP" ]]; then
          cp -p "$INIT_BACKUP" /etc/init.d/liteedge
        fi
      fi
      if [[ "$OLD_RUNNING" == 1 ]]; then
        rc-service liteedge start || echo 'Rollback service restart failed; inspect OpenRC.' >&2
      fi
    fi
  fi
  if [[ -n "$TMP" && -d "$TMP" ]]; then rm -rf "$TMP"; fi
  if [[ "$code" -ne 0 ]]; then notice "Failed (exit $code)."; fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$MODE" == auto ]]; then
  if [[ -f "$COMPOSE_DIR/docker-compose.yml" && -f "$COMPOSE_DIR/.env" ]]; then
    MODE=docker
  elif [[ -f /opt/liteedge/VERSION && -f /etc/init.d/liteedge ]]; then
    MODE=alpine
  else
    die 'Cannot identify an existing installation; pass --mode and --compose-dir.'
  fi
fi

upgrade_docker() {
  [[ "$START" == 1 ]] || die '--no-start is supported only for standalone Alpine installs.'
  command -v docker >/dev/null 2>&1 || die 'Docker is required.'
  docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is required.'
  [[ -f "$COMPOSE_DIR/.env" && -f "$COMPOSE_DIR/docker-compose.yml" ]] ||
    die 'Missing existing .env or docker-compose.yml; new installations are not supported.'
  [[ -d "$COMPOSE_DIR/data" ]] || die 'Missing persistent ./data directory.'
  [[ -r "$COMPOSE_DIR/.env" && -w "$COMPOSE_DIR/.env" ]] || die '.env must be readable and writable.'
  local old_repo old_tag image cid state health attempt
  old_repo="$(sed -n 's/^LITEEDGE_REPO=//p' "$COMPOSE_DIR/.env" | tail -n1)"
  if [[ -n "$old_repo" && "$REPO" == theonemule/docker-waf ]]; then REPO="$old_repo"; fi
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Invalid repository in .env.'
  old_tag="$(sed -n 's/^LITEEDGE_VERSION=//p' "$COMPOSE_DIR/.env" | tail -n1)"
  [[ -n "$old_tag" ]] || die 'Existing .env must specify LITEEDGE_VERSION.'
  compare_versions "$old_tag"
  (cd "$COMPOSE_DIR" && docker compose config -q) || die 'Existing Compose file fails validation.'
  TMP="$(mktemp -d "$COMPOSE_DIR/.liteedge-upgrade.XXXXXXXX")"
  cp -p "$COMPOSE_DIR/.env" "$TMP/original.env"
  image="ghcr.io/$REPO:$VERSION"
  notice "Downloading $image before modifying the running service."
  docker pull "$image" || die 'Could not pull the pinned release image.'
  ROLLBACK=1
  # Edit only the version key. All other credentials and configuration remain.
  sed -i "s/^LITEEDGE_VERSION=.*/LITEEDGE_VERSION=$VERSION/" "$COMPOSE_DIR/.env"
  (cd "$COMPOSE_DIR" && docker compose config -q && docker compose up -d) ||
    die 'Docker Compose activation failed.'
  cid="$(cd "$COMPOSE_DIR" && docker compose ps -q liteedge)"
  [[ -n "$cid" ]] || die 'Cannot find the LiteEdge container after upgrade.'
  for ((attempt=0; attempt<45; attempt++)); do
    state="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || true)"
    if [[ "$state" == true && ( "$health" == healthy || "$health" == none ) ]]; then
      ROLLBACK=0
      notice "$VERSION active in Docker. Existing .env, Compose, and ./data preserved."
      return
    fi
    [[ "$health" != unhealthy ]] || die 'New container health check failed.'
    sleep 2
  done
  die 'New container did not become healthy.'
}

upgrade_alpine() {
  [[ "$(id -u)" -eq 0 ]] || die 'Native Alpine upgrade requires root.'
  command -v apk >/dev/null 2>&1 || die 'Native mode requires Alpine Linux.'
  command -v curl >/dev/null 2>&1 || die 'curl is required.'
  command -v rc-service >/dev/null 2>&1 || die 'OpenRC is required.'
  command -v setcap >/dev/null 2>&1 || die 'setcap (libcap) is required.'
  [[ -d /opt/liteedge && -s /opt/liteedge/VERSION && -f /etc/init.d/liteedge ]] ||
    die 'LiteEdge standalone runtime is not installed.'
  [[ -d /var/lib/liteedge && -s /etc/conf.d/liteedge ]] ||
    die 'Existing standalone persistent state/config not found.'
  [[ "$(uname -m)" == x86_64 ]] || die 'v3.1.5 currently publishes x86_64 standalone binaries.'
  OLD_VERSION="$(sed -n 's/^LiteEdge=//p' /opt/liteedge/VERSION | head -n1)"
  [[ -n "$OLD_VERSION" ]] || die 'Cannot read the installed LiteEdge version.'
  compare_versions "$OLD_VERSION"
  TMP="$(mktemp -d /opt/.liteedge-upgrade.XXXXXXXX)"
  local asset=liteedge-linux-musl-x86_64.tar.gz base="$TMP/stage" src
  mkdir -p "$base"
  src="https://github.com/$REPO/releases/download/$VERSION"
  notice "Downloading and verifying $VERSION Alpine runtime."
  curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$TMP/$asset" "$src/$asset"
  curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$TMP/$asset.sha256" "$src/$asset.sha256"
  (cd "$TMP" && sha256sum -c "$asset.sha256") || die 'Release checksum mismatch.'
  # Reject malformed bundle layouts before the first service interruption.
  if tar -tzf "$TMP/$asset" | grep -Ev '^(opt/|opt/liteedge(/|$))' >/dev/null; then
    die 'Unexpected paths in release bundle.'
  fi
  tar -xzf "$TMP/$asset" -C "$base"
  [[ -x "$base/opt/liteedge/sbin/nginx" && -x "$base/opt/liteedge/entrypoint.sh" &&
     -f "$base/opt/liteedge/share/openrc/liteedge" ]] ||
    die 'Release archive lacks required runtime files.'
  grep -qx "LiteEdge=${VERSION#v}" "$base/opt/liteedge/VERSION" ||
    die 'Release archive version does not match requested upgrade.'
  LD_LIBRARY_PATH="$base/opt/liteedge/lib" "$base/opt/liteedge/sbin/nginx" -V 2>&1 |
    grep -q 'ModSecurity-nginx' || die 'Release NGINX has no ModSecurity connector.'
  if rc-service liteedge status >/dev/null 2>&1; then OLD_RUNNING=1; fi
  INIT_BACKUP="$TMP/previous-openrc"
  cp -p /etc/init.d/liteedge "$INIT_BACKUP"
  [[ "$OLD_RUNNING" == 0 ]] || rc-service liteedge stop || die 'Could not stop existing LiteEdge service.'
  BACKUP="$TMP/previous"
  ROLLBACK=1
  mv /opt/liteedge "$BACKUP"
  mv "$base/opt/liteedge" /opt/liteedge
  install -m 0755 /opt/liteedge/share/openrc/liteedge /etc/init.d/liteedge
  ln -sfn /opt/liteedge/lib/libmodsecurity.so.3 /usr/local/lib/libmodsecurity.so.3
  ln -sfn /opt/liteedge/lib/libmodsecurity.so /usr/local/lib/libmodsecurity.so
  setcap cap_net_bind_service=+ep /opt/liteedge/sbin/nginx
  if [[ "$START" == 1 ]]; then
    rc-service liteedge start || die 'New LiteEdge service failed to start.'
    sleep 2
    rc-service liteedge status >/dev/null 2>&1 || die 'New LiteEdge service is not running.'
    if [[ -f /var/lib/liteedge/nginx/nginx.conf ]]; then
      LD_LIBRARY_PATH=/opt/liteedge/lib /opt/liteedge/sbin/nginx -t \
        -c /var/lib/liteedge/nginx/nginx.conf || die 'New NGINX runtime configuration failed validation.'
    fi
  fi
  ROLLBACK=0
  notice "$VERSION installed on Alpine; /var/lib/liteedge and /etc/conf.d/liteedge preserved."
}
case "$MODE" in docker) upgrade_docker ;; alpine) upgrade_alpine ;; esac