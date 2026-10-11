#!/usr/bin/env python3
"""Complete LiteEdge /data backup and transactional restore, excluding logs.

Archive format is a gzipped PAX tar with manifest.json and data/ entries.
This utility requires an exclusive lock for both operations. It intentionally
never includes /data/logs, log files, or log-processing cursor state.
"""
import argparse
import datetime
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

FORMAT = 'liteedge-full-backup-v1'
MAX_COMPRESSED = 256 * 1024 * 1024
MAX_EXPANDED = 1024 * 1024 * 1024
MAX_ENTRIES = 30000
EXCLUDED_OBSERVABILITY = {'.events-chunk', '.audit-chunk', '.waf-events',
                          '.health-events', 'events.offset', 'audit.offset',
                          'logrotate.status'}

class InvalidBackup(Exception):
    pass

def excluded(parts):
    if not parts:
        return False
    return (any(p == 'logs' or p.startswith('.liteedge-') for p in parts)
            or parts[-1].endswith(('.log', '.jsonl'))
            or (parts[0] == 'observability' and parts[-1] in EXCLUDED_OBSERVABILITY))

def safe_path(value):
    if not value or '\x00' in value or '\\' in value or '\n' in value:
        raise InvalidBackup('Invalid archive path')
    p = PurePosixPath(value)
    if p.is_absolute() or any(x in ('..', '.') for x in value.split('/')):
        raise InvalidBackup('Archive contains an unsafe relative path')
    if len(value) > 1024:
        raise InvalidBackup('Archive member path is too long')
    return tuple(p.parts)

def valid_link(relative, target):
    if not target or os.path.isabs(target) or '\x00' in target or '\n' in target:
        raise InvalidBackup('An archive symlink has an unsafe target')
    resolved = list(relative[:-1])
    for part in target.split('/'):
        if part in ('', '.'):
            continue
        if part == '..':
            if not resolved:
                raise InvalidBackup('An archive symlink escapes the data directory')
            resolved.pop()
        else:
            resolved.append(part)
    if not resolved or excluded(resolved):
        raise InvalidBackup('An archive symlink points at an excluded location')

def collect(data):
    items = []
    def walk(directory, rel=()):
        for entry in sorted(os.scandir(directory), key=lambda e: e.name):
            parts = rel + (entry.name,)
            if excluded(parts):
                continue
            metadata = entry.stat(follow_symlinks=False)
            if stat.S_ISDIR(metadata.st_mode):
                items.append((parts, entry.path, metadata, 'dir'))
                walk(entry.path, parts)
            elif stat.S_ISREG(metadata.st_mode):
                items.append((parts, entry.path, metadata, 'file'))
            elif stat.S_ISLNK(metadata.st_mode):
                valid_link(parts, os.readlink(entry.path))
                items.append((parts, entry.path, metadata, 'link'))
            else:
                raise InvalidBackup('Unsupported special file in data: ' + '/'.join(parts))
            if len(items) > MAX_ENTRIES:
                raise InvalidBackup('Too many backup entries')
    walk(data)
    return items

def add_bytes(tar, filename, content):
    info = tarfile.TarInfo(filename)
    info.mode = 0o600
    info.size = len(content)
    info.mtime = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    tar.addfile(info, io.BytesIO(content))

