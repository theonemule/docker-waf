#!/usr/bin/env python3
"""Common typed route contract for admin and scoped provider API."""
import base64
import json
import re
import sys
import ssl
import ipaddress
from pathlib import Path
import listener_ports as ports

NAME=re.compile(r"[A-Za-z][A-Za-z0-9-]{0,63}")
VALUE=re.compile(r"[A-Za-z0-9_.,:/@+=% -]{1,256}")
QUERY=re.compile(r"[A-Za-z0-9_.~-]{1,256}")
PATH=re.compile(r"/[A-Za-z0-9._~/+-]*")
METHODS=("", "GET","HEAD","POST","PUT","DELETE","CONNECT","OPTIONS","TRACE","PATCH")
FIELDS=("header_matches","query_matches","method","request_headers","response_headers","redirect","rewrite","schemes","precedence","host_priority","mirrors","retry","backend_tls","deadlines","backend_tls_peers","grpc")
def require(ok,msg):
    if not ok: raise ValueError(msg)
def strict(obj,keys,required=()):
    require(isinstance(obj,dict) and set(obj)<=set(keys) and set(required)<=set(obj),"Unexpected or missing route feature fields")
def literal_path(p):
    return isinstance(p,str) and len(p)<=512 and PATH.fullmatch(p) and "//" not in p and not any(x in (".","..") for x in p.split("/")) and not p.startswith(("/.well-known/acme-challenge","/.liteedge-internal/mirror/"))
def hostname(h):
    return isinstance(h,str) and len(h)<=253 and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?",p) for p in h.split("."))
def predicates(items,query=False):
    require(isinstance(items,list) and len(items)<=16,"Too many or invalid match predicates")
    seen={}
    for h in items:
        strict(h,("name","value"),("name","value"))
        n,v=h["name"],h["value"]
        require(isinstance(n,str) and isinstance(v,str) and (QUERY if query else NAME).fullmatch(n) and (QUERY if query else VALUE).fullmatch(v),"Unsupported match literal")
        seen.setdefault(n if query else n.lower(),v)
    return [{"name":n,"value":v} for n,v in sorted(seen.items())]
def header_ops(items,response=False):
    require(isinstance(items,list) and len(items)<=20,"Invalid header operations")
    seen=set();out=[]
    for op in items:
        strict(op,("op","name","value"),("op","name"))
        name=op["name"];v=op.get("value","");kind=op["op"]
        require(isinstance(name,str) and re.fullmatch(r"(?i)x-[a-z0-9-]{1,64}",name),"Only literal X-headers supported")
        name=name.lower()
        require(name!="x-real-ip" and not name.startswith(("x-liteedge-","x-forwarded-","x-original-","x-auth-","x-remote-")),"Protected request header")
        if response:
            require(name not in ("x-content-type-options","x-frame-options","x-powered-by","x-xss-protection","x-webkit-csp","x-content-security-policy"),"Protected response header")
        require(name not in seen,"Duplicate header operation")
        require(isinstance(v,str) and (kind=="remove" and v=="" or kind in ("set","add") and VALUE.fullmatch(v)),"Invalid header operation/value")
        seen.add(name);out.append({"op":kind,"name":name,"value":v})
    return sorted(out,key=lambda x:x["name"])
def path_modifier(obj,match):
    if obj is None:return None
    strict(obj,("type","value"),("type","value"))
    require(obj["type"] in ("full","prefix") and literal_path(obj["value"]),"Invalid path modifier")
    require(obj["type"]!="prefix" or match=="prefix","Prefix replacement requires a prefix route")
    return {"type":obj["type"],"value":obj["value"]}
