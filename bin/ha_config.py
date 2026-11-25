#!/usr/bin/env python3
"""Shared, signed native configuration revisions. Runtime state stays node-local.

All participants use a shared filesystem with coherent flock and atomic rename.
A shared manifest is the notification; no database or peer network RPC is needed.
"""
import argparse
import contextlib
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

PARTS = ("sites", "certs", "waf", "providers", "server-settings.conf")
RUNTIME = Path("/opt/liteedge")
ID = re.compile(r"[a-z0-9][a-z0-9-]{0,62}\Z")
HEX = re.compile(r"[0-9a-f]{64}\Z")
MAX_BYTES = 256 * 1024 * 1024
MAX_FILES = 30000
ACTIVE_LOCK_FDS = ()

class HAError(Exception):
    pass

def enabled():
    return bool(os.environ.get("LITEEDGE_HA_DIR"))

def canonical(obj):
    return json.dumps(obj,sort_keys=True,separators=(",",":")).encode()

def read_json(path):
    return json.loads(path.read_bytes())

def atomic(path, value):
    fd, name = tempfile.mkstemp(prefix=".ha-",dir=path.parent)
    try:
        with os.fdopen(fd,"wb") as f:
            f.write(canonical(value))
            f.flush()
            os.fsync(f.fileno())
        os.replace(name,path)
        dfd=os.open(path.parent,os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(name):
            os.unlink(name)

@contextlib.contextmanager
def file_lock(path):
    with path.open("a") as handle:
        fcntl.flock(handle,fcntl.LOCK_EX)
        yield handle.fileno()

@contextlib.contextmanager
def shared_file_lock(path, timeout=None, interval=0.2):
    """Retry nonblocking flock to avoid the NFS blocking-lock retry latency.

    The timeout bounds contention retries, not kernel I/O on a hard mount.
    """
    if timeout is None:
        timeout = int(os.environ.get("LITEEDGE_HA_LOCK_TIMEOUT_SECONDS", "60"))
        if not 1 <= timeout <= 600:
            raise HAError("LITEEDGE_HA_LOCK_TIMEOUT_SECONDS must be between 1 and 600")
    deadline = time.monotonic() + timeout
    with path.open("a") as handle:
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise HAError("Timed out acquiring shared HA writer lock")
                time.sleep(min(interval, remaining))
        yield handle.fileno()

def tree_items(root):
    count=0
    size=0
    for path in sorted(root.rglob("*")):
        rel=path.relative_to(root).as_posix()
        info=path.lstat()
        if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise HAError("Configuration source contains unsupported filesystem object")
        count+=1
        size+=info.st_size if stat.S_ISREG(info.st_mode) else 0
        if count>MAX_FILES or size>MAX_BYTES:
            raise HAError("Configuration source exceeds shared revision limit")
        yield path,rel,info

def digest(root):
    h=hashlib.sha256()
    for path,rel,info in tree_items(root):
        h.update(canonical([rel,"d" if stat.S_ISDIR(info.st_mode) else "f",stat.S_IMODE(info.st_mode)]))
        h.update(b"\n")
        if stat.S_ISREG(info.st_mode):
            h.update(str(info.st_size).encode()+b":")
            with path.open("rb") as f:
                for chunk in iter(lambda:f.read(1024*1024),b""):
                    h.update(chunk)
    return h.hexdigest()

def copy_path(src,dst):
    if src.is_symlink():
        raise HAError("Configuration symlinks are not supported")
    if src.is_dir():
        # Validate before copying, including nested special files.
        list(tree_items(src))
        shutil.copytree(src,dst)
    elif src.is_file():
        shutil.copy2(src,dst)
    else:
        raise HAError("Unsupported configuration path")

def capture(data, dest):
    dest.mkdir(mode=0o700,exist_ok=True)
    for part in PARTS:
        src=data/part
        if not src.exists() and not src.is_symlink():
            continue
        if part=="certs":
            if src.is_symlink():
                raise HAError("Certificate directory must not be a symlink")
            (dest/part).mkdir(mode=0o700)
            for item in sorted(src.iterdir()):
                if item.name!="_admin":
                    copy_path(item,dest/part/item.name)
        else:
            copy_path(src,dest/part)

def remove(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()

def install(data, source):
    for part in PARTS:
        dst=data/part
        src=source/part
        if part=="certs":
            dst.mkdir(exist_ok=True)
            for item in dst.iterdir():
                if item.name!="_admin":
                    remove(item)
            if src.exists():
                for item in src.iterdir():
                    if item.name=="_admin":
                        raise HAError("Shared revision contains node-local admin certificate")
                    copy_path(item,dst/item.name)
        else:
            remove(dst)
            if src.exists():
                copy_path(src,dst)

def run_render(data, reload=True):
    env=dict(os.environ,DATA_DIR=str(data),LITEEDGE_CONFIG_LOCK_HELD="1")
    for name in ("render-runtime.sh","render-nginx.sh"):
        subprocess.run([str(RUNTIME/"bin"/name)],env=env,check=True,
                       stdout=subprocess.DEVNULL,timeout=120,pass_fds=ACTIVE_LOCK_FDS)
    if reload:
        from nginx_reload import reload as confirmed_reload
        confirmed_reload(RUNTIME/"sbin/nginx",data/"nginx/nginx.conf",pass_fds=ACTIVE_LOCK_FDS)

class Shared:
    def __init__(self,data):
        self.data=Path(data).resolve()
        self.root=Path(os.environ["LITEEDGE_HA_DIR"]).resolve()
        self.node=os.environ.get("LITEEDGE_HA_NODE_ID","")
        if not self.root.is_dir() or self.root==self.data or self.data in self.root.parents or self.root in self.data.parents:
            raise HAError("Shared HA directory must be a separate mounted directory")
        try:
            cfg=read_json(self.root/"cluster.json")
            self.cluster=cfg["cluster_id"]
            self.members=cfg["members"]
            self.bootstrap=cfg["bootstrap_node"]
            self.key=Path(os.environ.get("LITEEDGE_HA_KEY_FILE",str(self.root/"key"))).read_bytes().strip()
            if not ID.fullmatch(self.cluster) or not ID.fullmatch(self.node) or not isinstance(self.members,dict) or self.node not in self.members or self.bootstrap not in self.members:
                raise HAError("Node is not a configured HA member")
            if any(not ID.fullmatch(n) or not isinstance(v,str) or not v for n,v in self.members.items()) or not HEX.fullmatch(self.key.decode("ascii")):
                raise HAError("Invalid HA member configuration or key")
        except (KeyError,ValueError,TypeError,OSError) as e:
            raise HAError("Invalid shared cluster membership or key") from e
        if not re.fullmatch(r"/[A-Za-z0-9._/-]+",str(self.root)) or str(self.root)!=os.environ["LITEEDGE_HA_DIR"]:
            raise HAError("HA mount must use a canonical absolute path safe for NGINX")
        self.marker=self.data/".liteedge-ha-applied.json"
        self.dirty=self.data/".liteedge-ha-pending.json"
        self.lock_fds=()
        self.current=None

    def signature(self, body):
        return hmac.new(bytes.fromhex(self.key.decode()),canonical(body),hashlib.sha256).hexdigest()

    def read(self):
        return self.read_manifest(self.root/"current.json")

    def read_manifest(self,path,historical=False):
        if not path.exists():
            return None
        try:
            obj=read_json(path)
            if not isinstance(obj,dict):
                raise ValueError("manifest is not an object")
            sig=obj.pop("signature",None)
        except (OSError,ValueError,TypeError) as e:
            raise HAError("Unreadable shared configuration manifest") from e
        if (set(obj)!={"version","cluster","revision","digest","writer"} or obj["version"]!=1
            or obj["cluster"]!=self.cluster or not isinstance(obj["writer"],str) or not ID.fullmatch(obj["writer"]) or (not historical and obj["writer"] not in self.members)
            or type(obj["revision"]) is not int or obj["revision"]<1 or not isinstance(obj["digest"],str)
            or not HEX.fullmatch(obj["digest"]) or not isinstance(sig,str)
            or not hmac.compare_digest(sig,self.signature(obj))):
            raise HAError("Untrusted shared configuration manifest")
        return obj

    def history_file(self,m):
        return self.root/"history"/("%020d-%s.json"%(m["revision"],m["digest"]))

    def save_history(self,m):
        path=self.history_file(m)
        path.parent.mkdir(mode=0o700,exist_ok=True)
        if path.exists():
            if self.read_manifest(path,historical=True)!=m:
                raise HAError("Conflicting historical manifest")
        else:
            atomic(path,{**m,"signature":self.signature(m)})

    def history(self):
        current=self.read()
        if current is None:
            raise HAError("Shared source not initialized")
        entries={current["revision"]:current}
        for path in sorted((self.root/"history").glob("*.json")):
            if not re.fullmatch(r"[0-9]{20}-[0-9a-f]{64}\.json",path.name):
                continue
            m=self.read_manifest(path,historical=True)
            if m is None or path!=self.history_file(m):
                raise HAError("Invalid historical manifest identity")
            # An interrupted publication may leave an uncommitted future
            # manifest; never present it as a restore candidate.
            if m["revision"]>=current["revision"]:
                continue
            if m["revision"] in entries and entries[m["revision"]]!=m:
                raise HAError("Ambiguous historical revision")
            entries[m["revision"]]=m
        return [entries[k] for k in sorted(entries)]

    def restore_revision(self,revision):
        import providerctl
        current=self.read()
        if current is None or self.current!=current:
            raise HAError("Shared source not synchronized")
        candidates=[m for m in self.history() if m["revision"]==revision]
        if not candidates or revision>=current["revision"]:
            raise HAError("Select an earlier retained signed revision")
        old=self.verify_source(candidates[0])
        # Credential and authorization changes are never silently undone.
        def policy_digest(source):
            directory=source/"providers"
            return digest(directory) if directory.exists() else None
        if policy_digest(old)!=policy_digest(self.directory(current)):
            raise HAError("Historical provider authorization differs; explicit migration required")
        states={}
        for source in (self.data,old):
            for path in (source/"sites").glob(".provider-*.json"):
                name=path.name[len(".provider-"):-len(".json")]
                if not providerctl.PROVIDER.fullmatch(name):
                    raise HAError("Invalid provider revision history")
                state=providerctl.state(source,name)
                if type(state["revision"]) is not int or state["revision"]<0:
                    raise HAError("Invalid provider revision history")
                states[name]=max(states.get(name,0),state["revision"])
        self.begin_write()
        try:
            install(self.data,old)
            # Keep controller compare-and-swap monotonic even when restoring
            # a revision before a provider first created any managed sites.
            for name,highest in states.items():
                state=providerctl.state(self.data,name)
                state["revision"]=highest+1
                providerctl.atomic(providerctl.state_path(self.data,name),providerctl.canonical(state))
            remove(self.data/"nginx")
            run_render(self.data)
            self.publish()
        except Exception:
            self.sync(force=True)
            raise
        return self.current

    def prune(self,keep,apply=False):
        if type(keep) is not int or not 2<=keep<=1000:
            raise HAError("Keep between 2 and 1000 signed revisions")
        entries=self.history()
        old=entries[:-keep]
        # Only verified, committed, historical manifests are eligible.
        # Untracked directories from old versions or interrupted writes are
        # deliberately left for operator inspection.
        for m in old:
            self.verify_source(m)
        if apply:
            for m in old:
                # Remove manifest first, so an interrupted prune never
                # advertises an already deleted restore target.
                self.history_file(m).unlink()
                remove(self.directory(m))
        return [m["revision"] for m in old]

    def directory(self,m):
        return self.root/("revision-%020d-%s"%(m["revision"],m["digest"]))

    def local(self):
        return read_json(self.marker) if self.marker.exists() else None

    def record(self,m):
        atomic(self.marker,{"cluster":self.cluster,"revision":m["revision"],"digest":m["digest"]})

    def check_rollback(self,m):
        old=self.local()
        if old and (old.get("cluster")!=self.cluster or old["revision"]>m["revision"]
                    or (old["revision"]==m["revision"] and old["digest"]!=m["digest"])):
            raise HAError("Shared revision rollback or identity mismatch")

    def verify_source(self,m):
        source=self.directory(m)
        if source.is_symlink() or not source.is_dir() or digest(source)!=m["digest"]:
            raise HAError("Shared configuration content failed integrity verification")
        if any(p.name not in PARTS for p in source.iterdir()):
            raise HAError("Unexpected shared configuration source")
        return source

    def sync(self, reload=True, force=False):
        m=self.read()
        if m is None:
            raise HAError("Shared configuration is not initialized")
        self.check_rollback(m)
        local=self.local()
        if not force and not self.dirty.exists() and local and local["revision"]==m["revision"]:
            self.current=m
            return False
        source=self.verify_source(m)
        # Backup the native source and rendered config separately; never copy
        # runtime logs, sockets, local admin credentials or node health data.
        with tempfile.TemporaryDirectory(prefix=".ha-local-",dir=self.data) as tmp:
            backup=Path(tmp)
            capture(self.data,backup/"source")
            nginx=self.data/"nginx"
            if nginx.exists():
                shutil.copytree(nginx,backup/"nginx",symlinks=True)
            try:
                install(self.data,source)
                remove(nginx)
                run_render(self.data,reload)
                self.record(m)
                self.dirty.unlink(missing_ok=True)
            except Exception:
                install(self.data,backup/"source")
                remove(nginx)
                if (backup/"nginx").exists():
                    shutil.copytree(backup/"nginx",nginx,symlinks=True)
                if reload:
                    try:
                        from nginx_reload import reload as confirmed_reload
                        confirmed_reload(RUNTIME/"sbin/nginx",nginx/"nginx.conf",pass_fds=ACTIVE_LOCK_FDS)
                    except Exception:
                        pass
                raise
        self.current=m
        return True

    def local_matches(self):
        with tempfile.TemporaryDirectory(prefix=".ha-check-",dir=self.data) as tmp:
            stage=Path(tmp)/"source"
            capture(self.data,stage)
            return self.current is not None and digest(stage)==self.current["digest"]

    def prepare_write(self):
        if self.current is None:
            raise HAError("Shared source not initialized")
        self.verify_source(self.current)
        if not self.local_matches():
            self.sync(force=True)

    def begin_write(self):
        self.prepare_write()
        atomic(self.dirty,{"cluster":self.cluster,"revision":self.current["revision"]})

    def finish_write(self):
        self.dirty.unlink(missing_ok=True)

    def publish(self):
        # Caller owns the shared lock. Only validated native config is committed.
        base=self.read()
        if base!=self.current:
            raise HAError("Shared revision changed while writing")
        with tempfile.TemporaryDirectory(prefix=".ha-stage-",dir=self.root) as tmp:
            stage=Path(tmp)/"source"
            capture(self.data,stage)
            fingerprint=digest(stage)
            if base and base["digest"]==fingerprint:
                self.record(base)
                self.finish_write()
                return False
            m={"version":1,"cluster":self.cluster,"revision":1 if base is None else base["revision"]+1,
               "digest":fingerprint,"writer":self.node}
            target=self.directory(m)
            if target.exists():
                if digest(target)!=fingerprint:
                    raise HAError("Conflicting shared revision directory")
            else:
                # Persist source content before publishing the atomic pointer.
                for path,_,info in tree_items(stage):
                    if stat.S_ISREG(info.st_mode):
                        with path.open("rb") as f:
                            os.fsync(f.fileno())
                for path in reversed([stage]+[p for p,_,info in tree_items(stage) if stat.S_ISDIR(info.st_mode)]):
                    fd=os.open(path,os.O_RDONLY)
                    try:
                        os.fsync(fd)
                    finally:
                        os.close(fd)
                os.replace(stage,target)
            if base:
                self.save_history(base)
            atomic(self.root/"current.json",{**m,"signature":self.signature(m)})
            self.current=m
            self.record(m)
            self.finish_write()
            return True

    def init_acme(self):
        path=self.root/"acme"
        if path.is_symlink():
            raise HAError("Shared ACME directory cannot be a symlink")
        for sub in ("sites","certs","challenges/.well-known/acme-challenge"):
            (path/sub).mkdir(parents=True,exist_ok=True)
        path.chmod(0o700)

    def startup(self):
        m=self.read()
        if m is not None:
            self.init_acme()
            self.sync(reload=False,force=True)
            return
        if any(self.root.glob("revision-*")):
            raise HAError("Missing shared manifest with existing revisions; operator recovery required")
        if self.local() or self.node!=self.bootstrap or os.environ.get("LITEEDGE_HA_BOOTSTRAP")!="1":
            raise HAError("Only the designated bootstrap member may initialize the shared source")
        # Advanced raw/imported configuration cannot yet be portably replicated.
        for part in ("imported","migration"):
            if (self.data/part).is_dir() and any((self.data/part).iterdir()):
                raise HAError("Imported configuration is not supported in shared HA mode")
        for f in (self.data/"nginx/sites").glob("*.conf"):
            baseline=self.data/"nginx/baselines"/f.name
            if not baseline.exists() or f.read_bytes()!=baseline.read_bytes():
                raise HAError("Manual NGINX overrides must be removed before HA bootstrap")
        self.init_acme()
        run_render(self.data,reload=False)
        self.publish()

@contextlib.contextmanager
def session(data, sync=True):
    global ACTIVE_LOCK_FDS
    if not enabled():
        with file_lock(Path(data)/".liteedge-config.lock"):
            yield None
        return
    h=Shared(data)
    # All processes use shared -> local lock order, never the reverse.
    with shared_file_lock(h.root/".writer.lock") as shared_fd:
        with file_lock(h.data/".liteedge-config.lock") as local_fd:
            h.lock_fds=(shared_fd,local_fd)
            previous=ACTIVE_LOCK_FDS
            ACTIVE_LOCK_FDS=h.lock_fds
            try:
                if (h.data/".liteedge-provider-transaction").exists():
                    import providerctl
                    providerctl.recover(h.data)
                    atomic(h.dirty,{"cluster":h.cluster,"recovery":True})
                if sync:
                    h.sync()
                yield h
            finally:
                ACTIVE_LOCK_FDS=previous

def main():
    data=Path(os.environ.get("DATA_DIR","/data"))
    command=sys.argv[1]
    if command=="startup":
        with session(data,sync=False) as h:
            h.startup()
    elif command in ("history","restore-revision","prune"):
        parser=argparse.ArgumentParser()
        parser.add_argument("command",choices=("history","restore-revision","prune"))
        if command=="restore-revision":
            parser.add_argument("revision",type=int)
        elif command=="prune":
            parser.add_argument("--keep",type=int,default=10)
            parser.add_argument("--apply",action="store_true")
        args=parser.parse_args()
        with session(data) as h:
            if command=="history":
                result={"current":h.current["revision"],"revisions":h.history()}
            elif command=="restore-revision":
                result={"restored_from":args.revision,"current":h.restore_revision(args.revision)}
            else:
                result={"applied":args.apply,"pruned" if args.apply else "candidates":h.prune(args.keep,args.apply)}
        print(json.dumps(result))
    elif command=="ready":
        import socket
        # Readiness requires local runtime plus a completed signed revision.
        # If the source is unavailable, preserve service on last good state.
        if (data/".liteedge-ha-pending.json").exists():
            sys.exit(1)
        try:
            marker=read_json(data/".liteedge-ha-applied.json")
            if type(marker["revision"]) is not int or marker["revision"]<1 or not HEX.fullmatch(marker["digest"]):
                sys.exit(1)
        except (OSError,ValueError,KeyError,TypeError):
            sys.exit(1)
        with socket.create_connection(("127.0.0.1",int(os.environ.get("LITEEDGE_ADMIN_HTTPS_PORT","9443"))),timeout=1):
            pass
        try:
            h=Shared(data)
            current=h.read()
            if current is not None:
                h.check_rollback(current)
                if h.local()["revision"]<current["revision"]:
                    sys.exit(1)
        except (OSError,HAError,ValueError,KeyError):
            pass
    elif command=="watch":
        delay=max(1,min(60,int(os.environ.get("LITEEDGE_HA_POLL_SECONDS","2"))))
        while True:
            try:
                with session(data) as h:
                    pass
            except Exception as e:
                print("HA refresh failed: "+str(e),file=sys.stderr,flush=True)
            time.sleep(delay)
    else:
        raise HAError("Unknown HA command")

if __name__=="__main__":
    main()
