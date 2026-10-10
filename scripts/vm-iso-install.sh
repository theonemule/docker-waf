#!/bin/sh
# Run this inside the live ISO to install Alpine and LiteEdge without internet.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Run as root' >&2; exit 1; }
[ -f /etc/liteedge-offline/liteedge-linux-musl-x86_64.tar.gz ] ||
    { echo 'This is not a LiteEdge VM installation ISO.' >&2; exit 1; }
printf '\nLiteEdge offline VM installer (x86_64)\n'
printf 'This installer installs Alpine Linux and LiteEdge on a virtual hard disk.\n'
printf 'The selected disk will be completely ERASED.\n\n'
lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true
printf '\nDisk to erase (e.g. /dev/vda, /dev/sda): '
IFS= read -r disk
case "$disk" in /dev/vd[a-z]|/dev/sd[a-z]|/dev/nvme[0-9]n[0-9]) ;; *)
    echo 'Unsupported disk path.' >&2; exit 1 ;; esac
[ -b "$disk" ] || { echo "Disk not found: $disk" >&2; exit 1; }
printf 'Type ERASE to confirm permanent erasure of %s: ' "$disk"
IFS= read -r answer
[ "$answer" = ERASE ] || { echo 'Canceled.'; exit 1; }
# The disk must not be the ISO boot medium.
if mount | grep -Eq "^$disk([0-9p]| )"; then
    echo 'The selected device has mounted partitions; refusing to erase it.' >&2
    exit 1
fi
# Find the installation CD filesystem holding the signed, full package index.
# No remote repositories are ever used during this installation.
repository=''
for path in /media/cdrom/apks /media/*/apks /media/*/*/apks; do
    if [ -f "$path/x86_64/APKINDEX.tar.gz" ]; then repository="$path"; break; fi
done
[ -n "$repository" ] || {
    echo 'Cannot find offline Alpine APK repository. Ensure the LiteEdge ISO is mounted.' >&2
    exit 1
}
echo "Using offline package repository: $repository"
# Force all setup-alpine package operations to the ISO repository. The user
# still configures root login, time zone and network interactively.
answers="$(mktemp)"
trap 'rm -f "$answers"' EXIT
printf 'APKREPOSOPTS=%s\nDISKOPTS="-m sys %s"\n' "$repository" "$disk" > "$answers"
export MIRRORS='offline-install-only'
echo 'Starting Alpine setup. Set the root password and select network options.'
echo 'No Internet connection is required. Select local installation if asked.'
setup-alpine -f "$answers"
echo
echo 'Alpine installed. The next boot will install LiteEdge automatically'
echo 'from the payload included in the disk image.'
echo 'Disconnect the installation ISO and reboot the VM.'
echo 'After first boot, read /root/liteedge-install.txt for the admin credentials.'