def backend_tls(raw):
    if raw is None:return None
    strict(raw,("hostname","ca_certificate"),("hostname","ca_certificate"))
    host,ca=raw["hostname"],raw["ca_certificate"]
    require(hostname(host),"Backend TLS requires a literal DNS identity")
    try:ipaddress.ip_address(host)
    except ValueError:pass
    else:raise ValueError("Backend TLS requires a DNS identity, not IP")
    require(isinstance(ca,str) and 0<len(ca)<=32768,"Invalid backend CA bundle size")
    ca=ca.replace("\r\n","\n").strip()+"\n"
    blocks=re.findall(r"-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\n]+?-----END CERTIFICATE-----",ca)
    require(1<=len(blocks)<=8 and not re.sub(r"-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\n]+?-----END CERTIFICATE-----","",ca).strip(),"Backend trust must contain only PEM certificates")
    try:
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_verify_locations(cadata=ca)
        require(len(context.get_ca_certs())==len(blocks),"Backend trust requires distinct CA certificates")
    except (ssl.SSLError,ValueError) as e:raise ValueError("Invalid backend CA bundle") from e
    return {"hostname":host,"ca_certificate":ca}

def validate_tls_targets(tls,targets,health=False):
    if tls is None:return
    require(targets and all(isinstance(v,str) and re.fullmatch(r"https://[a-z0-9.-]+:[1-9][0-9]{0,4}",v) and hostname(v.split("://")[1].rsplit(":",1)[0]) and int(v.rsplit(":",1)[1])<=65535 for v in targets),"Verified backend TLS requires HTTPS origins with explicit ports")

def validate_tls_peers(peers,targets):
    if not peers:return
    require(set(peers)=={t for t in targets if t.startswith("https://")},"Every HTTPS peer requires its own configured trust; no unused trust entries")
    for target in peers:validate_tls_targets(peers[target],[target])
    require(all(t.startswith(("http://","https://")) or t in ("invalid","unavailable") for t in targets),"Invalid mixed-security pool")

