#!/bin/sh
set -eu
# Called by Alpine mkimage under fakeroot, from within the ISO staging dir.
HOSTNAME="${1:?hostname is required}"
: "${LITEEDGE_ISO_SOURCE:?Set LITEEDGE_ISO_SOURCE to the LiteEdge source checkout}"
root="$LITEEDGE_ISO_SOURCE"
tarball="$root/dist/liteedge-linux-musl-x86_64.tar.gz"
checksum="$tarball.sha256"
test -s "$tarball" && test -s "$checksum" || {
    echo 'Build the native LiteEdge payload before building the ISO.' >&2
    exit 1
}
(cd "$root/dist" && sha256sum -c "$(basename "$checksum")") >/dev/null
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/etc/liteedge-offline" "$tmp/etc/local.d" "$tmp/etc/runlevels/default" "$tmp/etc/profile.d" "$tmp/etc/apk"
printf '%s\n' "$HOSTNAME" > "$tmp/etc/hostname"
# Alpine setup-disk uses /etc/apk/world from this overlay to install all the
# LiteEdge runtime dependencies from the ISO's signed /apks/x86_64 repository.
cat > "$tmp/etc/apk/world" <<'PACKAGES'
alpine-base
alpine-conf
alpine-keys
openrc
linux-lts
grub-bios
grub-efi
efibootmgr
syslinux
e2fsprogs
dosfstools
parted
sfdisk
util-linux
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
libmaxminddb
coreutils
diffutils
patch
lua5.3-libs
jq
socat
logrotate
libcap
tar
gzip
findutils
openssh
PACKAGES
cp "$tarball" "$checksum" "$tmp/etc/liteedge-offline/"
cp "$root/scripts/install-alpine.sh" "$tmp/etc/liteedge-offline/install-alpine.sh"
cp "$root/scripts/vm-iso-install.sh" "$tmp/etc/liteedge-offline/vm-iso-install.sh"
cp "$root/scripts/vm-firstboot.sh" "$tmp/etc/local.d/liteedge-firstboot.start"
chmod 755 "$tmp/etc/local.d/liteedge-firstboot.start" "$tmp/etc/liteedge-offline/vm-iso-install.sh"
# Enables a one-shot first boot installer on the new disk.
ln -s /etc/init.d/local "$tmp/etc/runlevels/default/local"
cat > "$tmp/etc/profile.d/liteedge-iso.sh" <<'PROFILE'
# Present install guidance only on the live installer, not the installed system.
if [ -r /etc/liteedge-offline/vm-iso-install.sh ] && [ ! -e /var/lib/liteedge/.vm-iso-installed ]; then
    echo 'LiteEdge VM: run  sh /etc/liteedge-offline/vm-iso-install.sh'
    echo 'No internet connection is required to install.'
fi
PROFILE
chmod 644 "$tmp/etc/profile.d/liteedge-iso.sh"
# The private archive only contains public binaries, no build signing key and
# no pre-generated credentials.
chmod 644 "$tmp/etc/liteedge-offline/"*
tar -C "$tmp" --owner=0 --group=0 --numeric-owner -czf "$HOSTNAME.apkovl.tar.gz" etc
