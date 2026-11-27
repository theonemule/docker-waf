#!/usr/bin/env python3
"""Private, immutable runtime snapshots; the NGINX master uses active.conf.

The mutable rendering tree remains the admin/diagnostic and transaction
workspace. Never point a running master at that tree after migration.
"""
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess

NAME = re.compile(r"gen-[0-9a-f]{32}")
FILES = ("nginx.conf", "admin.conf", "upstreams.conf", "route-limits.conf",
         "streams.conf", "extra-listener-ports.conf", "trusted-proxies.conf", "modsecurity.conf",
         "modsecurity-pre.conf", "modsecurity-main.conf",
         "modsecurity-wordpress.conf", "modsecurity-overrides.conf")
TREES = ("sites", "waf-routes")

def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)

def sync_tree(path):
    for directory, _, files in os.walk(path, topdown=False):
        for name in files:
            with open(Path(directory)/name, "rb") as f: os.fsync(f.fileno())
        sync_dir(directory)

def root_for(config):
    return Path(config).parent.parent / ".liteedge-nginx-generations"

def current(root):
    link = root/"active.conf"
    if not link.is_symlink():
        if link.exists(): raise ValueError("Active configuration pointer is not a symlink")
        return None
    target = Path(os.readlink(link))
    if target.is_absolute() or len(target.parts) != 2 or not NAME.fullmatch(target.parts[0]) or target.name != "nginx.conf":
        raise ValueError("Invalid active configuration pointer")
    generation = root/target.parts[0]
    if generation.is_symlink() or not (generation/"nginx.conf").is_file():
        raise ValueError("Active configuration generation missing")
    return generation

def activate(root, generation):
    if generation.parent != root or not NAME.fullmatch(generation.name):
        raise ValueError("Invalid generation")
    temporary = root/(".active-"+secrets.token_hex(16))
    try:
        temporary.symlink_to(generation.name+"/nginx.conf")
        os.replace(temporary, root/"active.conf")
        sync_dir(root)
    finally:
        temporary.unlink(missing_ok=True)

def copy_tree(source, dest):
    # Snapshot only regular files and directories. Do not follow arbitrary
    # symlinks out of the managed configuration or copy special files.
    if source.is_symlink() or not source.is_dir():
        raise ValueError("Invalid configuration source directory")
    dest.mkdir(mode=0o700)
    for entry in sorted(source.iterdir()):
        if entry.name == ".git": continue
        mode = entry.lstat().st_mode
        target = dest/entry.name
        if stat.S_ISDIR(mode): copy_tree(entry,target)
        elif stat.S_ISREG(mode): shutil.copyfile(entry,target);target.chmod(0o600)
        elif stat.S_ISLNK(mode):
            resolved=entry.resolve(strict=True)
            if not resolved.is_file() or not resolved.is_relative_to(source.resolve()):
                raise ValueError("Configuration symlink escapes its directory")
            shutil.copyfile(resolved,target);target.chmod(0o600)
        else: raise ValueError("Unsupported configuration file type")

def copy_file(source,dest):
    if not source.is_file() or source.is_symlink():
        raise ValueError("Missing or invalid generated file: "+source.name)
    shutil.copyfile(source,dest);dest.chmod(0o600)

def rewrite(path, mappings):
    # Only replace managed absolute path prefixes at token boundaries.
    # Preserve mutable document roots, logs, auth files and runtime sockets.
    raw=path.read_bytes()
    for old,new in sorted(mappings,key=lambda pair:-len(str(pair[0]))):
        pattern=rb'(?<![A-Za-z0-9_.:/-])'+re.escape(os.fsencode(old))+rb'(?=/|[\s;"\x27]|$)'
        raw=re.sub(pattern,lambda _:os.fsencode(new),raw)
    path.write_bytes(raw)

