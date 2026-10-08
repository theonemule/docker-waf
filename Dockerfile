ARG ALPINE_VERSION=3.22
ARG ALPINE_DIGEST=sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8

FROM alpine:${ALPINE_VERSION}@${ALPINE_DIGEST}

ARG LITEEDGE_ARCH=x86_64

RUN apk add --no-cache bash ca-certificates curl openssl tzdata fcgiwrap spawn-fcgi pcre2 libxml2 yajl lmdb libcurl libstdc++ libgcc zlib libmaxminddb coreutils diffutils patch lua5.3-libs jq && addgroup -g 10001 -S liteedge && adduser -S -D -H -u 10001 -G liteedge liteedge && mkdir -p /data && chown 10001:10001 /data

COPY dist/liteedge-linux-musl-${LITEEDGE_ARCH}.tar.gz /tmp/liteedge.tar.gz
COPY dist/liteedge-linux-musl-${LITEEDGE_ARCH}.tar.gz.sha256 /tmp/liteedge.tar.gz.sha256

RUN set -eux; cd /tmp; sed -i 's#liteedge-linux-musl-[^ ]*\.tar\.gz#liteedge.tar.gz#' liteedge.tar.gz.sha256; sha256sum -c liteedge.tar.gz.sha256; tar -C / -xzf liteedge.tar.gz; rm -f liteedge.tar.gz liteedge.tar.gz.sha256; test -x /opt/liteedge/sbin/nginx; test -x /opt/liteedge/entrypoint.sh; LD_LIBRARY_PATH=/opt/liteedge/lib /opt/liteedge/sbin/nginx -V 2>&1 | grep -q 'ModSecurity-nginx'

ENV PATH=/opt/liteedge/bin:/opt/liteedge/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LD_LIBRARY_PATH=/opt/liteedge/lib DATA_DIR=/data LITEEDGE_RUN_DIR=/tmp/liteedge-run LITEEDGE_HTTP_PORT=8080 LITEEDGE_HTTPS_PORT=8443 LITEEDGE_BIND_ADDRESS=0.0.0.0 LITEEDGE_PUBLIC_HTTPS_PORT=443

USER 10001:10001
VOLUME ["/data"]
EXPOSE 8080 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD if [ "${LITEEDGE_ADMIN_HTTP_ONLY:-0}" = "1" ]; then code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)"; else code="$(curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/)"; fi; test "$code" = "401"

ENTRYPOINT ["/opt/liteedge/entrypoint.sh"]
