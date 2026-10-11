#!/bin/sh
# Minimal Alpine x86-64 bare-metal installer with all LiteEdge components
# included on the ISO. No internet is needed at install or first boot.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Run as root.' >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo 'x86_64 hardware is required.' >&2; exit 1; }
[ -s /etc/liteedge-offline/liteedge-linux-musl-x86_64.tar.gz ] || {
    echo 'Missing bundled LiteEdge runtime. Boot from the bare-metal ISO.' >&2; exit 1;
}
[ -x /sbin/setup-alpine ] || { echo 'Alpine disk installer unavailable.' >&2; exit 1; }
printf '\nLiteEdge minimal bare-metal offline installer (x86_64)\n'
printf 'Installs Alpine Linux, the LTS hardware kernel, and LiteEdge.\n'
printf 'Target must have 2 GiB RAM and a bootable hard disk.\n'
printf 'All contents of the chosen disk will be PERMANENTLY ERASED.\n\n'
lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true
printf '\nTarget disk (e.g. /dev/sda, /dev/nvme0n1, /dev/vda): '
IFS= read -r disk
case "$disk" in
    /dev/sd[a-z]|/dev/vd[a-z]|/dev/nvme[0-9]n[0-9]|/dev/mmcblk[0-9]) ;;
    *) echo 'Unsupported disk path.' >&2; exit 1 ;;
esac
[ -b "$disk" ] || { echo "Not a block disk: $disk" >&2; exit 1; }
[ "$(lsblk -dn -o TYPE "$disk" | head -n1)" = disk ] || {
    echo 'Target must be a whole disk, not a partition or optical drive.' >&2; exit 1;
}
# Never overwrite any disk backing a mounted device, including the boot USB.
if lsblk -nr -o MOUNTPOINTS "$disk" | grep -q '[^[:space:]]'; then
    echo 'Target has mounted partitions (possibly the installer USB). Refusing.' >&2
    exit 1
fi
# shellcheck disable=SC2013
for mount_source in $(awk '$2 ~ /^\/media\// || $2 == "/" {print $1}' /proc/mounts); do
    case "$mount_source" in
        /dev/*)
            parent="$(lsblk -nr -o PKNAME "$mount_source" | head -n1)"
            [ -n "$parent" ] || parent="$(basename "$mount_source")"
            if [ "/dev/$parent" = "$disk" ]; then
                echo 'Refusing to erase the disk containing the boot medium.' >&2
                exit 1
            fi
            ;;
    esac
done
repository=''
for path in /media/cdrom/apks /media/*/apks /media/*/*/apks; do
    if [ -s "$path/x86_64/APKINDEX.tar.gz" ]; then repository="$path"; break; fi
done
[ -n "$repository" ] || {
    echo 'Offline signed APK repository not mounted. Boot from the LiteEdge ISO.' >&2; exit 1;
}
# Confirm critical runtime and physical hardware packages are on the media.
for package in linux-lts linux-firmware-realtek linux-firmware-intel grub-efi grub-bios fcgiwrap spawn-fcgi; do
    [ -n "$(find "$repository/x86_64" -maxdepth 1 -name "$package-[0-9]*.apk" -print -quit)" ] || {
        echo "Offline media missing package: $package" >&2; exit 1;
    }
done
printf '\nSelected disk: %s\nOffline repository: %s\n' "$disk" "$repository"
printf 'Type ERASE to permanently erase this disk: '
IFS= read -r confirmation
[ "$confirmation" = ERASE ] || { echo 'Installation canceled.'; exit 1; }
answer_file="$(mktemp)"
trap 'rm -f "$answer_file"' EXIT HUP INT TERM
# Alpine's setup-alpine will prompt for root password/network configuration,
# but all package downloads resolve only to the on-ISO signed APK index.
printf 'APKREPOSOPTS=%s\nDISKOPTS="-m sys %s"\n' "$repository" "$disk" > "$answer_file"
export MIRRORS=offline-install-only
echo 'Installing offline Alpine Linux. Do not remove the installation media.'
setup-alpine -f "$answer_file"
echo 'Disk setup finished. Remove the USB/DVD and reboot.'
echo 'On first boot LiteEdge installs itself from the bundled offline payload.'
echo 'Its new administrator credentials will be saved in /root/liteedge-install.txt.'
