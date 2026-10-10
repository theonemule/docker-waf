#!/bin/sh
set -eu
apk add --no-cache \
    git openssl ca-certificates alpine-conf abuild apk-tools \
    fakeroot syslinux xorriso squashfs-tools grub mtools \
    coreutils findutils bash tar gzip
export PACKAGER="LiteEdge Build <build@liteedge.invalid>"
# Generated keys sign the ISO's on-media APK index, never bundled as private.
abuild-keygen -a -n >/dev/null
cp /root/.abuild/*.rsa.pub /etc/apk/keys/
PACKAGER_PRIVKEY="$(find /root/.abuild -maxdepth 1 -name '*.rsa' | head -n1)"
export PACKAGER_PRIVKEY
[ -s "$PACKAGER_PRIVKEY" ]
out=/src/dist
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Use the official GitHub Alpine aports mirror to avoid GitLab HTTP 418 in CI.
git clone -q --depth 1 --filter=blob:none --sparse --branch "$APORTS_REF" \
    https://github.com/alpinelinux/aports.git "$work/aports"
git -C "$work/aports" sparse-checkout set scripts
cp /src/scripts/mkimg.liteedge.sh "$work/aports/scripts/mkimg.liteedge.sh"
cp /src/scripts/genapkovl-liteedge.sh "$work/aports/scripts/genapkovl-liteedge.sh"
cd "$work/aports/scripts"
./mkimage.sh \
    --tag "$VERSION" \
    --outdir "$out" \
    --workdir "$work/build" \
    --arch x86_64 \
    --profile liteedge \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v3.22/main" \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v3.22/community"
output="$out/liteedge-vm-installer-${VERSION}-x86_64.iso"
test -s "$output"
(cd "$out" && sha256sum "$(basename "$output")" > "$(basename "$output").sha256")
# Verify native hybrid El Torito boot records (both BIOS and UEFI).
xorriso -indev "$output" -report_el_torito plain 2>&1 | tee "$out/vm-iso-validation.log"
grep -Eq 'BIOS|BIOS_boot' "$out/vm-iso-validation.log"
grep -Eq 'UEFI|EFI' "$out/vm-iso-validation.log"
# Verify the embedded offline payload is present on the finished medium.
mkdir -p "$work/verify"
xorriso -osirrox on -indev "$output" -extract /liteedge.apkovl.tar.gz "$work/verify/liteedge.apkovl.tar.gz" >/dev/null 2>&1
tar -tzf "$work/verify/liteedge.apkovl.tar.gz" | grep -q 'etc/liteedge-offline/liteedge-linux-musl-x86_64.tar.gz'
tar -tzf "$work/verify/liteedge.apkovl.tar.gz" | grep -q 'etc/local.d/liteedge-firstboot.start'
# Prove the complete on-media dependency closure can be resolved and fetched
# with zero network. This also verifies the locally signed repository index.
xorriso -osirrox on -indev "$output" -extract /apks "$work/verify/apks" >/dev/null 2>&1
mkdir -p "$work/verify/offline-fetch"
world="$(tar -xOzf "$work/verify/liteedge.apkovl.tar.gz" etc/apk/world)"
# shellcheck disable=SC2086
apk --no-network --repositories-file /dev/null --repository "$work/verify/apks" \
    fetch --recursive --output "$work/verify/offline-fetch" $world >/dev/null
count="$(find "$work/verify/offline-fetch" -name '*.apk' | wc -l)"
[ "$count" -ge 100 ] || { echo 'Offline APK dependency verification incomplete' >&2; exit 1; }
echo "PASS: ISO has BIOS/UEFI boot, signed offline APKs ($count resolved), and embedded LiteEdge"
