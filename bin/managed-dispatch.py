#!/usr/bin/env python3
"""Compile typed managed route predicates into NGINX HTTP-context maps.

No raw regex or directive is accepted from the provider. Literal matching
uses hex-escaped ASCII and the native route renderer owns the selected
location, including its WAF and traffic controls.
"""
import base64
import hashlib
import json
import re
import sys
from pathlib import Path
import route_features as features
import listener_ports as ports

def kv(path):
    return dict(line.split("=",1) for line in path.read_text().splitlines() if "=" in line)

def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()[:24]

def dispatch_var(host, scheme):
    return "liteedge_select_" + digest(host+"/"+scheme)

def literal(value):
    # Hex escape every byte: no config delimiters or regex metacharacters.
    return "".join(r"\x%02x" % b for b in value.encode("ascii"))

def flag(source, name, expression):
    print(f'map {source} ${name} {{ default 0; "~{expression}" 1; }}')

def emit(data):
    for site in sorted((data/"sites").glob("*.site")):
        s=kv(site)
        host=s["HOST"]
        routes=[kv(p) for p in sorted((data/"sites"/(host.replace("*","_")+".routes")).glob("*.route"))]
        managed=bool(s.get("PROVIDER"))
        typed=any(r.get("TYPED_ROUTE")=="1" for r in routes)
        enabled=s.get("GW_DISPATCH")=="1" if managed else typed
        if not managed and any(r.get("PROVIDER_ROUTE")=="1" for r in routes):
            raise ValueError("Provider route in manual site")
        # Compile path replacement maps and validate typed records even when
        # ordinary native NGINX location matching is sufficient.
        for r in routes:
            if not (managed or r.get("TYPED_ROUTE")=="1"):continue
            f=features.from_record(r,managed)
            for index,mirror in enumerate(f["mirrors"]):
                points=mirror["basis_points"]
                if points<10000:
                    salt=digest(host+"/"+r["ID"]+"/"+str(index))
                    percent=f"{points//100}.{points%100:02d}"
                    print(f'split_clients "${{request_id}}:{salt}" $le_mirror_{salt} {{ {percent}% 1; * 0; }}')
            modifier=(f["rewrite"] or f["redirect"] or {}).get("path")
            if modifier:
                rid=r["ID"]
                name="le_path_"+digest(host+"/"+rid)
                replacement=modifier["value"]
                if modifier["type"]=="full":
                    print(f'map $uri ${name} {{ default "{replacement}"; }}')
                else:
                    original=r["PATH"].rstrip("/") or "/"
                    cap="le_tail_"+digest(host+"/"+rid)
                    # Retain escaped request-path bytes, not decoded $uri
                    # bytes (which may contain CR/LF or delimiters). Reject
                    # a normalized-only match rather than constructing an
                    # ambiguous upstream URI or Location header.
                    allowed=r"(?:[A-Za-z0-9._~+/@:=,;!&()-]|%[0-9A-Fa-f][0-9A-Fa-f])*"
                    print(f'map $request_uri ${name} {{')
                    print('    default "";')
                    print(f'    "~^{literal(original)}(?:\\?.*)?$" "{replacement}";')
                    if original=="/":
                        print(f'    "~^/(?<{cap}>{allowed})(?:\\?.*)?$" "{replacement.rstrip("/")}/${cap}";')
                    else:
                        print(f'    "~^{literal(original)}/(?<{cap}>{allowed})(?:\\?.*)?$" "{replacement.rstrip("/")}/${cap}";')
                    print("}")
        if not enabled:continue
        if not managed:
            if s.get("MODE") or (data/"imported/sites"/host/"template.conf").exists():
                raise ValueError("Convert imported or legacy site before using typed route matching")
            for r in routes:
                if r.get("ACTION")=="custom" or r.get("MATCH") not in ("exact","prefix") or not features.literal_path(r.get("PATH","")) or r.get("REWRITE_ENABLED")=="1":
                    raise ValueError("Typed matching cannot coexist with regex/custom/legacy rewrite routes on the same site")
                if r.get("TARGET") and not re.fullmatch(r"https?://[A-Za-z0-9._:-]+",r["TARGET"]):
                    raise ValueError("Typed matching requires origin-only upstream URLs on this site")
                for url in r.get("BACKENDS","").split(","):
                    if url and not re.fullmatch(r"https?://[A-Za-z0-9._:-]+",url):
                        raise ValueError("Typed matching requires origin-only pool backends")
        for scheme in ports.site_listeners(s,routes):
            selected=[]
            seen=set()
            for r in routes:
                if scheme not in r.get("SCHEMES","http,https").split(","):continue
                f=features.from_record(r,managed)
                headers=f["header_matches"];method=f["method"];queries=f["query_matches"]
                path=r["PATH"].rstrip("/") or "/" if r["MATCH"]=="prefix" and (managed or r.get("TYPED_ROUTE")=="1") else r["PATH"]
                key=(r["MATCH"],path,json.dumps(headers),json.dumps(queries),method)
                if key in seen:raise ValueError("Conflicting native route match")
                seen.add(key)
                selected.append((r,headers,method,queries,path))
            selected.sort(key=lambda item: (
                -int(item[0].get("GW_HOST_PRIORITY") or 0),
                item[0]["MATCH"]!="exact",
                -len(item[4]),
                not bool(item[2]),
                -len(item[1]),
                -len(item[3]),
                int(item[0].get("GW_PRECEDENCE") or 0),
                item[0]["ID"]))
            names=[]
            for r,headers,method,queries,path in selected:
                rid=r["ID"]
                if not re.fullmatch("[0-9a-f]{16}",rid):
                    raise ValueError("invalid managed route id")
                stem="le_match_"+digest(host+"/"+scheme+"/"+rid)
                if r["MATCH"]=="exact":
                    regex="^"+literal(path)+"$"
                elif not managed and r.get("TYPED_ROUTE")!="1":
                    regex="^"+literal(path)
                elif path=="/":
                    regex="^"+literal("/")
                else:
                    regex="^"+literal(path)+"(?:/|$)"
                flag("$uri",stem+"_p",regex)
                bits=["$"+stem+"_p"]
                if method:
                    flag("$request_method",stem+"_m","^"+literal(method)+"$")
                    bits.append("$"+stem+"_m")
                for i,h in enumerate(headers):
                    name=h["name"]
                    if not re.fullmatch("[a-z][a-z0-9-]{0,63}",name):
                        raise ValueError("invalid header match name")
                    # Exact values are case sensitive, unlike literal map keys.
                    suffix="_h"+str(i)
                    flag("$http_"+name.replace("-","_"),stem+suffix,"^"+literal(h["value"])+"$")
                    bits.append("$"+stem+suffix)
                for i,q in enumerate(queries):
                    suffix="_q"+str(i)
                    flag("$args",stem+suffix,"(?:^|&)"+literal(q["name"])+"="+literal(q["value"])+"(?:&|$)")
                    bits.append("$"+stem+suffix)
                print('map "'+"".join(bits)+'" $'+stem+' { default 0; "'+"1"*len(bits)+'" 1; }')
                names.append((stem,rid))
            dest=dispatch_var(host,scheme)
            if not names:
                print(f"map $uri ${dest} {{ default @le_not_found; }}")
                continue
            print('map "'+"".join("$"+n for n,_ in names)+'" $'+dest+' {')
            print("    default @le_not_found;")
            for i,(_,rid) in enumerate(names):
                print(f'    "~^{"0"*i}1" @le_route_{rid};')
            print("}")

if __name__=="__main__":
    emit(Path(sys.argv[1]))
