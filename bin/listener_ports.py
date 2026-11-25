#!/usr/bin/env python3
"""Operator-provisioned additional HTTP listener mappings (public:bind)."""
import os
import re
import sys

def port(s):
    if not isinstance(s,str) or not re.fullmatch(r"[1-9][0-9]{0,4}",s) or int(s)>65535:
        raise ValueError("Invalid listener port")
    return int(s)

def mappings():
    public={int(os.getenv("LITEEDGE_PUBLIC_HTTP_PORT","80")),int(os.getenv("LITEEDGE_PUBLIC_HTTPS_PORT","443")),80,443,9443}
    bind={int(os.getenv("LITEEDGE_HTTP_PORT","80")),int(os.getenv("LITEEDGE_HTTPS_PORT","443")),int(os.getenv("LITEEDGE_ADMIN_HTTPS_PORT","9443"))}
    result={}
    for protocol in ("http","https"):
        raw=os.getenv("LITEEDGE_EXTRA_"+protocol.upper()+"_PORTS","")
        if not raw:continue
        for row in raw.split(","):
            parts=row.split(":")
            if len(parts)!=2:raise ValueError("Expected public:bind listener mapping")
            p,b=map(port,parts)
            if p in public or b in bind or p==int(os.getenv("LITEEDGE_ADMIN_HTTPS_PORT","9443")) or b<1024:
                raise ValueError("Extra port conflicts with a reserved or privileged listener")
            public.add(p);bind.add(b)
            result[protocol+":"+str(p)]=b
    if len(result)>16:raise ValueError("At most 16 extra listener ports")
    return result

def valid_key(s):
    if s in ("http","https"):return True
    if not isinstance(s,str) or ":" not in s:return False
    protocol,number=s.split(":",1)
    if protocol not in ("http","https"):return False
    try:return port(number) not in (80,443,9443)
    except ValueError:return False

def extra_port(s):
    return int(s.split(":",1)[1]) if ":" in s else None

def is_https(s):
    return s=="https" or s.startswith("https:")

def site_listeners(record,routes):
    keys=set((record.get("GW_LISTENERS") or "http,https").split(","))
    if not record.get("PROVIDER"):
        for route in routes:
            keys.update(s for s in (route.get("SCHEMES") or "http,https").split(",") if ":" in s)
    if not all(valid_key(s) for s in keys):raise ValueError("Invalid persisted listener key")
    extra=mappings()
    if any(":" in s and s not in extra for s in keys):raise ValueError("Listener port not provisioned on appliance")
    return sorted(keys)

def main():
    for key,b in sorted(mappings().items()):
        print(key,b)
if __name__=="__main__":
    try:main()
    except ValueError as e:print(e,file=sys.stderr);sys.exit(1)
