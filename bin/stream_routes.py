#!/usr/bin/env python3
"""Typed, independently authorized L4 routes. No arbitrary NGINX directives."""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import listener_ports as ports

PROTOCOLS=("tcp","udp","tls")
NATIVE="_native"
ORIGIN=re.compile(r"(tcp|udp)://([a-z0-9.-]+):([1-9][0-9]{0,4})")
def require(ok,msg):
    if not ok:raise ValueError(msg)
def mappings():
    http=ports.mappings()
    public={80,443,9443,int(os.getenv("LITEEDGE_PUBLIC_HTTP_PORT","80")),int(os.getenv("LITEEDGE_PUBLIC_HTTPS_PORT","443")),int(os.getenv("LITEEDGE_ADMIN_HTTPS_PORT","9443"))}|{ports.extra_port(k) for k in http}
    bind={int(os.getenv("LITEEDGE_HTTP_PORT","80")),int(os.getenv("LITEEDGE_HTTPS_PORT","443")),int(os.getenv("LITEEDGE_ADMIN_HTTPS_PORT","9443"))}|set(http.values())
    result={}
    for kind in PROTOCOLS:
        raw=os.getenv("LITEEDGE_EXTRA_"+kind.upper()+"_PORTS","")
        if not raw:continue
        for row in raw.split(","):
            v=row.split(":")
            require(len(v)==2,"Expected public:bind transport mapping")
            p,b=map(ports.port,v)
            # Conservative: no public or bind overlap even between TCP and UDP.
            require(p not in public and b not in bind and b>=1024,"Transport port conflicts with provisioned or reserved listener")
            public.add(p);bind.add(b);result[kind,p]=b
    require(len(result)<=16,"At most 16 transport listener ports")
    return result
def host_valid(host):
    return isinstance(host,str) and len(host)<=253 and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?",p) for p in host.split("."))
def host_scoped(host,policy):
    return any(host==s or host.endswith("."+s) for s in policy.get("host_suffixes",[]))
def allowed_policy(policy):
    values=policy.get("stream_ports",{})
    require(isinstance(values,dict) and set(values)<=set(PROTOCOLS),"Invalid transport port scope")
    for kind,items in values.items():
        require(isinstance(items,list) and len(items)<=16 and all(type(p) is int and 1<=p<=65535 and p not in (80,443,9443) for p in items) and len(set(items))==len(items),"Invalid transport port scope")
    return values
def normalize_one(raw,policy=None):
    require(isinstance(raw,dict) and set(raw)<= {"protocol","port","hostname","backends"} and {"protocol","port","backends"}<=set(raw),"Invalid transport route fields")
    kind,p=raw["protocol"],raw["port"]
    require(kind in PROTOCOLS and type(p) is int and (kind,p) in mappings(),"Transport listener not provisioned")
    if policy is not None:
        if policy.get("allow_stream") is not True or p not in allowed_policy(policy).get(kind,[]):raise PermissionError("Transport listener not authorized")
    host=raw.get("hostname","")
    if kind=="tls":
        require(host=="*" or host_valid(host[2:] if isinstance(host,str) and host.startswith("*.") else host),"Invalid TLS passthrough hostname")
        if policy is not None:
            if host=="*":
                if policy.get("allow_catch_all_tls") is not True:raise PermissionError("TLS passthrough catch-all not authorized")
            elif (host.startswith("*.") and policy.get("allow_wildcards") is not True) or not host_scoped(host.removeprefix("*."),policy):raise PermissionError("TLS passthrough hostname outside scope")
    else:require(host=="","TCP/UDP routes cannot match hostnames")
    entries=raw["backends"]
    require(isinstance(entries,list) and 1<=len(entries)<=16,"Invalid transport pool size")
    pool={}
    for entry in entries:
        require(isinstance(entry,dict) and set(entry)=={"target","weight"},"Invalid transport backend fields")
        target,w=entry["target"],entry["weight"]
        require(isinstance(target,str) and type(w) is int and 1<=w<=1000000 and target not in pool,"Invalid transport backend or weight")
        if target not in ("invalid","unavailable"):
            m=ORIGIN.fullmatch(target)
            require(m and m[1]==("udp" if kind=="udp" else "tcp") and int(m[3])<=65535,"Expected transport origin with explicit port")
            h=m[2]
            try:ip=ipaddress.ip_address(h)
            except ValueError:
                require(host_valid(h),"Invalid backend DNS name")
                # Machine providers use address scope; do not allow a DNS
                # name to resolve to arbitrary management sockets.
                if policy is not None:raise PermissionError("Transport provider backends require scoped IPv4 addresses")
            else:
                require(ip.version==4 and not ip.is_multicast and not ip.is_unspecified and not ip.is_link_local,"Invalid transport backend address")
                if policy is not None and (ip.is_loopback or not any(ip in ipaddress.ip_network(n) for n in policy.get("backend_cidrs",[]))):raise PermissionError("Transport backend outside scope")
        pool[target]=w
    return dict(protocol=kind,port=p,hostname=host,backends=[dict(target=t,weight=pool[t]) for t in sorted(pool)])
def route_key(route):
    return route["protocol"],route["port"],route["hostname"]
def file(data,owner):
    require(owner==NATIVE or re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}",owner),"Invalid transport owner")
    return data/"sites"/(".streams-"+owner+".json")
def inventory(data,skip_owner=None):
    result={}
    for path in sorted((data/"sites").glob(".streams-*.json")):
        owner=path.name[len(".streams-"):-5]
        require(path==file(data,owner) and not path.is_symlink(),"Invalid transport inventory")
        if owner==skip_owner:continue
        rows=json.loads(path.read_text())
        require(isinstance(rows,list) and len(rows)<=100,"Invalid stored transport inventory")
        result[owner]=[normalize_one(r) for r in rows]
    return result
