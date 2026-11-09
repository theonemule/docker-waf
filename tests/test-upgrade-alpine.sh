#!/usr/bin/env bash
# Native upgrade lifecycle is tested inside a disposable container only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v docker >/dev/null || { echo 'Docker required for isolated native test' >&2; exit 1; }
NAME="liteedge-native-upgrade-test-$(date +%s)-$RANDOM"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
docker create --name "$NAME" --network none debian:bookworm-slim sleep 300 >/dev/null
docker cp "$ROOT/scripts/upgrade-liteedge.sh" "$NAME:/tmp/upgrade-liteedge.sh"
docker start "$NAME" >/dev/null
docker exec -i "$NAME" bash -s <<'CONTAINER'
set -euo pipefail
mkdir -p /opt/liteedge /etc/init.d /etc/conf.d /var/lib/liteedge /usr/local/lib /tmp/mocks /tmp/assets /tmp/release/opt/liteedge/sbin /tmp/release/opt/liteedge/share/openrc /tmp/release/opt/liteedge/lib
printf 'LiteEdge=3.1.4\n' >/opt/liteedge/VERSION
echo '# prior init' >/etc/init.d/liteedge
echo 'KEEP-THE-USER-CONFIG' >/etc/conf.d/liteedge
echo 'KEEP-THE-PERSISTENT-DATA' >/var/lib/liteedge/sentinel
cat > /tmp/release/opt/liteedge/sbin/nginx <<'NGINX'
#!/usr/bin/env bash
echo 'nginx with ModSecurity-nginx' >&2
NGINX
cat > /tmp/release/opt/liteedge/entrypoint.sh <<'ENTRY'
#!/usr/bin/env bash
exit 0
ENTRY
echo '# new init' >/tmp/release/opt/liteedge/share/openrc/liteedge
echo 'LiteEdge=3.1.5' >/tmp/release/opt/liteedge/VERSION
chmod +x /tmp/release/opt/liteedge/{sbin/nginx,entrypoint.sh}
tar -czf /tmp/assets/liteedge-linux-musl-x86_64.tar.gz -C /tmp/release opt/liteedge
(cd /tmp/assets && sha256sum liteedge-linux-musl-x86_64.tar.gz > liteedge-linux-musl-x86_64.tar.gz.sha256)
cat > /tmp/mocks/apk <<'APK'
#!/usr/bin/env bash
exit 0
APK
cat > /tmp/mocks/setcap <<'SETCAP'
#!/usr/bin/env bash
exit 0
SETCAP
cat > /tmp/mocks/rc-service <<'RC'
#!/usr/bin/env bash
set -euo pipefail
case "$2" in
  status) test -e /tmp/service-running ;;
  stop) rm -f /tmp/service-running ;;
  start)
    if [[ "${FAIL_NEW:-0}" == 1 ]] && grep -qx 'LiteEdge=3.1.5' /opt/liteedge/VERSION; then exit 2; fi
    touch /tmp/service-running ;;
  *) exit 90 ;;
esac
RC
cat > /tmp/mocks/curl <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out='' url=''
while (($#)); do
  if [[ "$1" == '-o' ]]; then out="$2"; shift 2
  else url="$1"; shift; fi
done
[[ -n "$out" ]] || exit 40
case "$url" in
  */liteedge-linux-musl-x86_64.tar.gz) cp /tmp/assets/liteedge-linux-musl-x86_64.tar.gz "$out" ;;
  */liteedge-linux-musl-x86_64.tar.gz.sha256) cp /tmp/assets/liteedge-linux-musl-x86_64.tar.gz.sha256 "$out" ;;
  *) exit 41 ;;
esac
CURL
chmod +x /tmp/mocks/*
export PATH="/tmp/mocks:$PATH"
touch /tmp/service-running
bash /tmp/upgrade-liteedge.sh --mode alpine
grep -qx 'LiteEdge=3.1.5' /opt/liteedge/VERSION
grep -qx 'KEEP-THE-PERSISTENT-DATA' /var/lib/liteedge/sentinel
grep -qx 'KEEP-THE-USER-CONFIG' /etc/conf.d/liteedge
grep -qx '# new init' /etc/init.d/liteedge
test -f /tmp/service-running
rm -rf /opt/liteedge
mkdir -p /opt/liteedge
echo 'LiteEdge=3.1.4' >/opt/liteedge/VERSION
echo '# prior init' >/etc/init.d/liteedge
touch /tmp/service-running
if FAIL_NEW=1 bash /tmp/upgrade-liteedge.sh --mode alpine >/tmp/upgrade-error.log 2>&1; then
  cat /tmp/upgrade-error.log >&2
  echo 'Failed native activation was accepted' >&2
  exit 1
fi
grep -qx 'LiteEdge=3.1.4' /opt/liteedge/VERSION
grep -qx '# prior init' /etc/init.d/liteedge
test -f /tmp/service-running
grep -qx 'KEEP-THE-PERSISTENT-DATA' /var/lib/liteedge/sentinel
grep -qx 'KEEP-THE-USER-CONFIG' /etc/conf.d/liteedge
printf '%s\n' 'deadbeef  liteedge-linux-musl-x86_64.tar.gz' >/tmp/assets/liteedge-linux-musl-x86_64.tar.gz.sha256
if bash /tmp/upgrade-liteedge.sh --mode alpine >/dev/null 2>&1; then
  echo 'Bad checksum was accepted' >&2; exit 1
fi
grep -qx 'LiteEdge=3.1.4' /opt/liteedge/VERSION
test -f /tmp/service-running
echo 'PASS isolated native upgrade: staging/checksum, config preservation, activation rollback and service recovery'
CONTAINER