def create(data, output):
    items = collect(data)
    payload = []
    for parts, path, meta, kind in items:
        entry = {'path': '/'.join(parts), 'type': kind,
                 'mode': stat.S_IMODE(meta.st_mode)}
        if kind == 'file':
            with open(path, 'rb') as source:
                digest = hashlib.file_digest(source, 'sha256').hexdigest()
            entry['sha256'] = digest
            entry['size'] = meta.st_size
        elif kind == 'link':
            entry['target'] = os.readlink(path)
        payload.append(entry)
    manifest = {'format': FORMAT, 'created_utc': datetime.datetime.now(
        datetime.timezone.utc).isoformat(), 'excludes_logs': True, 'entries': payload}
    manifest_bytes = (json.dumps(manifest, sort_keys=True, separators=(',', ':'))+'\n').encode()
    with tarfile.open(output, 'w:gz', format=tarfile.PAX_FORMAT) as tar:
        add_bytes(tar, 'manifest.json', manifest_bytes)
        for parts, path, meta, kind in items:
            name = 'data/' + '/'.join(parts)
            entry = tarfile.TarInfo(name)
            entry.mode = stat.S_IMODE(meta.st_mode)
            entry.mtime = int(meta.st_mtime)
            if kind == 'dir':
                entry.type = tarfile.DIRTYPE
                tar.addfile(entry)
            elif kind == 'link':
                entry.type = tarfile.SYMTYPE
                entry.linkname = os.readlink(path)
                tar.addfile(entry)
            else:
                entry.size = meta.st_size
                with open(path, 'rb') as source:
                    tar.addfile(entry, source)
    os.chmod(output, 0o600)
    return {'ok': True, 'entries': len(payload), 'bytes': os.stat(output).st_size}

def stage_archive(source, stage):
    if os.stat(source).st_size > MAX_COMPRESSED:
        raise InvalidBackup('Backup exceeds the 256 MiB upload limit')
    root = stage / 'data'
    root.mkdir(parents=True, mode=0o700)
    with tarfile.open(source, 'r:gz') as tar:
        members = tar.getmembers()
        if len(members) > MAX_ENTRIES + 1 or not members or members[0].name != 'manifest.json':
            raise InvalidBackup('Not a LiteEdge full backup archive')
        meta = tar.extractfile(members[0])
        if meta is None or members[0].size > 8 * 1024 * 1024:
            raise InvalidBackup('Invalid or oversized backup manifest')
        manifest = json.loads(meta.read())
        if manifest.get('format') != FORMAT or manifest.get('excludes_logs') is not True:
            raise InvalidBackup('Unsupported backup format')
        expected = manifest.get('entries')
        if not isinstance(expected, list) or len(expected) != len(members) - 1:
            raise InvalidBackup('Backup manifest does not match archive')
        seen = set()
        total = 0
        links = []
        directories = []
        for member, record in zip(members[1:], expected):
            parts = safe_path(member.name)
            if len(parts) < 2 or parts[0] != 'data' or excluded(parts[1:]):
                raise InvalidBackup('Archive contains excluded or unexpected paths')
            rel = parts[1:]
            if '/'.join(rel) != record.get('path') or rel in seen:
                raise InvalidBackup('Archive and manifest paths do not match')
            seen.add(rel)
            if len(seen) > MAX_ENTRIES:
                raise InvalidBackup('Too many archive entries')
            dest = root.joinpath(*rel)
            if any(rel[:n] in links for n in range(1, len(rel))):
                raise InvalidBackup('Archive contains files under symlink paths')
            if member.isdir():
                if record.get('type') != 'dir':
                    raise InvalidBackup('Directory metadata mismatch')
                dest.mkdir(parents=True, exist_ok=True)
                directories.append((dest, record.get('mode', 0o700)))
            elif member.issym():
                if record.get('type') != 'link' or member.linkname != record.get('target'):
                    raise InvalidBackup('Symlink metadata mismatch')
                valid_link(rel, member.linkname)
                links.append(rel)
            elif member.isfile():
                if record.get('type') != 'file' or member.size != record.get('size'):
                    raise InvalidBackup('File metadata mismatch')
                total += member.size
                if total > MAX_EXPANDED:
                    raise InvalidBackup('Expanded backup exceeds 1 GiB safety limit')
                dest.parent.mkdir(parents=True, exist_ok=True)
                digest = hashlib.sha256()
                with tar.extractfile(member) as infile, open(dest, 'xb') as outfile:
                    while True:
                        part = infile.read(1024 * 1024)
                        if not part:
                            break
                        digest.update(part)
                        outfile.write(part)
                if digest.hexdigest() != record.get('sha256'):
                    raise InvalidBackup('Backup file checksum mismatch')
                os.chmod(dest, int(record.get('mode', 0o600)) & 0o777)
            else:
                raise InvalidBackup('Archive contains unsupported device or link type')
        for rel in links:
            record = next(item for item in expected if item['path'] == '/'.join(rel))
            dest = root.joinpath(*rel)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.symlink_to(record['target'])
        # Check fully resolved symlink chains after all members are staged.
        for rel in links:
            dest = root.joinpath(*rel)
            resolved = Path(os.path.realpath(dest))
            if not resolved.is_relative_to(root.resolve()):
                raise InvalidBackup('Archive contains an escaping symlink chain')
        for path, mode in reversed(directories):
            path.chmod(int(mode) & 0o777)
    for required in ('sites', 'certs', 'nginx', 'auth'):
        if not (root / required).is_dir():
            raise InvalidBackup('Backup missing required directory: ' + required)
    if not (root / 'auth/.htpasswd').is_file():
        raise InvalidBackup('Backup missing administrator credentials')
    (root / 'auth/.htpasswd').chmod(0o600)
    for key in (root / 'certs').rglob('privkey.pem'):
        if key.is_file() and not key.is_symlink():
            key.chmod(0o600)
    return {'ok': True, 'entries': len(seen), 'expanded_bytes': total}

