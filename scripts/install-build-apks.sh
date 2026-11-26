#!/bin/sh
# Bootstrap build-only packages before the offline staging step. Keep a
# coherent repository set; retry only the package transport, not build tests.
install_build_apks() {
    primary="${ALPINE_APK_MIRROR:-https://dl-2.alpinelinux.org/alpine}"
    primary="${primary%/}"
    case "$primary" in https://*) ;; *) echo 'ALPINE_APK_MIRROR must use HTTPS' >&2; return 1 ;; esac
    for mirror in "$primary" https://dl-cdn.alpinelinux.org/alpine https://mirror.clarkson.edu/alpine; do
        repo="$mirror/v${ALPINE_VERSION:-3.22}"
        printf '%s\n' "$repo/main" "$repo/community" >/etc/apk/repositories
        echo "Build APK mirror: $mirror"
        if timeout 180 apk --timeout 20 add --no-cache "$@"; then
            # Also used by the ISO staging resolver.
            export repo
            return 0
        fi
        echo "Build package installation failed at $mirror; trying next mirror" >&2
    done
    return 1
}
