#!/usr/bin/env python3
"""Scoped read endpoints read current files without expanding unrelated data."""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
import site_read as sr
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    def write(path, text):
        f = root / path
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
        return f
    site = write("sites/manual.test.site", "HOST=manual.test\nALIASES=www.manual.test\nENABLED=1\n")
    write("sites/_.managed.test.site", "HOST=*.managed.test\nPROVIDER=cluster-a\nGW_LISTENERS=http,https\nGW_TLS_REJECT=1\n")
    route = write("sites/manual.test.routes/0123456789abcdef.route", "ID=0123456789abcdef\nMATCH=prefix\nPATH=/api\nTARGET=http://app:8080\nWAF=1\nWAF_PL=1\n")
    write("sites/_.managed.test.routes/1111111111111111.route", "ID=1111111111111111\nMATCH=prefix\nPATH=/\nTARGET=http://app:8080\nPROVIDER_ROUTE=1\n")
    write("certs/manual.test/mode", "manual\n")
    write("nginx/sites/manual.test.conf", "# raw nginx only\n")
    write("nginx/baselines/manual.test.conf", "# not requested\n")
    write("sites/manual.test.waf-disabled", "100\n100\n20\nnot-a-rule\n")
    write("waf/plugins/test/.liteedge-plugin", "TYPE=app\nCATEGORY=plugin\n")
    # Corrupt a policy that must not be parsed during list and overview reads.
    route.write_text(route.read_text()+"GW_MATCH_B64=invalid!\n")
    data = sr.inventory(root)
    assert [s["route_count"] for s in data["sites"]] == [1,1]
    assert all(set(s)=={"host","aliases","enabled","tls","provider","route_count"} for s in data["sites"])
    o = sr.overview(root, sr.site_record(root,"manual.test"))["site"]
    assert o["routes"][0]["path"] == "/api" and "configuration" not in o
    assert "header_matches" not in o["routes"][0]["features"]
    assert o["disabled_rules"] == ["20","100"]
    assert sr.overview(root,sr.site_record(root,"*.managed.test"))["site"]["tls_listeners"]["https"]=="rejected"
    def request(*args):
        env={**os.environ,"DATA_DIR":temp}
        raw=subprocess.check_output([sys.executable,str(ROOT/"bin/site_read.py"),*args],env=env).decode()
        header,body=raw.split("\r\n\r\n",1)
        assert "Cache-Control: no-store" in header
        return int(header.splitlines()[0].split()[1]),json.loads(body)
    assert request("route","manual.test","0123456789abcdef")[0]==500
    route.write_text(route.read_text().split("GW_MATCH_B64=")[0])
    code, d = request("route","manual.test","0123456789abcdef")
    assert code==200 and d["route"]["features"]["header_matches"]==[]
    assert request("configuration","manual.test")[1]=={"ok":True,"configuration":"# raw nginx only","conflict":"","delta":""}
    assert request("configuration","*.managed.test")[0]==403
    assert request("overview","../manual.test")[0]==400
    assert request("route","manual.test","../passwd")[0]==400
    assert request("route","manual.test","aaaaaaaaaaaaaaaa")[0]==404
    assert request("overview","missing.test")[0]==404
    assert request("plugins")[1]["installed"][0]["name"]=="test"
    route.unlink()
    site.write_text("HOST=manual.test\nENABLED=0\n")
    s=next(s for s in request("inventory")[1]["sites"] if s["host"]=="manual.test")
    assert s["route_count"]==0 and not s["enabled"], "must see external edits without invalidation"
print("PASS scoped inventory, overview, route, advanced configuration, ownership, input validation and fresh reads")