def reload_config():
    subprocess.run(['/opt/liteedge/bin/render-runtime.sh'], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    subprocess.run(['/opt/liteedge/bin/render-nginx.sh'], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    subprocess.run(['/opt/liteedge/sbin/nginx', '-t', '-c',
                    str(Path(os.environ.get('DATA_DIR', '/data'))/'nginx/nginx.conf')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    subprocess.run(['/opt/liteedge/sbin/nginx', '-s', 'reload', '-c',
                    str(Path(os.environ.get('DATA_DIR', '/data'))/'nginx/nginx.conf')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

def restore(data, source, work):
    result = stage_archive(source, work / 'stage')
    stage = work / 'stage' / 'data'
    previous = work / 'previous'
    previous.mkdir()
    replaced = []
    installed = []
    try:
        # Keep logs and the runtime lock in place; replace all other state.
        for entry in list(data.iterdir()):
            if excluded((entry.name,)):
                continue
            entry.rename(previous / entry.name)
            replaced.append(entry.name)
        for entry in list(stage.iterdir()):
            entry.rename(data / entry.name)
            installed.append(entry.name)
        reload_config()
    except Exception as error:
        for name in reversed(installed):
            current = data / name
            if current.is_dir() and not current.is_symlink():
                shutil.rmtree(current)
            elif current.exists() or current.is_symlink():
                current.unlink()
        for name in reversed(replaced):
            (previous / name).rename(data / name)
        try:
            reload_config()
        except Exception:
            pass
        raise InvalidBackup('Restore rolled back after configuration validation failed: '+str(error)) from error
    return dict(result, restored=True, logs_preserved=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('backup', 'restore', 'verify'))
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    data = Path(os.environ.get('DATA_DIR', '/data')).resolve()
    if not data.is_dir():
        raise InvalidBackup('Data directory is missing')
    lock_path = data / '.liteedge-backup.lock'
    with open(lock_path, 'a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(prefix='.liteedge-backup-work.', dir=data) as temp:
            work = Path(temp)
            if args.action == 'backup':
                result = create(data, args.archive)
            elif args.action == 'verify':
                result = stage_archive(args.archive, work / 'stage')
            else:
                result = restore(data, args.archive, work)
    print(json.dumps(result, separators=(',', ':')))

if __name__ == '__main__':
    try:
        main()
    except (InvalidBackup, OSError, tarfile.TarError, subprocess.CalledProcessError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