def stage(binary,config,runtime,marker,pass_fds=(),timeout=90):
    config=Path(config).absolute()
    source=config.parent;data=source.parent;root=root_for(config)
    root.mkdir(mode=0o700,exist_ok=True)
    if root.is_symlink() or root.stat().st_mode & 0o077:
        raise ValueError("Configuration generation directory must be private")
    # Never exhaust the local PVC with retained generations. A long-lived
    # connection may delay retirement; reject a new update rather than
    # evict any generation still potentially in use.
    prune(root)
    if sum(1 for child in root.iterdir() if NAME.fullmatch(child.name))>=32:
        raise ValueError("Too many retained runtime generations; drain old workers or restart appliance")
    candidate=root/("gen-"+secrets.token_hex(16))
    candidate.mkdir(mode=0o700)
    try:
        for name in FILES:
            src=source/name
            if name=="nginx.conf":src=config
            # Old restored backups can lack an optional empty stream include.
            if name in ("streams.conf", "trusted-proxies.conf") and not src.exists():
                (candidate/name).touch(mode=0o600)
            else:copy_file(src,candidate/name)
        for name in TREES:
            if (source/name).exists():copy_tree(source/name,candidate/name)
            else:(candidate/name).mkdir(mode=0o700)
        mappings=[(source,candidate)]
        for name in ("certs","waf","migration"):
            src=data/name
            if src.exists():
                copy_tree(src,candidate/name);mappings.append((src,candidate/name))
        for env,default,sub in (("WAF_DIR",data/"waf","waf"),("WAF_PLUGIN_DIR",data/"waf/plugins","external-plugins"),("WAF_CRS_DIR",data/"waf/crs","external-crs")):
            src=Path(os.environ.get(env,str(default)))
            if src!=default and src.exists():
                dst=candidate/sub
                if dst.exists():dst=candidate/("external-"+sub)
                copy_tree(src,dst);mappings.append((src,dst))
        mappings.append((runtime/"reload-ack.conf",candidate/"reload-ack.conf"))
        for path in candidate.rglob("*.conf"):
            rewrite(path,mappings)
        ack='server { listen unix:'+str(runtime/"reload-ack.sock")+'; server_name localhost; access_log off; location = / { return 200 "'+marker+'"; } location / { return 404; } }\n'
        (candidate/"reload-ack.conf").write_text(ack)
        (candidate/"reload-ack.conf").chmod(0o600)
        for path in candidate.rglob("*"):
            if path.is_file():path.chmod(0o400)
        sync_tree(candidate);sync_dir(root)
        # Validate using the same config-directory prefix as the actual
        # master's active.conf, including relative manual includes.
        validation=root/(".validate-"+secrets.token_hex(16)+".conf")
        try:
            validation.symlink_to(candidate.name+"/nginx.conf")
            subprocess.run([str(binary),"-t","-c",str(validation)],check=True,stdout=subprocess.DEVNULL,timeout=timeout,pass_fds=pass_fds)
        finally:validation.unlink(missing_ok=True)
        return candidate
    except BaseException:
        shutil.rmtree(candidate,ignore_errors=True)
        raise

def workers(master):
    # Start ticks avoid treating a reused PID as an old worker.
    result={}
    try: children=Path(f"/proc/{master}/task/{master}/children").read_text().split()
    except OSError:return None
    for pid in children:
        try:
            # PID 1 may also have inherited the entrypoint's long-running
            # observability/health/CGI children; they do not load NGINX
            # configuration and must not prevent generation retirement.
            if Path(f"/proc/{pid}/comm").read_text().strip()!="nginx":continue
            result[pid]=Path(f"/proc/{pid}/stat").read_text().rsplit(")",1)[1].split()[19]
        except (OSError,IndexError):pass
    return result

def retire(root,generation,old_workers):
    if generation is None or old_workers is None:return
    # No deletion until every worker that could refer to this generation
    # has exited. A crash before metadata publication leaves a safe orphan.
    metadata=root/(generation.name+".retired")
    temporary=root/(".retired-"+secrets.token_hex(16))
    try:
        with temporary.open("x") as f:
            json.dump(old_workers,f);f.flush();os.fsync(f.fileno())
        os.replace(temporary,metadata);sync_dir(root)
    finally:temporary.unlink(missing_ok=True)

def prune(root):
    active=current(root)
    for record in root.glob("gen-*.retired"):
        generation=root/record.name.removesuffix(".retired")
        if generation==active or not NAME.fullmatch(generation.name):continue
        try:
            pids=json.loads(record.read_text())
            if not isinstance(pids,dict):continue
            alive=False
            for pid,tick in pids.items():
                if not pid.isdecimal():raise ValueError("Invalid PID")
                try: actual=Path(f"/proc/{pid}/stat").read_text().rsplit(")",1)[1].split()[19]
                except FileNotFoundError:continue
                if actual==tick:alive=True;break
            if alive:continue
            shutil.rmtree(generation)
            record.unlink()
        except (OSError,ValueError,TypeError,IndexError):continue
    sync_dir(root)

def secure_startup_root(root):
    """Re-establish private mode on the owned local PVC before master start.

    Kubernetes may recursively add group permissions on volume attachment.
    Never follow a symlink, repair a foreign-owned directory, or relax the
    strict runtime stage check. Open and chmod the same directory inode.
    """
    root.mkdir(mode=0o700,exist_ok=True)
    fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        if os.fstat(fd).st_uid!=os.geteuid():
            raise ValueError("Configuration generation directory must be owned by appliance")
        os.fchmod(fd,0o700)
        os.fsync(fd)
    finally:
        os.close(fd)

def startup(binary,config,runtime,marker):
    # Called only before the appliance launches its master. Orphaned
    # snapshots from an interrupted transaction can now be removed safely.
    root=root_for(config)
    secure_startup_root(root)
    if root.is_dir() and not root.is_symlink():
        previous=current(root)
        for child in root.iterdir():
            if child!=previous and NAME.fullmatch(child.name) and child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            elif child.name.endswith(".retired") and NAME.fullmatch(child.name.removesuffix(".retired")):
                child.unlink()
    candidate=stage(binary,config,runtime,marker)
    activate(root,candidate)
    for child in root.iterdir():
        if child==candidate or child.name=="active.conf":continue
        if NAME.fullmatch(child.name) and child.is_dir() and not child.is_symlink():shutil.rmtree(child)
        elif child.name.endswith(".retired") and NAME.fullmatch(child.name.removesuffix(".retired")):child.unlink()
    sync_dir(root)
    return root/"active.conf"
