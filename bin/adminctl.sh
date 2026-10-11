#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
AUTH_FILE="$DATA_DIR/auth/.htpasswd"
USERNAME="${ADMIN_USER:-admin}"

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ "${1:-}" == change-password ]] || die 'Usage: adminctl.sh change-password (passwords from stdin)'
IFS= read -r current || die 'Current password is required.'
IFS= read -r replacement || die 'New password is required.'
IFS= read -r confirmation || die 'Password confirmation is required.'

[[ -n "$current" ]] || die 'Current password is required.'
[[ "$replacement" == "$confirmation" ]] || die 'New passwords do not match.'
[[ ${#replacement} -ge 10 && ${#replacement} -le 128 ]] || die 'New password must contain 10 to 128 characters.'
[[ "$replacement" != *$'\r'* && "$replacement" != *$'\n'* ]] || die 'New password cannot include line breaks.'
[[ -s "$AUTH_FILE" ]] || die 'Admin authentication file is missing.'

umask 077
exec 9>"$DATA_DIR/auth/.htpasswd.lock"
flock -x 9
stored="$(awk -F: -v name="$USERNAME" '$1==name {print $2; exit}' "$AUTH_FILE")"
[[ -n "$stored" ]] || die 'Configured admin account does not exist.'
if [[ ! "$stored" =~ ^\$6\$([a-zA-Z0-9./]{1,16})\$[a-zA-Z0-9./]+$ ]]; then
  die 'Unsupported existing password hash.'
fi
salt="${BASH_REMATCH[1]}"
verified="$(printf '%s\n' "$current" | openssl passwd -6 -salt "$salt" -stdin)"
[[ "$verified" == "$stored" ]] || die 'Current password is incorrect.'
new_hash="$(printf '%s\n' "$replacement" | openssl passwd -6 -stdin)"
[[ "$new_hash" =~ ^\$6\$ ]] || die 'Unable to hash new password.'

tmp="$(mktemp "$DATA_DIR/auth/.htpasswd.new.XXXXXXXX")"
trap 'rm -f "$tmp"' EXIT
awk -F: -v name="$USERNAME" -v hashed="$new_hash" 'BEGIN{OFS=":"} $1==name {$2=hashed} {print $0}' "$AUTH_FILE" > "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$AUTH_FILE"
trap - EXIT
printf 'Password updated successfully.\n'
