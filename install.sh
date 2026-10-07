#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required." >&2
  exit 1
}
docker compose version >/dev/null 2>&1 || {
  echo "Docker Compose v2 is required." >&2
  exit 1
}
command -v openssl >/dev/null 2>&1 || {
  echo "OpenSSL is required by the installer." >&2
  exit 1
}

mkdir -p data
chmod 750 data

uid="$(id -u)"
gid="$(id -g)"
if [[ "$uid" == 0 ]]; then
  uid=10001
  gid=10001
  chown "$uid:$gid" data
fi

if [[ ! -f .env ]]; then
  password="$(openssl rand -hex 24)"
  cat > .env <<ENV
ADMIN_USER=admin
ADMIN_PASSWORD=$password
ACME_EMAIL=
TZ=UTC
LITEEDGE_VERSION=latest
LITEEDGE_REPO=theonemule/docker-waf
LITEEDGE_UID=$uid
LITEEDGE_GID=$gid
ENV
  chmod 600 .env
  echo "Created .env"
  echo "Admin user: admin"
  echo "Admin password: $password"
  echo "Set ACME_EMAIL in .env before using Let's Encrypt."
else
  grep -q '^LITEEDGE_VERSION=' .env || printf '\nLITEEDGE_VERSION=latest\n' >> .env
  grep -q '^LITEEDGE_REPO=' .env || printf 'LITEEDGE_REPO=theonemule/docker-waf\n' >> .env
  grep -q '^LITEEDGE_UID=' .env || printf 'LITEEDGE_UID=%s\n' "$uid" >> .env
  grep -q '^LITEEDGE_GID=' .env || printf 'LITEEDGE_GID=%s\n' "$gid" >> .env
fi

docker compose pull
docker compose up -d

echo
echo "LiteEdge is running on host ports 80 and 443."
echo "Open https://<server-ip>/"
