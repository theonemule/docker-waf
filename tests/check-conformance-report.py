#!/usr/bin/env python3
"""Release gate: verify upstream report, not just a successful runner exit."""
import sys
from pathlib import Path
import yaml
if len(sys.argv)!=4:
    raise SystemExit("Usage: check-conformance-report.py REPORT PROFILE VERSION")
path,profile,version=sys.argv[1:]
data=yaml.safe_load(Path(path).read_text())
assert data["kind"]=="ConformanceReport"
assert data["gatewayAPIVersion"]=="v1.4.0" and data["gatewayAPIChannel"]=="standard"
assert data["implementation"]["version"]==version
assert data["mode"]=="client-validated-frontend"
profiles=[p for p in data["profiles"] if p["name"]==profile]
assert len(profiles)==1
core=profiles[0]["core"]
stats=core["statistics"]
assert core["result"]=="success" and stats["Failed"]==0 and stats["Skipped"]==0 and stats["Passed"]>0
print(f"{profile}: {stats['Passed']} passed; 0 failed; 0 skipped")
