#!/bin/sh
# Alpine OpenRC local.d one-shot, copied to the installed disk via the apkovl.
set -eu
# The live ISO restores this hook too. Run ONLY once the VM has booted from
# an installed filesystem; never run it from Alpine's RAM-backed live root.
if grep -Eq '^[^ ]+ / (tmpfs|rootfs|overlay) ' /proc/mounts; then
    exit 0
fi
marker=/var/lib/liteedge/.vm-iso-installed
[ ! -f "$marker" ] || exit 0
source_dir=/etc/liteedge-offline
[ -r "$source_dir/liteedge-linux-musl-x86_64.tar.gz" ] || {
    echo 'LiteEdge first-boot archive missing.' >&2; exit 1; }
# Passwords are created on the VM, never on the ISO or CI.
umask 077
log=/root/liteedge-install.txt
if sh "$source_dir/install-alpine.sh" --offline-dir "$source_dir" > "$log" 2>&1; then
    mkdir -p /var/lib/liteedge
    touch "$marker"
    chmod 600 "$marker" "$log"
    echo 'LiteEdge installed. Admin credentials: /root/liteedge-install.txt'
else
    echo 'LiteEdge first-boot installation failed. Review /root/liteedge-install.txt' >&2
    exit 1
fi
