#!/bin/sh
set -eu
# shellcheck source=scripts/install-build-apks.sh
. /src/scripts/install-build-apks.sh
install_build_apks \
    git openssl ca-certificates alpine-conf abuild apk-tools \
    fakeroot syslinux xorriso squashfs-tools grub mtools \
    coreutils findutils bash tar gzip curl
export PACKAGER="LiteEdge Build <build@liteedge.invalid>"
# Generated keys sign the ISO's on-media APK index, never bundled as private.
abuild-keygen -a -n >/dev/null
cp /root/.abuild/*.rsa.pub /etc/apk/keys/
PACKAGER_PRIVKEY="$(find /root/.abuild -maxdepth 1 -name '*.rsa' | head -n1)"
export PACKAGER_PRIVKEY
[ -s "$PACKAGER_PRIVKEY" ]
variant="${LITEEDGE_ISO_VARIANT:-vm}"
case "$variant" in
  vm) profile=liteedge ;;
  baremetal) profile=liteedge_baremetal ;;
  *) echo 'Unknown ISO variant' >&2; exit 1 ;;
esac
out=/src/dist
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Use the official GitHub Alpine aports mirror to avoid GitLab HTTP 418 in CI.
git init -q "$work/aports"
git -C "$work/aports" remote add origin https://github.com/alpinelinux/aports.git
git -C "$work/aports" sparse-checkout init --cone
git -C "$work/aports" sparse-checkout set scripts
git -C "$work/aports" config remote.origin.promisor true
git -C "$work/aports" config remote.origin.partialclonefilter blob:none
for attempt in 1 2 3; do
    if timeout 120 git -C "$work/aports" fetch -q --depth 1 --filter=blob:none origin "$APORTS_COMMIT" &&
       timeout 120 git -C "$work/aports" checkout -q --detach FETCH_HEAD; then
        break
    fi
    [ "$attempt" -lt 3 ] || exit 1
    sleep "$attempt"
done
[ "$(git -C "$work/aports" rev-parse HEAD)" = "$APORTS_COMMIT" ]
printf 'ISO aports commit: %s\n' "$APORTS_COMMIT"
cp /src/scripts/mkimg.liteedge.sh "$work/aports/scripts/mkimg.liteedge.sh"
cp /src/scripts/genapkovl-liteedge.sh "$work/aports/scripts/genapkovl-liteedge.sh"
# All package transfers happen first, with per-file mirror fallback.
# mkimage then reads only the locally signed staging repository.
timeout --kill-after=30s 20m /bin/sh /src/scripts/stage-iso-apks.sh "$repo" "$profile" "$work/aports/scripts" "$work/repository"
# Record the exact selected APK bytes and upstream script revision. The
# manifest excludes ephemeral signing keys and records only public inputs.
manifest="$out/${variant}-iso-build-inputs.txt"
{
    printf 'aports_commit=%s\n' "$APORTS_COMMIT"
    printf 'alpine_version=%s\n' "$ALPINE_VERSION"
    printf 'profile=%s\n' "$profile"
    printf 'apk_tools=%s\n' "$(apk --version)"
    printf 'native_payload_sha256=%s\n' "$(sha256sum "$out/liteedge-linux-musl-x86_64.tar.gz" | cut -d' ' -f1)"
    printf 'Staged APK SHA256 hashes:\n'
    (cd "$work/repository/x86_64" && sha256sum ./*.apk | LC_ALL=C sort -k2)
} >"$manifest"
cd "$work/aports/scripts"
timeout --kill-after=30s 10m ./mkimage.sh \
    --tag "$VERSION" \
    --outdir "$out" \
    --workdir "$work/build" \
    --arch x86_64 \
    --profile "$profile" \
    --repository "$work/repository"
output="$out/liteedge-${variant}-installer-${VERSION}-x86_64.iso"
test -s "$output"
(cd "$out" && sha256sum "$(basename "$output")" > "$(basename "$output").sha256")
# Verify native hybrid El Torito boot records (both BIOS and UEFI).
xorriso -indev "$output" -report_el_torito plain 2>&1 | tee "$out/${variant}-iso-validation.log"
grep -Eq 'BIOS|BIOS_boot' "$out/${variant}-iso-validation.log"
grep -Eq 'UEFI|EFI' "$out/${variant}-iso-validation.log"
# Verify the embedded offline payload is present on the finished medium.
mkdir -p "$work/verify"
xorriso -osirrox on -indev "$output" -extract /liteedge.apkovl.tar.gz "$work/verify/liteedge.apkovl.tar.gz" >/dev/null 2>&1
tar -tzf "$work/verify/liteedge.apkovl.tar.gz" | grep -q 'etc/liteedge-offline/liteedge-linux-musl-x86_64.tar.gz'
tar -tzf "$work/verify/liteedge.apkovl.tar.gz" | grep -q 'etc/local.d/liteedge-firstboot.start'
if [ "$variant" = baremetal ]; then
  tar -tzf "$work/verify/liteedge.apkovl.tar.gz" | grep -q 'etc/liteedge-offline/baremetal-iso-install.sh'
  tar -xOzf "$work/verify/liteedge.apkovl.tar.gz" etc/apk/world | grep -qx 'linux-lts'
  if tar -xOzf "$work/verify/liteedge.apkovl.tar.gz" etc/apk/world | grep -qx 'linux-virt'; then
    echo 'Bare-metal target incorrectly selects the VM kernel.' >&2; exit 1
  fi
fi
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
echo "PASS: $variant ISO has BIOS/UEFI boot, signed offline APKs ($count resolved), and embedded LiteEdge"
