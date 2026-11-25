#!/usr/bin/env python3
"""Confirm a reload by probing a generation-specific private NGINX listener."""
import http.client
import nginx_generation as generation
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import time

def runtime():
    path=Path(os.environ.get("LITEEDGE_RUN_DIR","/tmp/liteedge-run"))
    if not re.fullmatch(r"/[A-Za-z0-9_./-]+",str(path)):
        raise ValueError("Invalid reload listener directory")
    return path

def publish_marker(directory):
    """Publish a new, local-only generation marker atomically."""
    marker=secrets.token_hex(24)
    config=('server { listen unix:'+str(directory/"reload-ack.sock")+
            '; server_name localhost; access_log off; location = / { return 200 "'+
            marker+'"; } location / { return 404; } }\n')
    fd,temporary=tempfile.mkstemp(prefix=".reload-ack-",dir=directory)
    try:
        with os.fdopen(fd,"w") as f:
            f.write(config); f.flush(); os.fsync(f.fileno())
        os.replace(temporary,directory/"reload-ack.conf")
    finally:
        Path(temporary).unlink(missing_ok=True)
    return marker

def probe(directory,marker):
    try:
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
            connection.settimeout(0.5)
            connection.connect(str(directory/"reload-ack.sock"))
            connection.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            response=http.client.HTTPResponse(connection)
            response.begin()
            return response.status==200 and response.read(64)==marker.encode()
    except (OSError,http.client.HTTPException):
        return False

def reload(binary,config,*,pass_fds=(),timeout=30):
    directory=runtime()
    master=int((directory/"nginx.pid").read_text().strip())
    if master<=0:
        raise RuntimeError("Invalid NGINX master PID")
    root=generation.root_for(config)
    previous=generation.current(root)
    if previous is None:
        raise RuntimeError("Restart appliance to initialize immutable configuration publication")
    marker=secrets.token_hex(24)
    candidate=generation.stage(binary,config,directory,marker,pass_fds=pass_fds,timeout=timeout)
    old_workers=generation.workers(master)
    generation.activate(root,candidate)
    try:
        subprocess.run([str(binary),"-s","reload","-c",str(root/"active.conf")],check=True,
                       stdout=subprocess.DEVNULL,timeout=timeout,pass_fds=pass_fds)
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            if probe(directory,marker):
                # A worker may have respawned during signaling. Include
                # all children observed after acknowledgement as well; this
                # conservatively retains the prior snapshot through their exit.
                after=generation.workers(master)
                if old_workers is not None and after is not None:
                    generation.retire(root,previous,{**old_workers,**after})
                generation.prune(root)
                return
            time.sleep(.05)
        raise RuntimeError("NGINX reload did not serve the requested generation")
    except BaseException:
        # Restore the pointer even if the signal or acknowledgment failed.
        # The caller's transaction recovery performs a freshly acknowledged
        # reload of the restored source. Retain candidate files until restart.
        generation.activate(root,previous)
        raise

if __name__=="__main__":
    try:
        if sys.argv[1:]==["init"]:
            directory=runtime()
            if not (directory/"reload-ack.conf").is_file():
                publish_marker(directory)
        elif len(sys.argv)==4 and sys.argv[1]=="startup":
            generation.startup(sys.argv[2],sys.argv[3],runtime(),secrets.token_hex(24))
        else:
            reload(sys.argv[1],sys.argv[2])
    except (OSError,ValueError,IndexError,RuntimeError,subprocess.SubprocessError) as exc:
        print(f"NGINX reload failed: {exc}",file=sys.stderr)
        sys.exit(1)
