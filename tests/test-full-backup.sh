#!/usr/bin/env bash
set -Eeuo pipefail
IMAGE="$1"
TEMP="$(mktemp -d)"
NAME="liteedge-backup-regression-$$"
PASS=backup-regression-password
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$TEMP"' EXIT
docker run -d --name "$NAME" -e ADMIN_USER=admin -e "ADMIN_PASSWORD=$PASS" -p 127.0.0.1::9443 "$IMAGE" >/dev/null
PORT="$(docker port "$NAME" 9443/tcp | awk -F: 'END{print $NF}')"
BASE="https://127.0.0.1:$PORT"
for i in $(seq 1 30); do
  code="$(curl --noproxy '*' -ks -o /dev/null -w '%{http_code}' "$BASE/" || true)"
  [[ "$code" == 401 ]] && break
  sleep 1
done
[[ "$code" == 401 ]] || { echo "NGINX not ready" >&2; exit 1; }
request() { curl --noproxy '*' -ks -u "admin:$PASS" -o "$TEMP/response" -w '%{http_code}' "$@"; }
expect() { [[ "$1" == "$2" ]] || { echo "FAIL $3 expected $1 got $2" >&2; cat "$TEMP/response" | head -c 500; exit 1; }; }
expect 401 "$(curl --noproxy '*' -ks -o /dev/null -w '%{http_code}' "$BASE/api/v1/backup/export")" "Export authenticated"
expect 401 "$(curl --noproxy '*' -ks -X POST -o /dev/null -w '%{http_code}' "$BASE/api/v1/backup/restore")" "Restore authenticated"
expect 403 "$(request -X POST -d anything=x "$BASE/api/v1/backup/restore")" "Restore CSRF protected"
expect 200 "$(request -X POST -H 'X-LiteEdge-API: 1' -d host=keep.example "$BASE/api/v1/actions/site/save")" "Create kept site"
docker exec "$NAME" sh -c 'mkdir -p /data/www; echo keep-config > /data/www/test.txt; echo test-acme > /data/acme/test-state; echo keep-log > /data/logs/keep.log; echo old-cursor > /data/observability/events.offset'
expect 200 "$(request "$BASE/api/v1/backup/export")" "Download full backup"
cp "$TEMP/response" "$TEMP/good.tar.gz"
python3 - "$TEMP/good.tar.gz" <<'PY'
import tarfile,sys,json
with tarfile.open(sys.argv[1],"r:gz") as t:
  n=t.getnames()
  for required in ('manifest.json','data/auth/.htpasswd','data/certs/_admin/privkey.pem','data/www/test.txt','data/acme/test-state'):
    assert required in n,required
  assert not any('/logs' in x or x.endswith(('.log','.jsonl')) for x in n)
  assert 'data/observability/events.offset' not in n
  assert json.load(t.extractfile('manifest.json'))['excludes_logs']
print('PASS archive includes authentication/certificates/config and excludes logs')
PY
expect 200 "$(request -X POST -H 'X-LiteEdge-API: 1' -d host=temporary.example "$BASE/api/v1/actions/site/save")" "Create transient site"
docker exec "$NAME" sh -c 'echo changed > /data/www/test.txt; echo log-after-export >> /data/logs/keep.log'
expect 200 "$(request -X POST -H 'X-LiteEdge-API: 1' -H 'Content-Type: application/octet-stream' --data-binary "@$TEMP/good.tar.gz" "$BASE/api/v1/backup/restore")" "Restore succeeds"
jq -e '.ok==true and .logs_preserved==true' "$TEMP/response" >/dev/null
expect 200 "$(request "$BASE/api/v1/sites")" "Restored API"
jq -e '([.sites[].host]|index("keep.example"))!=null and ([.sites[].host]|index("temporary.example"))==null' "$TEMP/response" >/dev/null
docker exec "$NAME" sh -c 'test "$(cat /data/www/test.txt)" = keep-config; grep -q log-after-export /data/logs/keep.log; test ! -e /data/observability/events.offset'
expect 400 "$(request -X POST -H 'X-LiteEdge-API: 1' -H 'Content-Type: application/octet-stream' --data-binary 'not-a-gzip' "$BASE/api/v1/backup/restore")" "Invalid archive rejected"
python3 - "$TEMP/good.tar.gz" "$TEMP/invalid.tar.gz" <<'PY'
import hashlib,io,json,sys,tarfile
with tarfile.open(sys.argv[1],"r:gz") as source:
  members=source.getmembers()
  manifest=json.loads(source.extractfile('manifest.json').read())
  bad=b'not-a-certificate\n'
  target='data/certs/_admin/fullchain.pem'
  for item in manifest['entries']:
    if item['path']==target.removeprefix('data/'):
      item['size']=len(bad);item['sha256']=hashlib.sha256(bad).hexdigest()
      break
  else: raise AssertionError('Certificate absent')
  with tarfile.open(sys.argv[2],"w:gz") as output:
    for m in members:
      if m.name=='manifest.json': content=json.dumps(manifest).encode()
      elif m.name==target: content=bad
      elif m.isfile(): content=source.extractfile(m).read()
      else: output.addfile(m);continue
      m.size=len(content);output.addfile(m,io.BytesIO(content))
PY
expect 400 "$(request -X POST -H 'X-LiteEdge-API: 1' -H 'Content-Type: application/octet-stream' --data-binary "@$TEMP/invalid.tar.gz" "$BASE/api/v1/backup/restore")" "Invalid TLS configuration rolled back"
jq -e '.ok==false and (.error|contains("rolled back"))' "$TEMP/response" >/dev/null
expect 200 "$(request "$BASE/api/v1/sites")" "API survives rollback"
jq -e '([.sites[].host]|index("keep.example"))!=null' "$TEMP/response" >/dev/null
docker exec "$NAME" sh -c 'grep -q log-after-export /data/logs/keep.log; test "$(cat /data/www/test.txt)" = keep-config; /opt/liteedge/sbin/nginx -t -c /data/nginx/nginx.conf >/dev/null 2>&1'
python3 - "$TEMP/evil.tar.gz" <<'PY'
import io,json,sys,tarfile
with tarfile.open(sys.argv[1],"w:gz") as archive:
  obj={'format':'liteedge-full-backup-v1','excludes_logs':True,'entries':[{'path':'../escape','type':'file','size':1,'sha256':'0'*64}]}
  buf=json.dumps(obj).encode();m=tarfile.TarInfo('manifest.json');m.size=len(buf);archive.addfile(m,io.BytesIO(buf))
  m=tarfile.TarInfo('data/../../escape');m.size=1;archive.addfile(m,io.BytesIO(b'x'))
PY
expect 400 "$(request -X POST -H 'X-LiteEdge-API: 1' -H 'Content-Type: application/octet-stream' --data-binary "@$TEMP/evil.tar.gz" "$BASE/api/v1/backup/restore")" "Unsafe archive traversal rejected"
echo "PASS full backup and restore, log exclusion, auth, CSRF, integrity, validation, rollback, traversal rejection"
