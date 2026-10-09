#!/usr/bin/env bash
set -euo pipefail
ROOT=/src
# shellcheck disable=SC1091
source "$ROOT/build/versions.env"
VERSION="${VERSION:?VERSION is required}"
BUILD_JOBS="${BUILD_JOBS:-1}"
[[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid BUILD_JOBS: $BUILD_JOBS" >&2; exit 1; }
ARCH="$(uname -m)"
case "$ARCH" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/src"
PKG="$WORK/pkg"
PREFIX="$PKG/opt/liteedge"
mkdir -p "$SRC" "$PREFIX"/{bin,sbin,lib,etc/nginx,etc/modsecurity,etc/crs,ui,cgi,share,licenses}
fetch_git() {
  local url="$1" commit="$2" dest="$3"
  git init -q "$dest"
  git -C "$dest" remote add origin "$url"
  git -C "$dest" fetch -q --depth 1 origin "$commit"
  git -C "$dest" checkout -q FETCH_HEAD
}
echo "Building LiteEdge $VERSION for linux-musl-$ARCH"
echo "[1/6] ModSecurity ${MODSECURITY_VERSION}"
fetch_git https://github.com/owasp-modsecurity/ModSecurity.git "$MODSECURITY_COMMIT" "$SRC/ModSecurity"
git -C "$SRC/ModSecurity" submodule update --init --recursive --depth 1
(
  cd "$SRC/ModSecurity"
  ./build.sh
  ./configure --prefix=/opt/liteedge --disable-static --with-lua
  make -j"$BUILD_JOBS"
  make DESTDIR="$PKG" install
)
echo "[2/6] ModSecurity-nginx ${MODSECURITY_NGINX_VERSION}"
fetch_git https://github.com/owasp-modsecurity/ModSecurity-nginx.git "$MODSECURITY_NGINX_COMMIT" "$SRC/ModSecurity-nginx"
echo "[3/6] NGINX ${NGINX_VERSION}"
curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o "$WORK/nginx.tar.gz"
echo "${NGINX_SHA256}  $WORK/nginx.tar.gz" | sha256sum -c -
tar -xzf "$WORK/nginx.tar.gz" -C "$SRC"
(
  cd "$SRC/nginx-${NGINX_VERSION}"
  NGX_IGNORE_RPATH=YES MODSECURITY_INC="$PREFIX/include" MODSECURITY_LIB="$PREFIX/lib" \
  ./configure \
    --prefix=/opt/liteedge \
    --sbin-path=/opt/liteedge/sbin/nginx \
    --conf-path=/opt/liteedge/etc/nginx/nginx.conf \
    --pid-path=/run/liteedge/nginx.pid \
    --lock-path=/run/liteedge/nginx.lock \
    --error-log-path=/dev/stderr \
    --http-log-path=/dev/stdout \
    --http-client-body-temp-path=/tmp/liteedge-run/client_temp \
    --http-proxy-temp-path=/tmp/liteedge-run/proxy_temp \
    --http-fastcgi-temp-path=/tmp/liteedge-run/fastcgi_temp \
    --http-uwsgi-temp-path=/tmp/liteedge-run/uwsgi_temp \
    --http-scgi-temp-path=/tmp/liteedge-run/scgi_temp \
    --with-threads \
    --with-file-aio \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_gzip_static_module \
    --with-http_stub_status_module \
    --with-pcre-jit \
    --without-http_autoindex_module \
    --without-http_ssi_module \
    --add-module="$SRC/ModSecurity-nginx"
  make -j"$BUILD_JOBS"
  install -m 0755 objs/nginx "$PREFIX/sbin/nginx"
  install -m 0644 conf/mime.types "$PREFIX/etc/nginx/mime.types"
  install -m 0644 conf/fastcgi_params "$PREFIX/etc/nginx/fastcgi_params"
)
echo "[4/6] OWASP CRS ${CRS_VERSION}"
fetch_git https://github.com/coreruleset/coreruleset.git "$CRS_COMMIT" "$SRC/coreruleset"
cp "$SRC/coreruleset/crs-setup.conf.example" "$PREFIX/etc/crs/crs-setup.conf"
cp -a "$SRC/coreruleset/rules" "$PREFIX/etc/crs/rules"
cp "$PREFIX/etc/crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf.example" \
   "$PREFIX/etc/crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf"
cp "$PREFIX/etc/crs/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf.example" \
   "$PREFIX/etc/crs/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf"
echo "[5/6] dehydrated ${DEHYDRATED_VERSION} + LiteEdge runtime"
fetch_git https://github.com/dehydrated-io/dehydrated.git "$DEHYDRATED_COMMIT" "$SRC/dehydrated"
install -m 0755 "$SRC/dehydrated/dehydrated" "$PREFIX/bin/dehydrated"
install -m 0644 "$SRC/ModSecurity/modsecurity.conf-recommended" "$PREFIX/etc/modsecurity/modsecurity.conf.template"
install -m 0644 "$SRC/ModSecurity/unicode.mapping" "$PREFIX/etc/modsecurity/unicode.mapping"
sed -i \
  -e 's/^SecRuleEngine .*/SecRuleEngine On/' \
  -e 's#^SecAuditLog .*#SecAuditLog @DATA_DIR@/logs/modsec_audit.json#' \
  -e 's#^SecUnicodeMapFile .*#SecUnicodeMapFile /opt/liteedge/etc/modsecurity/unicode.mapping 20127#' \
  "$PREFIX/etc/modsecurity/modsecurity.conf.template"
printf '\nSecAuditLogFormat JSON\nSecAuditLogType Serial\nSecAuditLogParts AFHZ\nSecAuditEngine RelevantOnly\nSecTmpDir @RUN_DIR@\nSecDataDir @RUN_DIR@\n' >> "$PREFIX/etc/modsecurity/modsecurity.conf.template"
cp -a "$ROOT/bin/." "$PREFIX/bin/"
cp -a "$ROOT/cgi/." "$PREFIX/cgi/"
cp -a "$ROOT/ui/." "$PREFIX/ui/"
curl -fsSL --retry 3 "https://cdn.jsdelivr.net/npm/bootstrap@${BOOTSTRAP_VERSION}/dist/css/bootstrap.min.css" -o "$PREFIX/ui/bootstrap.min.css"
echo "${BOOTSTRAP_SHA256}  $PREFIX/ui/bootstrap.min.css" | sha256sum -c -
install -m 0755 "$ROOT/entrypoint.sh" "$PREFIX/entrypoint.sh"
install -m 0644 "$ROOT/nginx/nginx.conf" "$PREFIX/etc/nginx/nginx.conf"
install -m 0644 "$ROOT/nginx/logrotate-observability.conf" "$PREFIX/etc/logrotate-observability.conf"
install -m 0644 "$ROOT/nginx/admin.conf" "$PREFIX/etc/nginx/admin.conf.template"
install -m 0644 "$ROOT/nginx/admin-http.conf" "$PREFIX/etc/nginx/admin-http.conf.template"
install -m 0644 "$ROOT/nginx/security.conf" "$PREFIX/etc/nginx/security.conf"
install -m 0644 "$ROOT/nginx/modsecurity.conf" "$PREFIX/etc/nginx/modsecurity-main.conf.template"
install -m 0644 "$ROOT/nginx/modsecurity-wordpress.conf" "$PREFIX/etc/nginx/modsecurity-wordpress.conf.template"
chmod 0755 "$PREFIX"/bin/*.sh "$PREFIX"/cgi/*.sh "$PREFIX"/entrypoint.sh "$PREFIX"/bin/dehydrated
install -d -m 0755 "$PREFIX/share/openrc"
install -m 0755 "$ROOT/packaging/openrc/liteedge" "$PREFIX/share/openrc/liteedge"
install -m 0755 "$ROOT/scripts/install-alpine.sh" "$PREFIX/share/install-alpine.sh"
install -m 0644 "$ROOT/registry/crs-plugin-registry.tsv" "$PREFIX/share/crs-plugin-registry.tsv"
install -m 0644 "$ROOT/registry/crs-rule-parser.awk" "$PREFIX/share/crs-rule-parser.awk"
install -m 0644 "$ROOT/license.txt" "$PREFIX/licenses/LiteEdge.txt"
for item in   "$SRC/ModSecurity/LICENSE:ModSecurity.txt"   "$SRC/ModSecurity-nginx/LICENSE:ModSecurity-nginx.txt"   "$SRC/coreruleset/LICENSE:OWASP-CRS.txt"   "$SRC/dehydrated/LICENSE:dehydrated.txt"; do
  source_file="${item%%:*}"
  target_name="${item#*:}"
  [[ -f "$source_file" ]] && install -m 0644 "$source_file" "$PREFIX/licenses/$target_name"
done
rm -rf "$PREFIX/include" "$PREFIX/lib/pkgconfig" "$PREFIX/share/doc" "$PREFIX/share/man"
find "$PREFIX/lib" -type f -name '*.la' -delete
strip --strip-unneeded "$PREFIX/sbin/nginx" || true
find "$PREFIX/lib" -type f -name '*.so*' -exec strip --strip-unneeded {} + 2>/dev/null || true
cat > "$PREFIX/VERSION" <<META
LiteEdge=${VERSION}
Alpine=${ALPINE_VERSION}
NGINX=${NGINX_VERSION}
ModSecurity=${MODSECURITY_VERSION}
ModSecurity-nginx=${MODSECURITY_NGINX_VERSION}
CRS=${CRS_VERSION}
dehydrated=${DEHYDRATED_VERSION}
Architecture=${ARCH}
META
cat > "$PREFIX/RUNTIME-PACKAGES" <<'EOF_RUNTIME'
bash
ca-certificates
curl
openssl
tzdata
fcgiwrap
spawn-fcgi
pcre2
libxml2
yajl
lmdb
libcurl
libstdc++
libgcc
zlib
diffutils
patch
libmaxminddb
lua5.3-libs
jq
socat
logrotate
EOF_RUNTIME
{
  cat "$ROOT/build/versions.env"
  echo "LITEEDGE_VERSION=$VERSION"
  echo "ARCH=$ARCH"
} > "$PREFIX/BUILD-MANIFEST"
echo "[6/6] validating and packaging"
export LD_LIBRARY_PATH="$PREFIX/lib"
"$PREFIX/sbin/nginx" -V 2>&1 | tee "$PREFIX/NGINX-BUILD.txt"
grep -q -- '--add-module=.*/ModSecurity-nginx' "$PREFIX/NGINX-BUILD.txt" || { echo "NGINX build does not show the ModSecurity connector." >&2; exit 1; }
ldd "$PREFIX/lib/libmodsecurity.so.3" | tee "$PREFIX/MODSECURITY-LDD.txt"
grep -Eq 'liblua-5\.3\.so' "$PREFIX/MODSECURITY-LDD.txt" || { echo "ModSecurity build does not link Lua 5.3." >&2; exit 1; }
echo 'Lua=5.3' >> "$PREFIX/VERSION"
mkdir -p "$ROOT/dist"
ARTIFACT="$ROOT/dist/liteedge-linux-musl-${ARCH}.tar.gz"
tar --numeric-owner --owner=0 --group=0 -C "$PKG" -czf "$ARTIFACT" opt/liteedge
( cd "$ROOT/dist" && sha256sum "$(basename "$ARTIFACT")" > "$(basename "$ARTIFACT").sha256" )
echo "Created $ARTIFACT"
