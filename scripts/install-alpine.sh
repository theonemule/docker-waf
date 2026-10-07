#!/bin/sh
set -eu

REPO="${LITEEDGE_REPO:-theonemule/docker-waf}"
VERSION="${LITEEDGE_VERSION:-latest}"
START=1
GENERATED_PASSWORD=""

usage() {
  cat <<USAGE
Usage: $0 [--version TAG|latest] [--repo OWNER/REPO] [--no-start]

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
  x86_64|aarch64) ARCH="$(uname -m)" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

apk add --no-cache \
  bash ca-certificates curl openssl \
  fcgiwrap spawn-fcgi \
  pcre2 libxml2 yajl lmdb libcurl libstdc++ libgcc zlib libmaxminddb \
  coreutils diffutils patch lua5.3-libs jq libcap openrc

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

(
  cd "$TMP"
  sha256sum -c "$ASSET.sha256"
)

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
