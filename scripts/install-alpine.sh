#!/bin/sh
set -eu

REPO="${LITEEDGE_REPO:-theonemule/docker-waf}"
VERSION="${LITEEDGE_VERSION:-latest}"
START=1
GENERATED_PASSWORD=""
OFFLINE_DIR=""

usage() {
  cat <<USAGE
Usage: $0 [--version TAG|latest] [--repo OWNER/REPO] [--no-start]
       $0 --offline-dir /etc/liteedge-offline [--no-start]

Installs the complete prebuilt LiteEdge release on Alpine Linux. The release
contains NGINX with the ModSecurity connector compiled in, libModSecurity,
OWASP CRS, dehydrated, the shell control/API scripts, and the management UI.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --no-start) START=0; shift ;;
    --offline-dir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; OFFLINE_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || {
  echo "Run this installer as root." >&2
  exit 1
}

command -v apk >/dev/null 2>&1 || {
  echo "This installer is for Alpine Linux." >&2
  exit 1
}

case "$(uname -m)" in
  x86_64) ARCH=x86_64 ;;
  aarch64) echo "aarch64 release artifacts are not published yet; this installer supports x86_64 only." >&2; exit 1 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# The offline ISO includes all runtime dependencies in /etc/apk/world and
# installs them from its signed, on-media APK repository during setup-disk.
# On first boot the ISO is removed, so the installer must never use a network
# repository or download a GitHub release in offline mode.
RUNTIME_PACKAGES="bash ca-certificates curl openssl tzdata fcgiwrap spawn-fcgi pcre2 libxml2 yajl lmdb libcurl libstdc++ libgcc zlib libmaxminddb coreutils diffutils patch lua5.3-libs jq socat logrotate libcap openrc"
if [ -n "$OFFLINE_DIR" ]; then
  [ -d "$OFFLINE_DIR" ] || { echo "Offline directory missing: $OFFLINE_DIR" >&2; exit 1; }
  for package in $RUNTIME_PACKAGES; do
    apk info -e "$package" >/dev/null 2>&1 || {
      echo "Required offline dependency is not installed: $package" >&2; exit 1;
    }
  done
  ASSET="liteedge-linux-musl-${ARCH}.tar.gz"
  if [ ! -s "$OFFLINE_DIR/$ASSET" ] || [ ! -s "$OFFLINE_DIR/$ASSET.sha256" ]; then
    echo 'Bundled LiteEdge archive or checksum missing.' >&2; exit 1;
  fi
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT HUP INT TERM
  cp "$OFFLINE_DIR/$ASSET" "$OFFLINE_DIR/$ASSET.sha256" "$TMP/"
  VERSION="offline-iso"
else
  # shellcheck disable=SC2086
  apk add --no-cache $RUNTIME_PACKAGES
  if [ "$VERSION" = "latest" ]; then
    VERSION="$(
      curl -fsSL --proto '=https' --tlsv1.2 \
        "https://api.github.com/repos/$REPO/releases/latest" |
        sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n1
    )"
    [ -n "$VERSION" ] || {
      echo "Could not determine latest release for $REPO." >&2
      exit 1
    }
  fi
  ASSET="liteedge-linux-musl-${ARCH}.tar.gz"
  BASE_URL="https://github.com/$REPO/releases/download/$VERSION"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT HUP INT TERM
  curl -fL --retry 3 --proto '=https' --tlsv1.2 \
    -o "$TMP/$ASSET" "$BASE_URL/$ASSET"
  curl -fL --retry 3 --proto '=https' --tlsv1.2 \
    -o "$TMP/$ASSET.sha256" "$BASE_URL/$ASSET.sha256"
fi
(cd "$TMP" && sha256sum -c "$ASSET.sha256")

was_running=0
if rc-service liteedge status >/dev/null 2>&1; then
  was_running=1
  rc-service liteedge stop
fi

tar -C / -xzf "$TMP/$ASSET"

if ! getent group liteedge >/dev/null 2>&1; then
  addgroup -S liteedge
fi
if ! id liteedge >/dev/null 2>&1; then
  adduser -S -D -H -s /sbin/nologin -G liteedge liteedge
fi

install -d -o liteedge -g liteedge -m 0750 \
  /var/lib/liteedge \
  /var/lib/liteedge/auth \
  /var/lib/liteedge/certs \
  /var/lib/liteedge/acme \
  /var/lib/liteedge/logs \
  /var/lib/liteedge/nginx \
  /var/lib/liteedge/run
install -d -o liteedge -g liteedge -m 0755 \
  /var/lib/liteedge/sites \
  /var/lib/liteedge/www

chown -R liteedge:liteedge /var/lib/liteedge

# A file capability makes the dynamic loader enter secure mode, where
# LD_LIBRARY_PATH is ignored. Expose the bundled libModSecurity SONAME through
# Alpine's trusted /usr/local/lib search path before granting bind-service.
ln -sfn /opt/liteedge/lib/libmodsecurity.so.3 /usr/local/lib/libmodsecurity.so.3
ln -sfn /opt/liteedge/lib/libmodsecurity.so /usr/local/lib/libmodsecurity.so

setcap cap_net_bind_service=+ep /opt/liteedge/sbin/nginx

install -m 0755 /opt/liteedge/share/openrc/liteedge /etc/init.d/liteedge

if [ ! -f /etc/conf.d/liteedge ]; then
  GENERATED_PASSWORD="$(openssl rand -hex 24)"
  cat > /etc/conf.d/liteedge <<CONF
export DATA_DIR=/var/lib/liteedge
export LITEEDGE_RUN_DIR=/var/lib/liteedge/run
export ADMIN_USER=admin
export ADMIN_PASSWORD='$GENERATED_PASSWORD'
export ACME_EMAIL=''
export LITEEDGE_HTTP_PORT=80
export LITEEDGE_HTTPS_PORT=443
export LITEEDGE_ADMIN_HTTPS_PORT=8443
export LITEEDGE_BIND_ADDRESS=0.0.0.0
export LITEEDGE_PUBLIC_HTTPS_PORT=443
CONF
  chmod 0600 /etc/conf.d/liteedge
fi

LD_LIBRARY_PATH=/opt/liteedge/lib /opt/liteedge/sbin/nginx -V 2>&1 | grep -q 'ModSecurity-nginx'
test -x /opt/liteedge/bin/dehydrated
test -x /opt/liteedge/entrypoint.sh
test -x /opt/liteedge/cgi/admin.sh

rc-update add liteedge default >/dev/null

if [ "$START" -eq 1 ]; then
  if [ "$was_running" -eq 1 ]; then
    rc-service liteedge restart
  else
    rc-service liteedge start
  fi
fi

echo "Installed LiteEdge $VERSION for linux-musl-$ARCH."
echo "State: /var/lib/liteedge"
echo "Configuration: /etc/conf.d/liteedge"
if [ -n "$GENERATED_PASSWORD" ]; then
  echo "Admin user: admin"
  echo "Admin password: $GENERATED_PASSWORD"
fi