def normalize(raw,match,path,provider=False):
    strict(raw,FIELDS)
    headers=predicates(raw.get("header_matches",[]))
    queries=predicates(raw.get("query_matches",[]),True)
    method=raw.get("method","")
    require(method in METHODS,"Invalid method match")
    schemes=raw.get("schemes",["http","https"])
    require(isinstance(schemes,list) and 1<=len(schemes)<=18 and all(ports.valid_key(s) for s in schemes) and len(set(schemes))==len(schemes),"Invalid route schemes")
    require(all(s in ("http","https") or s in ports.mappings() for s in schemes),"Listener port not provisioned on appliance")
    precedence=raw.get("precedence",0);priority=raw.get("host_priority",0)
    require(type(precedence) is int and 0<=precedence<=1000000,"Invalid precedence")
    require(type(priority) is int and 0<=priority<=1253 and (provider or priority==0),"Invalid host priority")
    ops=header_ops(raw.get("request_headers",[]))
    response_ops=header_ops(raw.get("response_headers",[]),True)
    raw_mirrors=raw.get("mirrors",[])
    require(isinstance(raw_mirrors,list) and len(raw_mirrors)<=4,"At most four mirror destinations")
    mirrors=[]
    seen=set()
    for item in raw_mirrors:
        if isinstance(item,str):item={"target":item}
        strict(item,("target","basis_points"),("target",))
        target=item["target"]
        points=item.get("basis_points",10000)
        require(isinstance(target,str) and len(target)<=512,"Invalid mirror destination")
        m=re.fullmatch(r"http://([a-z0-9.-]+):([1-9][0-9]{0,4})",target)
        require(m and hostname(m[1]) and int(m[2])<=65535,"Mirror destination must be an HTTP origin with explicit port")
        require(type(points) is int and 0<=points<=10000,"Mirror percentage must be 0–100 in hundredths")
        require(target not in seen,"Duplicate mirror destination")
        seen.add(target)
        if points:mirrors.append({"target":target,"basis_points":points})
    mirrors.sort(key=lambda m:m["target"])
    tls=backend_tls(raw.get("backend_tls"))
    raw_peers=raw.get("backend_tls_peers",{})
    require(isinstance(raw_peers,dict) and len(raw_peers)<=16 and not (tls and raw_peers),"Invalid or conflicting per-peer TLS settings")
    peers={}
    for target,trust in raw_peers.items():
        require(isinstance(target,str) and trust is not None,"Invalid per-peer TLS settings")
        peers[target]=backend_tls(trust)
        validate_tls_targets(peers[target],[target])
    require(len(json.dumps(peers,separators=(",",":")).encode())<=40000,"Per-peer TLS trust exceeds combined 40 KB limit")
    deadlines=raw.get("deadlines")
    if deadlines is not None:
        strict(deadlines,("request_ms","backend_ms"))
        require(bool(deadlines) and all(type(v) is int and 0<=v<=3600000 for v in deadlines.values()),"Deadline must be 0–3600000 milliseconds")
        request=deadlines.get("request_ms",0)
        require(not request or deadlines.get("backend_ms",0)<=request,"Backend deadline exceeds request deadline")
    retry=raw.get("retry")
    if retry is not None:
        strict(retry,("attempts","codes","budget_ms","backoff_ms"),("attempts",))
        attempts=retry["attempts"]
        codes=retry.get("codes",[])
        budget=retry.get("budget_ms",0)
        backoff=retry.get("backoff_ms",0)
        require(type(attempts) is int and 0<=attempts<=4,"Retry attempts must be 0–4")
        require(isinstance(codes,list) and all(type(c) is int and c in (500,502,503,504,429) for c in codes) and len(set(codes))==len(codes),"Invalid retry status codes")
        require(type(budget) is int and 0<=budget<=60000,"Retry budget must be 0–60000 milliseconds")
        require(type(backoff) is int and 0<=backoff<=60000,"Retry backoff must be 0–60000 milliseconds")
        require(attempts>0 or not(codes or budget or backoff),"Disabled retries cannot specify codes or budget")
        retry={"attempts":attempts,"codes":sorted(codes),"budget_ms":budget}
        if backoff:retry["backoff_ms"]=backoff
    grpc=raw.get("grpc",False)
    require(type(grpc) is bool,"Invalid gRPC mode")
    redirect=raw.get("redirect")
    rewrite=raw.get("rewrite")
    if redirect is not None:
        strict(redirect,("hostname","scheme","port","status_code","path"))
        dest=redirect.get("hostname","");scheme=redirect.get("scheme","");port=redirect.get("port",0);code=redirect.get("status_code",302)
        require(dest=="" or hostname(dest),"Invalid redirect hostname")
        require(scheme in ("","http","https") and type(port) is int and 0<=port<=65535 and type(code) is int and code in (301,302,303,307,308),"Invalid redirect")
        redirect={"hostname":dest,"scheme":scheme,"port":port,"status_code":code,"path":path_modifier(redirect.get("path"),match)}
    if rewrite is not None:
        strict(rewrite,("hostname","path"))
        dest=rewrite.get("hostname","")
        require(dest=="" or hostname(dest),"Invalid rewrite hostname")
        modifier=path_modifier(rewrite.get("path"),match)
        require(dest or modifier,"Rewrite must change host or path")
        rewrite={"hostname":dest,"path":modifier}
    require(not grpc or (method=="POST" and not (redirect or rewrite or mirrors or peers or deadlines is not None or retry is not None or queries)),"gRPC requires POST and cannot use HTTP-only transformations, mirrors, deadlines, retries or per-peer TLS")
    require(not mirrors or not (redirect or rewrite),"Mirroring cannot be combined with redirect or rewrite")
    require(not (tls or peers) or not (redirect or mirrors),"Backend TLS cannot be combined with redirects or mirroring")
    require(not redirect or retry is None,"Redirect cannot have retries")
    require(not (deadlines is not None or retry and retry.get("backoff_ms")) or not (redirect or mirrors),"Deadlines/backoff cannot be combined with redirects or mirrors")
    require(not redirect or not (ops or rewrite),"Redirect cannot have backend transformations")
    require(not (headers or queries or method or redirect or rewrite or priority or mirrors) or match in ("exact","prefix") and literal_path(path),"Advanced matching requires a safe literal exact or prefix path")
    return dict(grpc=grpc,deadlines=deadlines,backend_tls_peers=peers,backend_tls=tls,retry=retry,mirrors=mirrors,header_matches=headers,query_matches=queries,method=method,schemes=sorted(schemes),precedence=precedence,host_priority=priority,request_headers=ops,response_headers=response_ops,redirect=redirect,rewrite=rewrite)
