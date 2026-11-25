#!/usr/bin/env python3
"""Native administrator L4 route edits use the same transaction and HA lock."""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import providerctl as p
import stream_routes as s

def save(data,raw):
    p.require(os.environ.get("LITEEDGE_CONFIG_LOCK_HELD")=="1","Configuration lock required")
    p.require(not p.journal(data).exists(),"Pending configuration recovery",503)
    routes=s.normalize(raw)
    s.check_ownership(data,s.NATIVE,routes)
    for name in p.PARTS:(data/name).mkdir(exist_ok=True)
    stage=Path(tempfile.mkdtemp(prefix=".liteedge-stream-stage-",dir=data))
    try:
        for name in p.PARTS:shutil.copytree(data/name,stage/name,symlinks=True)
        p.sync_tree(stage);os.replace(stage,p.journal(data));p.sync_directory(data)
    finally:
        if stage.exists():shutil.rmtree(stage)
    previously_degraded={item["host"] for item in p.read_json(data/"nginx/degraded-sites.json", [])}
    try:
        path=s.file(data,s.NATIVE)
        if routes:p.atomic(path,p.canonical(routes))
        else:path.unlink(missing_ok=True)
        p.require(not (p.render(data)-previously_degraded),"Transport edit would degrade HTTP sites")
        for name in p.PARTS:p.sync_tree(data/name)
        p.sync_directory(data)
        p.reload(data)
    except Exception:
        p.recover(data,p.reload)
        raise ValueError("Transport configuration rejected; previous state restored") from None
    p.discard_journal(data)

if __name__=="__main__":
    try:save(Path(os.getenv("DATA_DIR","/data")),json.load(sys.stdin,object_pairs_hook=p.unique_object))
    except (p.Error,ValueError,PermissionError,TypeError,KeyError,OSError) as e:print(str(e),file=sys.stderr);sys.exit(1)
