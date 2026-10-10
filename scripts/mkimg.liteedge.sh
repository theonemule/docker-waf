#!/bin/sh
# shellcheck disable=SC2034
# A custom Alpine 3.22 ISO containing the complete offline package dependency
# closure plus the standalone LiteEdge payload inside its live overlay.
profile_liteedge() {
    profile_standard
    image_name="liteedge-vm-installer"
    profile_abbrev="ledg"
    title="LiteEdge virtual appliance installer"
    desc="Offline Alpine Linux installation including LiteEdge"
    arch="x86_64"
    hostname="liteedge"
    syslinux_serial="0 115200"
    kernel_cmdline="console=tty0 console=ttyS0,115200"
    # Packages in world will be installed into the target by setup-disk.
    # Packages in apks are vendored into the ISO with their dependency closure.
    apks="$apks
        alpine-conf alpine-keys openrc linux-lts
        grub-bios grub-efi efibootmgr syslinux
        e2fsprogs dosfstools parted sfdisk util-linux
        bash ca-certificates curl openssl tzdata
        fcgiwrap spawn-fcgi
        pcre2 libxml2 yajl lmdb libcurl libstdc++ libgcc zlib libmaxminddb
        coreutils diffutils patch lua5.3-libs jq socat logrotate libcap
        tar gzip findutils"
    apkovl="genapkovl-liteedge.sh"
}