def blob(value):
    return base64.b64encode(json.dumps(value,sort_keys=True,separators=(",",":")).encode()).decode() if value else ""
def unblob(value,default):
    return json.loads(base64.b64decode(value,validate=True)) if value else default
def record(f):
    return {"GW_GRPC":int(f["grpc"]),"GW_BACKEND_TLS_PEERS_B64":blob(f["backend_tls_peers"]),"GW_DEADLINES_B64":blob(f["deadlines"]),"GW_BACKEND_TLS_B64":blob(f["backend_tls"]),"GW_RETRY_B64":blob(f["retry"]),"GW_MIRRORS_B64":blob(f["mirrors"]),"GW_MATCH_B64":blob(f["header_matches"]),"GW_QUERY_B64":blob(f["query_matches"]),"GW_METHOD":f["method"],"GW_HEADERS_B64":blob(f["request_headers"]),"GW_RESPONSE_HEADERS_B64":blob(f["response_headers"]),"GW_REDIRECT_B64":blob(f["redirect"]),"GW_REWRITE_B64":blob(f["rewrite"]),"SCHEMES":",".join(f["schemes"]),"GW_PRECEDENCE":f["precedence"],"GW_HOST_PRIORITY":f["host_priority"]}
def from_record(r,provider=False):
    return normalize(dict(grpc=r.get("GW_GRPC")=="1",backend_tls_peers=unblob(r.get("GW_BACKEND_TLS_PEERS_B64"),{}),deadlines=unblob(r.get("GW_DEADLINES_B64"),None),backend_tls=unblob(r.get("GW_BACKEND_TLS_B64"),None),retry=unblob(r.get("GW_RETRY_B64"),None),mirrors=unblob(r.get("GW_MIRRORS_B64"),[]),header_matches=unblob(r.get("GW_MATCH_B64"),[]),query_matches=unblob(r.get("GW_QUERY_B64"),[]),method=r.get("GW_METHOD",""),request_headers=unblob(r.get("GW_HEADERS_B64"),[]),response_headers=unblob(r.get("GW_RESPONSE_HEADERS_B64"),[]),redirect=unblob(r.get("GW_REDIRECT_B64"),None),rewrite=unblob(r.get("GW_REWRITE_B64"),None),schemes=(r.get("SCHEMES") or "http,https").split(","),precedence=int(r.get("GW_PRECEDENCE") or 0),host_priority=int(r.get("GW_HOST_PRIORITY") or 0)),r.get("MATCH","prefix"),r.get("PATH","/"),provider)
def kv(p):
    return dict(line.split("=",1) for line in Path(p).read_text().splitlines() if "=" in line)
def dispatch(f):
    return bool(f["mirrors"] or f["header_matches"] or f["query_matches"] or f["method"] or f["host_priority"] or (f["rewrite"] and f["rewrite"]["path"]) or (f["redirect"] and f["redirect"]["path"]))
def uses_deadline_engine(f):
    return bool(f["backend_tls_peers"]) or f["deadlines"] is not None or bool(f["retry"] and f["retry"].get("backoff_ms"))

