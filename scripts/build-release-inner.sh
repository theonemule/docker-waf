#!/bin/sh
set -eu
apk add --no-cache \
  bash build-base linux-headers autoconf automake libtool pkgconf git curl tar xz \
  coreutils findutils perl file \
  pcre2-dev openssl-dev zlib-dev libxml2-dev yajl-dev lmdb-dev curl-dev \
  libmaxminddb-dev lua5.3-dev
exec /bin/bash /src/scripts/build-release-alpine.sh