def check_ownership(data,owner,rows):
    keys={(r["protocol"],r["port"]) for r in rows}
    for other,rs in inventory(data,skip_owner=owner).items():
        if other!=owner and keys.intersection((r["protocol"],r["port"]) for r in rs):
            raise PermissionError("Transport port owned by another provider or native administrator")
def normalize(rows,policy=None):
    require(isinstance(rows,list) and len(rows)<=100,"Invalid transport route count")
    result=[]
    for row in rows:result.append(normalize_one(row,policy))
    require(len({route_key(r) for r in result})==len(result),"Duplicate transport route")
    return sorted(result,key=route_key)
def render(data):
    rows=[r for rs in inventory(data).values() for r in rs]
    if not rows:return ""
    require(len({route_key(r) for r in rows})==len(rows),"Duplicate transport route ownership")
    bind_address=os.getenv("LITEEDGE_BIND_ADDRESS","0.0.0.0")
    require(ipaddress.ip_address(bind_address).version==4,"Invalid stream bind address")
    run=os.getenv("LITEEDGE_RUN_DIR","/tmp/liteedge-run")
    require(re.fullmatch(r"/[a-zA-Z0-9_./-]+",run),"Invalid stream runtime path")
    resolver=os.getenv("LITEEDGE_RESOLVER","")
    if not re.fullmatch(r"[A-Fa-f0-9:.]+",resolver):
        resolver=next((line.split()[1] for line in Path("/etc/resolv.conf").read_text().splitlines() if line.startswith("nameserver ")), "1.1.1.1")
    out=["stream {","    log_format liteedge_stream escape=json '{\"type\":\"stream\",\"timestamp\":\"$time_iso8601\",\"protocol\":\"$protocol\",\"ip\":\"$remote_addr\",\"port\":\"$server_port\",\"sni\":\"$ssl_preread_server_name\",\"upstream_addr\":\"$upstream_addr\",\"status\":$status,\"bytes_sent\":$bytes_sent,\"bytes_received\":$bytes_received,\"duration\":\"$session_time\"}';",f"    access_log {data}/logs/streams.jsonl liteedge_stream;",f"    resolver {resolver} ipv6=off valid=30s;"]
    groups={}
    for r in rows:
        k=route_key(r)
        name="le_stream_"+hashlib.sha256(json.dumps(k).encode()).hexdigest()[:20]
        out += [f"    upstream {name} {{",f"        zone {name} 64k;"]
        for b in r["backends"]:
            target=b["target"]
            if target in ("invalid","unavailable"):authority=f"unix:{run}/stream-reject.sock"
            else:authority=target.split("://",1)[1]
            # resolve DNS asynchronously; provider backends are IPv4 only.
            extra=""
            if target not in ("invalid","unavailable"):
                try:ipaddress.ip_address(authority.rsplit(":",1)[0])
                except ValueError:extra=" resolve"
            out.append(f"        server {authority} weight={b['weight']} max_fails=0{extra};")
        out.append("    }")
        groups.setdefault(k[:2],[]).append((r,name))
    for (kind,p),routes in sorted(groups.items()):
        dest=routes[0][1]
        if kind=="tls":
            var=f"le_sni_{p}"
            # A bare or unknown SNI fails closed. Wildcards are suffix
            # matches, with longest suffix first and literal names first.
            default=next((name for r,name in routes if r["hostname"]=="*"),f"unix:{run}/stream-reject.sock")
            out.append(f"    map $ssl_preread_server_name ${var} {{")
            out.append(f"        default {default};")
            out.append(f'        "" unix:{run}/stream-reject.sock;')
            for r,name in sorted(routes,key=lambda x:(x[0]["hostname"].startswith("*"),-len(x[0]["hostname"]),x[0]["hostname"])):
                h=r["hostname"]
                if h=="*":continue
                if h.startswith("*."):
                    h=r"~*^.+\."+re.escape(h[2:])+r"$"
                    out.append(f'        "{h}" {name};')
                else:out.append(f"        {h} {name};")
            out.append("    }");dest="$"+var
        elif len(routes)!=1:raise ValueError("Multiple transport routes on one TCP/UDP port")
        out += ["    server {",f"        listen {bind_address}:{mappings()[kind,p]}"+(" udp reuseport;" if kind=="udp" else ";"),"        proxy_connect_timeout 5s;","        proxy_timeout "+("30s;" if kind=="udp" else "10m;"),"        proxy_next_upstream off;"]
        if kind=="tls":out+=["        ssl_preread on;","        preread_timeout 10s;","        preread_buffer_size 32k;"]
        if kind=="tcp" or kind=="tls":out+=["        proxy_half_close on;"]
        out += [f"        proxy_pass {dest};","    }"]
    out.append("}")
    return "\n".join(out)+"\n"
if __name__=="__main__":
    try:
        data=Path(os.getenv("DATA_DIR","/data"))
        if sys.argv[1]=="render":print(render(data),end="")
        elif sys.argv[1]=="list":print(json.dumps({"ok":True,"listeners":[{"protocol":k,"port":p,"bind":b} for (k,p),b in sorted(mappings().items())],"routes":[dict(r,owner=o) for o,rows in inventory(data).items() for r in rows]}))
        else:raise ValueError("Unknown transport command")
    except (ValueError,PermissionError,OSError,TypeError,KeyError) as e:print(str(e),file=sys.stderr);sys.exit(1)