def deadline_config(r,f):
    require(uses_deadline_engine(f),"No deadline engine policy")
    require(r.get("LB_MODE","round_robin") in ("","round_robin"),"Deadline routes require round-robin pool mode")
    require(r.get("REWRITE_ENABLED","0")!="1" and r.get("FORCE_HTTPS","0")!="1","Deadline routes cannot use legacy rewrite or forced HTTPS")
    targets=[r.get("TARGET","")]+([x for x in r.get("BACKENDS","").split(",") if x])
    weights=(r.get("BACKEND_WEIGHTS") or ",".join("1" for _ in targets)).split(",")
    require(len(targets)==len(weights) and 1<=len(targets)<=16 and len(set(targets))==len(targets),"Invalid deadline pool")
    validate_tls_peers(f["backend_tls_peers"],targets)
    for target in targets:
        if target in ("invalid","unavailable"):
            require(r.get("PROVIDER_ROUTE")=="1" and not f["backend_tls"] and not (f["retry"] and f["retry"]["attempts"]),"Invalid local deadline backend")
            continue
        require(re.fullmatch(r"https?://[a-zA-Z0-9.-]+:[1-9][0-9]{0,4}",target) and int(target.rsplit(":",1)[1])<=65535,"Deadline routes require explicit origin-only backend URLs")
        require(target.startswith("https://" if f["backend_tls"] or target in f["backend_tls_peers"] else "http://"),"Deadline HTTPS backends require explicit verified TLS")
    require(all(re.fullmatch(r"[1-9][0-9]{0,6}",w) and int(w)<=1000000 for w in weights),"Invalid deadline weights")
    result=blob(dict(backends=[{"target":t,"weight":int(w)} for t,w in zip(targets,weights)],deadlines=f["deadlines"],retry=f["retry"],backend_tls=f["backend_tls"],backend_tls_peers=f["backend_tls_peers"]))
    require(len(result)<=65536,"Deadline configuration exceeds internal size limit")
    return result

def main():
    cmd=sys.argv[1]
    if cmd=="normalize":
        f=normalize(json.loads(sys.stdin.read()),sys.argv[2],sys.argv[3])
        print(json.dumps(f,separators=(",",":")))
    elif cmd=="validate-tls-targets":
        f=json.loads(sys.stdin.read())
        targets=[sys.argv[2]]+sys.argv[3].split(",") if sys.argv[3] else [sys.argv[2]]
        validate_tls_targets(f.get("backend_tls"),targets,sys.argv[4]=="1")
        validate_tls_peers(f.get("backend_tls_peers",{}),targets)
    elif cmd=="record":
        f=json.loads(sys.stdin.read())
        for k,v in record(f).items():print(f"{k}={v}")
    elif cmd=="deadline-config":
        r=kv(sys.argv[2]);f=from_record(r,r.get("PROVIDER_ROUTE")=="1")
        print(deadline_config(r,f) if uses_deadline_engine(f) else "")
    elif cmd=="read":
        r=kv(sys.argv[2]);print(json.dumps(from_record(r,r.get("PROVIDER_ROUTE")=="1"),separators=(",",":")))
    elif cmd=="manual-id":
        print(manual_id(sys.argv[2],sys.argv[3],sys.argv[4],json.loads(sys.stdin.read())))
    elif cmd=="id":
        import hashlib
        r=kv(sys.argv[2])
        print(manual_id(r["MATCH"],r["PATH"],r.get("TARGET",""),from_record(r)))
    else:raise ValueError("Unknown route feature command")
def manual_id(match,path,target,features):
    import hashlib
    key=json.dumps([match,path,target,features["header_matches"],features["query_matches"],features["method"],features["schemes"]],sort_keys=True,separators=(",",":"))
    return hashlib.sha256(key.encode()).hexdigest()[:16]
if __name__=="__main__":
    try:main()
    except (ValueError,TypeError,KeyError,OSError) as e:
        print(str(e),file=sys.stderr);sys.exit(1)
