#!/bin/sh
# Prompt for the web administrator account during the offline ISO install.
# Only a SHA-512-crypt hash is written to disk; plaintext is never logged.
set -eu

[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }
[ "$#" -eq 1 ] || { echo 'Usage: iso-admin-setup.sh AUTH_FILE' >&2; exit 2; }
auth_file="$1"
[ ! -e "$auth_file" ] || {
    echo 'Administrator credentials have already been configured.' >&2
    exit 1
}

# Read directly from the console, never from an installer answer file or argv.
exec 3<>/dev/tty || { echo 'An interactive console is required.' >&2; exit 1; }
printf '\nLiteEdge web administration account\n' >&3
printf 'Admin username [admin]: ' >&3
IFS= read -r admin_user <&3 || exit 1
[ -n "$admin_user" ] || admin_user='admin'
case "$admin_user" in
    [!a-zA-Z]*|*[!a-zA-Z0-9_.-]*)
        echo 'Username must start with a letter and contain only letters, digits, _, . or -.' >&2
        exit 1 ;;
esac
[ "${#admin_user}" -le 32 ] || { echo 'Username must be at most 32 characters.' >&2; exit 1; }

tty_mode="$(stty -g <&3)" || exit 1
trap 'stty "$tty_mode" <&3' EXIT
trap 'exit 1' HUP INT TERM
stty -echo <&3
printf 'Admin password (10-128 characters): ' >&3
IFS= read -r password <&3 || exit 1
printf '\nConfirm admin password: ' >&3
IFS= read -r confirmation <&3 || exit 1
printf '\n' >&3
stty "$tty_mode" <&3
trap - EXIT HUP INT TERM

[ "$password" = "$confirmation" ] || { echo 'Passwords do not match.' >&2; exit 1; }
if [ "${#password}" -lt 10 ] || [ "${#password}" -gt 128 ]; then
    echo 'Password must contain 10-128 characters.' >&2
    exit 1
fi
umask 077
password_hash="$(printf '%s\n' "$password" | openssl passwd -6 -stdin)" || exit 1
unset password confirmation
case "$password_hash" in
    '$6$'*) ;;
    *) echo 'Unable to generate a SHA-512-crypt password hash.' >&2; exit 1 ;;
esac
printf '%s:%s\n' "$admin_user" "$password_hash" > "$auth_file"
chmod 600 "$auth_file"
unset password_hash
echo 'LiteEdge web administrator credentials configured.'
