#!/usr/bin/env python3
"""Hold the appliance writer lock across a shell/Python command and its children."""
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import json
import re

def disallowed(argv):
    name=Path(argv[0]).name
    action=argv[1] if len(argv)>1 else ""
    if name=="sitectl.sh" and action in ("config-save","config-reset"):
        return True
    if name=="bundlectl.sh" and action=="import":
        return True
    if any(Path(x).name=="backupctl.py" for x in argv[:2]) and "restore" in argv[1:3]:
        return True
    if name=="admin.sh":
        path=os.environ.get("PATH_INFO","")
        return (path.endswith(("/config/save","/config/reset","/backup/restore"))
                or path in ("/api/v1/import","/admin/import","/admin/backup/restore"))
    return False

def failure(message,cgi):
    if cgi:
        print("Status: 503\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n"+
              json.dumps({"ok":False,"error":message}),end="")
        return 0
    print(message,file=sys.stderr)
    return 1

def shared_run(data,argv):
    from ha_config import session
    cgi=Path(argv[0]).name=="admin.sh"
    if disallowed(argv):
        return failure("This operation is not yet supported in shared HA mode",cgi)
    try:
        with session(data) as h:
            h.begin_write()
            env=dict(os.environ,LITEEDGE_CONFIG_LOCK_HELD="1")
            result=subprocess.run(argv,env=env,stdout=subprocess.PIPE if cgi else None,pass_fds=h.lock_fds)
            rejected=result.returncode!=0 or (cgi and re.match(rb"Status: [45][0-9][0-9]",result.stdout))
            if rejected:
                # Reconcile from the canonical source on failures; never publish partial edits.
                try:
                    matches=h.local_matches()
                except Exception:
                    matches=False
                if not matches:
                    h.sync(force=True)
                else:
                    h.finish_write()
            else:
                try:
                    h.publish()
                except Exception:
                    h.sync(force=True)
                    raise
            if cgi:
                sys.stdout.buffer.write(result.stdout)
            return result.returncode
    except Exception as e:
        print("Shared HA transaction failed: "+str(e),file=sys.stderr)
        return failure("Shared configuration unavailable or rejected",cgi)

if __name__ == "__main__":
    data = Path(os.environ.get("DATA_DIR", "/data"))
    data.mkdir(parents=True, exist_ok=True)
    if os.environ.get("LITEEDGE_HA_DIR"):
        sys.exit(shared_run(data,sys.argv[1:]))
    with (data / ".liteedge-config.lock").open("a") as fd:
        fcntl.flock(fd, fcntl.LOCK_EX)
        if (data / ".liteedge-provider-transaction").exists():
            print("Provider transaction recovery required before configuration writes.", file=sys.stderr)
            sys.exit(1)
        env = dict(os.environ, LITEEDGE_CONFIG_LOCK_HELD="1")
        sys.exit(subprocess.call(sys.argv[1:], env=env, pass_fds=(fd.fileno(),)))
