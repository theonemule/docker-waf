#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# The released installer has its originating v3 tag baked in by CI. A cloned
# checkout already has docker-compose.yml and does not need a release download.
release_tag="${LITEEDGE_INSTALL_RELEASE_TAG:-__LITEEDGE_RELEASE_TAG__}"
# Split this literal so the release job only replaces the assignment above.
# Check equality, not substring presence: valid versions can contain the marker text.
release_placeholder="__LITEEDGE_"'RELEASE_TAG__'
default_version=latest
if [[ "$release_tag" != "$release_placeholder" ]]; then
  [[ "$release_tag" =~ ^v3\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
    echo "Invalid LiteEdge release tag: $release_tag" >&2
    exit 1
  }
  default_version="$release_tag"
fi

if [[ ! -f docker-compose.yml ]]; then
  if [[ "$release_tag" == "$release_placeholder" ]]; then
    echo "docker-compose.yml is missing. Use a repository checkout or a published v3 installer." >&2
    exit 1
  fi
  command -v curl >/dev/null 2>&1 || { echo "curl is required to download Compose." >&2; exit 1; }
  repo="${LITEEDGE_REPO:-theonemule/docker-waf}"
  if [[ -z "${LITEEDGE_REPO:-}" && -f .env ]]; then
    configured_repo="$(sed -n 's/^LITEEDGE_REPO=//p' .env | head -n 1)"
    [[ -z "$configured_repo" ]] || repo="$configured_repo"
  fi
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "Invalid LITEEDGE_REPO: $repo" >&2
    exit 1
  }
  tmp="$(mktemp -d ./.liteedge-compose.XXXXXXXX)"
  trap 'rm -rf "$tmp"' EXIT
  base="https://github.com/$repo/releases/download/$release_tag"
  curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$tmp/docker-compose.yml" "$base/docker-compose.yml"
  curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$tmp/docker-compose.yml.sha256" "$base/docker-compose.yml.sha256"
  ( cd "$tmp" && sha256sum -c docker-compose.yml.sha256 )
  mv "$tmp/docker-compose.yml" docker-compose.yml
  rm -rf "$tmp"
  trap - EXIT
fi

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
LITEEDGE_VERSION=$default_version
LITEEDGE_REPO=${LITEEDGE_REPO:-theonemule/docker-waf}
LITEEDGE_UID=$uid
LITEEDGE_GID=$gid
LITEEDGE_ADMIN_HTTP_ONLY=0
ENV
  chmod 600 .env
  echo "Created .env"
  echo "Admin user: admin"
  echo "Admin password: $password"
  echo "Set ACME_EMAIL in .env before using Let's Encrypt."
else
  grep -q '^LITEEDGE_VERSION=' .env || printf '\nLITEEDGE_VERSION=%s\n' "$default_version" >> .env
  grep -q '^LITEEDGE_REPO=' .env || printf 'LITEEDGE_REPO=theonemule/docker-waf\n' >> .env
  grep -q '^LITEEDGE_UID=' .env || printf 'LITEEDGE_UID=%s\n' "$uid" >> .env
  grep -q '^LITEEDGE_GID=' .env || printf 'LITEEDGE_GID=%s\n' "$gid" >> .env
fi

docker compose pull
docker compose up -d

echo
echo "LiteEdge is running on host ports 80 and 443."
echo "Open https://<server-ip>/"