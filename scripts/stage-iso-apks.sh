#!/bin/sh
# Stage a signed, complete Alpine package closure before mkimage uses it.
# The original APK signatures remain intact; the temporary index is signed
# with the per-build ISO key, never with an untrusted package flag.
set -eu
if [ "${1:-}" = fetch-one ]; then
    url="$2"
    case "$url" in "$APK_SOURCE_REPO"/main/x86_64/*.apk|"$APK_SOURCE_REPO"/community/x86_64/*.apk) ;; *)
        echo "Unexpected APK URL: $url" >&2; exit 1 ;;
    esac
    relative="${url#"$APK_SOURCE_REPO"/}"
    name="${relative##*/}"
    dest="$APK_STAGE/$name"
    part="$dest.part"
    for base in "$APK_SOURCE_REPO" "$APK_FALLBACK_REPO" "$APK_THIRD_REPO"; do
        rm -f "$part"
        if curl --fail --location --silent --show-error --connect-timeout 5 \
            --speed-limit 1024 --speed-time 15 --max-time 180 \
            "$base/$relative" -o "$part" && apk verify "$part" >/dev/null; then
            mv "$part" "$dest"
            printf 'Verified %s from %s\n' "$name" "$base"
            exit 0
        fi
        echo "Retrying $name after failure at $base" >&2
    done
    rm -f "$part"
    echo "Unable to obtain verified package $name" >&2
    exit 1
fi
[ "$#" = 4 ] || { echo "Usage: $0 repository-base profile aports-scripts output-repository" >&2; exit 2; }
APK_SOURCE_REPO="$1"
profile="$2"
aports="$3"
target="$4"
APK_FALLBACK_REPO="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION:-3.22}"
APK_THIRD_REPO="https://mirror.clarkson.edu/alpine/v${ALPINE_VERSION:-3.22}"
APK_STAGE="$target/x86_64"
export APK_SOURCE_REPO APK_FALLBACK_REPO APK_THIRD_REPO APK_STAGE
mkdir -p "$APK_STAGE"
# Evaluate precisely the same upstream and custom profile used by mkimage.
# Upstream profile functions rely on unset optional variables.
packages="$(sh -e -c '
    ARCH=x86_64
    . "$1/mkimg.base.sh"
    . "$1/mkimg.standard.sh"
    . "$1/mkimg.liteedge.sh"
    "profile_$2"
    printf "%s " $apks alpine-base syslinux grub-efi linux-firmware wireless-regdb $modloop_addons $boot_addons
    for k in $kernel_flavors; do
        printf "linux-%s " "$k"
        for a in $kernel_addons; do printf "%s-%s " "$a" "$k"; done
    done
' sh "$aports" "$profile")"
# Keep dependency selection tied to the signed indexes from one coherent mirror.
apk --timeout 15 update
# shellcheck disable=SC2086
apk fetch --from repositories --recursive --url $packages >"$target/package-urls.txt"
test -s "$target/package-urls.txt"
sort -u "$target/package-urls.txt" -o "$target/package-urls.txt"
echo "Staging $(wc -l <"$target/package-urls.txt") signed packages for $profile"
# xargs reports any failed child. Never create an index after a partial fetch.
xargs -r -P 6 -n 1 /bin/sh /src/scripts/stage-iso-apks.sh fetch-one <"$target/package-urls.txt"
expected="$(wc -l <"$target/package-urls.txt" | tr -d ' ')"
actual="$(find "$APK_STAGE" -name '*.apk' | wc -l | tr -d ' ')"
[ "$expected" = "$actual" ] || { echo "Staged package count mismatch: $actual/$expected" >&2; exit 1; }
apk index --rewrite-arch x86_64 --description "LiteEdge verified Alpine staging repository" --output "$APK_STAGE/APKINDEX.tar.gz" "$APK_STAGE"/*.apk
abuild-sign "$APK_STAGE/APKINDEX.tar.gz"
# Check dependency resolution without reaching any public mirror.
verify_root="$target/verify-root"
mkdir -p "$verify_root/etc/apk/keys"
cp /etc/apk/keys/* "$verify_root/etc/apk/keys/"
printf '%s\n' "$target" >"$verify_root/etc/apk/repositories"
apk --root "$verify_root" --no-network add --initdb --no-scripts >/dev/null
apk --root "$verify_root" --no-network update >/dev/null
# shellcheck disable=SC2086
apk --root "$verify_root" --no-network fetch --recursive --simulate $packages >/dev/null
rm -rf "$verify_root"
echo "PASS staged $actual verified Alpine packages; local dependency closure complete"
