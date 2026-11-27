#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/auth"
OLD='example-initial-credential'
NEW='example-replacement-credential'
OTHER='unchanged-other-user'
old_hash="$(printf '%s\n' "$OLD" | openssl passwd -6 -stdin)"
other_hash="$(printf '%s\n' "$OTHER" | openssl passwd -6 -stdin)"
printf 'admin:%s\nother:%s\n' "$old_hash" "$other_hash" > "$TEMP/auth/.htpasswd"
chmod 600 "$TEMP/auth/.htpasswd"
helper="$ROOT/bin/adminctl.sh"
original="$(sha256sum "$TEMP/auth/.htpasswd")"

if printf '%s\n' invalid-credential "$NEW" "$NEW" | DATA_DIR="$TEMP" "$helper" change-password > "$TEMP/response" 2>&1; then
  echo 'Wrong current credential accepted' >&2; exit 1
fi
grep -Fq 'Current password is incorrect' "$TEMP/response"
[[ "$(sha256sum "$TEMP/auth/.htpasswd")" == "$original" ]]
if printf '%s\n' "$OLD" "$NEW" different-confirmation | DATA_DIR="$TEMP" "$helper" change-password > "$TEMP/response" 2>&1; then
  echo 'Mismatching new values accepted' >&2; exit 1
fi
[[ "$(sha256sum "$TEMP/auth/.htpasswd")" == "$original" ]]
if printf '%s\n' "$OLD" short short | DATA_DIR="$TEMP" "$helper" change-password > "$TEMP/response" 2>&1; then
  echo 'Weak new value accepted' >&2; exit 1
fi
[[ "$(sha256sum "$TEMP/auth/.htpasswd")" == "$original" ]]
printf '%s\n' "$OLD" "$NEW" "$NEW" | DATA_DIR="$TEMP" "$helper" change-password > "$TEMP/response"
grep -Fq 'Password updated successfully' "$TEMP/response"
[[ "$(stat -c %a "$TEMP/auth/.htpasswd")" == 600 ]]
[[ "$(awk -F: '$1=="other" {print $2}' "$TEMP/auth/.htpasswd")" == "$other_hash" ]]
[[ "$(awk -F: '$1=="admin" {print $2}' "$TEMP/auth/.htpasswd")" != "$old_hash" ]]
if printf '%s\n' "$OLD" "$NEW" "$NEW" | DATA_DIR="$TEMP" "$helper" change-password > "$TEMP/response" 2>&1; then
  echo 'Old credential was accepted after change' >&2; exit 1
fi
grep -Fq 'Current password is incorrect' "$TEMP/response"
printf '%s\n' "$NEW" "$OLD" "$OLD" | DATA_DIR="$TEMP" "$helper" change-password > "$TEMP/response"
grep -Fq 'Password updated successfully' "$TEMP/response"
echo 'PASS: password update, wrong current, mismatch, minimum length, atomic persistent file and second update'

# Exercise the actual entrypoint bootstrap block, including Kubernetes Secret
# file terminators, without starting the appliance or touching persistent data.
sed -n '/^ADMIN_USER=/,/^unset ADMIN_PASSWORD/p' "$ROOT/entrypoint.sh" > "$TEMP/bootstrap.sh"
for suffix in '' $'\n' $'\r\n'; do
  mkdir -p "$TEMP/bootstrap/auth"; rm -f "$TEMP/bootstrap/auth/.htpasswd"
  DATA_DIR="$TEMP/bootstrap" ADMIN_PASSWORD="$OLD$suffix" bash -eu "$TEMP/bootstrap.sh"
  hash="$(cut -d: -f2 "$TEMP/bootstrap/auth/.htpasswd")"
  salt="$(cut -d'$' -f3 <<< "$hash")"
  [[ "$(printf '%s\n' "$OLD" | openssl passwd -6 -stdin -salt "$salt")" == "$hash" ]]
done
for invalid in $'first\nsecond' $'first\rsecond' $'first\n\n' $'\n'; do
  rm -f "$TEMP/bootstrap/auth/.htpasswd"
  if DATA_DIR="$TEMP/bootstrap" ADMIN_PASSWORD="$invalid" bash -eu "$TEMP/bootstrap.sh" >/dev/null 2>&1; then
    echo 'Invalid bootstrap password accepted' >&2; exit 1
  fi
  test ! -e "$TEMP/bootstrap/auth/.htpasswd"
done
echo 'PASS bootstrap password Secret terminators and embedded newline rejection'
