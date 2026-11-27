#!/usr/bin/env python3
"""Scoped, declarative LightEdge provider transactions. No raw NGINX input."""
import argparse
import base64
import contextlib
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import stat
import ssl
import time
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
import route_features as features
import listener_ports as ports
import stream_routes as streams

MAX_BODY = 4 * 1024 * 1024
PROVIDER = re.compile(r"[a-z0-9][a-z0-9-]{0,62}\Z")
LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")
PATH = re.compile(r"/[A-Za-z0-9._~/+-]*\Z")
TOKEN = re.compile(r"[A-Za-z0-9_-]{43,256}\Z")
RUNTIME = Path("/opt/liteedge")

class Error(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.location = None
        self.field = None

def require(condition, message, status=400, field=None):
    if not condition:
        error=Error(status,message)
        error.field=field
        raise error

def hostname(value):
    require(isinstance(value, str) and len(value) <= 253
            and all(LABEL.fullmatch(part) for part in value.split(".")),
            "Expected lowercase DNS hostname (wildcards not supported)")
    return value

def scoped(name, suffixes):
    return any(name == suffix or name.endswith("." + suffix) for suffix in suffixes)

def host_pattern(value, policy):
    if value == "*":
        require(policy.get("allow_catch_all") is True,"Catch-all requires explicit provider authorization",403)
        return value
    if isinstance(value,str) and value.startswith("*."):
        suffix=hostname(value[2:])
        require(policy.get("allow_wildcards") is True and scoped(suffix,policy.get("host_suffixes",[])),
                "Wildcard outside provider scope or not authorized",403)
        return value
    value=hostname(value)
    require(scoped(value,policy.get("host_suffixes",[])),"Hostname outside provider scope",403)
    return value

def slug(host):
    return host.replace("*","_")

def overlap(a,b):
    if a==b or a=="*" or b=="*":
        return True
    aw,bw=a.startswith("*."),b.startswith("*.")
    if aw and bw:
        return a[2:].endswith("."+b[2:]) or b[2:].endswith("."+a[2:])
    if aw:
        return b.endswith(a[1:])
    if bw:
        return a.endswith(b[1:])
    return False

def strict(obj, allowed, required=()):
    require(isinstance(obj, dict) and set(obj) <= set(allowed)
            and set(required) <= set(obj), "Unexpected or missing fields")

def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default

def sync_directory(path):
    fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(fd)
    finally:os.close(fd)

def sync_tree(path):
    # Durability before journal publication and commit. Never follow symlinks
    # or open special files (e.g. runtime sockets).
    for root,dirs,files in os.walk(path,topdown=False,followlinks=False):
        for name in files:
            item=Path(root)/name
            if stat.S_ISREG(item.lstat().st_mode):
                with item.open("rb") as f:os.fsync(f.fileno())
        sync_directory(root)

def atomic(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()

def sha(data):
    return hashlib.sha256(data).hexdigest()

def kv(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)

def write_kv(path, fields):
    atomic(path, "".join(f"{key}={value}\n" for key, value in fields.items()).encode())

@contextlib.contextmanager
def locked(data):
    data.mkdir(parents=True, exist_ok=True)
    from ha_config import file_lock
    with file_lock(data / ".liteedge-config.lock"):
        yield

def auth(data, provider, header):
    require(PROVIDER.fullmatch(provider), "Unknown provider", 404)
    policy = read_json(data / "providers" / (provider + ".json"))
    token = header.removeprefix("Bearer ") if header.startswith("Bearer ") else ""
    require(isinstance(policy, dict) and TOKEN.fullmatch(token)
            and hmac.compare_digest(sha(token.encode()), str(policy.get("token_sha256", ""))),
            "Unauthorized", 401)
    return policy

def address_allowed(ip, policy):
    return (ip.version == 4 and not ip.is_loopback and not ip.is_link_local
            and not ip.is_multicast and not ip.is_unspecified
            and not ip.is_reserved
            and any(ip in ipaddress.ip_network(net) for net in policy.get("backend_cidrs", [])))

def resolve_backend(host):
    # Bound the system resolver independently of libc/NSS retry settings.
    # Use an argument, never shell expansion. No DNS lookup occurs in the
    # traffic plane after authorization.
    try:
        output = subprocess.check_output([sys.executable, "-c",
            "import socket,sys; print(' '.join(sorted({r[4][0] for r in socket.getaddrinfo(sys.argv[1],None,socket.AF_INET,socket.SOCK_STREAM)})))",
            host], timeout=2, stderr=subprocess.DEVNULL)
        return [ipaddress.ip_address(x) for x in output.decode("ascii").split()]
    except (subprocess.SubprocessError, OSError, ValueError):
        raise Error(403, "Backend DNS resolution failed") from None

def backend(value, policy, verified_tls=False, cache=None):
    require(isinstance(value, str) and len(value) <= 512, "Invalid backend")
    try:
        parsed = urlsplit(value)
        host, port = parsed.hostname, parsed.port
    except ValueError:
        raise Error(400, "Invalid backend URL") from None
    scheme="https" if verified_tls else "http"
    require(parsed.scheme == scheme and host and port and 1 <= port <= 65535
            and not parsed.username and not parsed.password and not parsed.query
            and not parsed.fragment and parsed.path in ("", "/")
            and value == f"{scheme}://{host}:{port}", "Expected authorized origin with explicit port (IPv4 or DNS)")
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        hostname(host)
        require(scoped(host, policy.get("backend_dns_suffixes", [])),
                "Backend DNS name outside provider scope", 403)
        if cache is None:
            cache = {}
        if host not in cache:
            require(len(cache) < 16, "Too many distinct backend DNS names", 403)
            answers = resolve_backend(host)
            require(0 < len(answers) <= 64 and all(address_allowed(a, policy) for a in answers),
                    "Backend DNS resolves outside provider scope", 403)
            # Pin a deterministic scoped answer. Explicit IP pools are
            # required for multi-endpoint balancing.
            cache[host] = min(answers)
        ip = cache[host]
    require(address_allowed(ip, policy), "Backend address outside provider scope", 403)
    return f"{scheme}://{ip}:{port}"

def certificate(host, tls, client_validated=False):
    strict(tls, ("certificate", "private_key"), ("certificate", "private_key"))
    cert, key = tls["certificate"], tls["private_key"]
    require(all(isinstance(s, str) and 0 < len(s) <= 128*1024 for s in (cert, key)),
            "Invalid TLS material")
    with tempfile.TemporaryDirectory() as tmp:
        c, k = Path(tmp)/"cert", Path(tmp)/"key"
        atomic(c, cert.encode())
        atomic(k, key.encode())
        def run(*args):
            result = subprocess.run(["openssl", *args], capture_output=True, timeout=10)
            require(result.returncode == 0, "Invalid TLS certificate or key")
            return result.stdout
        # Parse SANs structurally with CPython's OpenSSL certificate decoder;
        # match the Go controller's exact and single-label wildcard rules.
        # Never trust comma-delimited display output or fall back to CN.
        try:
            decoded=ssl._ssl._test_decode_cert(str(c))
        except (ValueError,OSError,ssl.SSLError):
            raise Error(400,"Invalid TLS certificate or key") from None
        names={v.lower() for kind,v in decoded.get("subjectAltName",()) if kind=="DNS"}
        if not client_validated and host.startswith("*."):
            require(host in names,"Certificate requires exact wildcard SAN")
        elif not client_validated and host!="*":
            suffix=host.split(".",1)[1] if "." in host else ""
            require(host in names or (suffix and "*."+suffix in names),"Certificate does not cover hostname")
        run("x509", "-in", str(c), "-noout", "-checkend", "0")
        require(ssl.cert_time_to_seconds(decoded["notBefore"])<=time.time(),"TLS certificate not currently valid")
        public = run("x509", "-in", str(c), "-pubkey", "-noout")
        key_public = run("pkey", "-in", str(k), "-pubout", "-passin", "pass:")
        require(public == key_public, "TLS certificate and key do not match")
    return tls

def normalize(payload, policy):
    strict(payload, ("revision", "sites","streams"), ("revision", "sites"))
    require(type(payload["revision"]) is int and payload["revision"] >= 0, "Invalid revision")
    require(isinstance(payload["sites"], list) and len(payload["sites"]) <= 100, "Invalid site count")
    try:streams.allowed_policy(policy)
    except ValueError as e:raise Error(500,str(e)) from None
    result = {}
    total = 0
    dns_cache = {}
    for field in ("host_suffixes","backend_dns_suffixes","redirect_host_suffixes","rewrite_host_suffixes"):
        if field in policy:
            value=policy[field]
            require(isinstance(value,list) and all(isinstance(x,str) and len(x)<=253 and all(LABEL.fullmatch(part) for part in x.split(".")) for x in value),"Invalid provider hostname policy",500)
    try:
        cidrs=policy.get("backend_cidrs",[])
        require(isinstance(cidrs,list) and all(isinstance(x,str) and ipaddress.ip_network(x).version==4 for x in cidrs),"Invalid provider backend policy",500)
    except ValueError:
        raise Error(500,"Invalid provider backend policy") from None
    allowed_ports={}
    for protocol in ("http","https"):
        values=policy.get("extra_"+protocol+"_ports",[])
        require(isinstance(values,list) and len(values)<=16 and all(type(p) is int and ports.valid_key(protocol+":"+str(p)) for p in values) and len(set(values))==len(values),"Invalid provider listener port policy",500)
        allowed_ports.update({protocol+":"+str(p):p for p in values})
    require(len(allowed_ports)<=16 and len(set(allowed_ports.values()))==len(allowed_ports),"Conflicting provider listener port policy",500)
    require(type(policy.get("allow_client_validated_frontend",False)) is bool,"Invalid frontend certificate policy",500)
    min_pl = policy.get("min_waf_pl", 1)
    require(type(min_pl) is int and 1 <= min_pl <= 4, "Invalid provider policy", 500)
    for site_index,site in enumerate(payload["sites"]):
        try:
            strict(site, ("host", "routes", "tls", "listeners", "tls_reject", "wildcard_single", "tls_listeners"), ("host", "routes"))
            host = host_pattern(site["host"],policy)
            require(host not in result, "Duplicate host")
            wildcard_single=site.get("wildcard_single",False)
            require(type(wildcard_single) is bool and (not wildcard_single or host.startswith("*.")),"Single-label wildcard requires a wildcard hostname")

            listeners=site.get("listeners")
            if listeners is not None:
                require(isinstance(listeners,list) and 1<=len(listeners)<=18 and all(ports.valid_key(x) for x in listeners) and len(set(listeners))==len(listeners),"Invalid site listeners")
            if listeners:
                for key in listeners:
                    if ":" in key:
                        require(key in allowed_ports,"Extra listener not authorized",403)
                        require(key in ports.mappings(),"Extra listener not provisioned",400)
            require(isinstance(site["routes"], list) and len(site["routes"]) <= 100 and (site["routes"] or listeners), "Invalid route count")
            routes = {}
            for route_index,route in enumerate(site["routes"]):
                try:
                    strict(route, ("match", "path", "target", "backends", "waf_pl", "rate_count", "max_body", "schemes", "allow_ips", "health", "waf_profile", "request_headers", "response_headers", "header_matches", "method", "precedence", "host_priority", "redirect", "query_matches", "rewrite", "quarantined", "mirrors", "retry", "backend_tls", "deadlines", "backend_tls_peers", "grpc"),
                           ("match", "path"))
                    match, path = route["match"], route["path"]
                    require(match in ("exact", "prefix") and isinstance(path, str) and len(path) <= 512
                            and PATH.fullmatch(path) and "//" not in path and
                            not path.startswith(("/.well-known/acme-challenge","/.liteedge-internal/mirror/")) and
                            all(p not in (".", "..") for p in path.split("/")),
                            "Unsupported or unsafe path")
                    # Prefix is explicitly segment-aware: the native renderer receives
                    # exact /foo plus prefix /foo/ unless an explicit exact route wins.
                    if match == "prefix":
                        path = path.rstrip("/") or "/"
                    raw_features={k:route[k] for k in features.FIELDS if k in route}
                    raw_features.setdefault("schemes",["http"] if host=="*" else ["http","https"])
                    try:
                        f=features.normalize(raw_features,match,path,provider=True)
                    except ValueError as e:
                        raise Error(400,str(e)) from None
                    if f["grpc"]:require(policy.get("allow_grpc") is True,"gRPC not approved for this provider",403,"grpc")
                    if f["mirrors"]:
                        require(policy.get("allow_request_mirroring") is True,"Request mirroring not approved for this provider",403,"mirrors")
                        for mirror in f["mirrors"]:mirror["target"]=backend(mirror["target"],policy,cache=dns_cache)
                        require(len({m["target"] for m in f["mirrors"]})==len(f["mirrors"]),"Duplicate resolved mirror destination")
                    tls=f["backend_tls"]
                    peers=f["backend_tls_peers"]
                    resolved_peers={}
                    if tls or peers:
                        require(policy.get("allow_backend_tls") is True,"Verified backend TLS not approved for this provider",403,"backend_tls")
                    redirect=f["redirect"]
                    if redirect is not None:
                        require("target" not in route and "backends" not in route,"Redirect cannot have backends")
                        dest=redirect["hostname"]
                        require(not dest or scoped(dest,policy.get("redirect_host_suffixes",policy.get("host_suffixes",[]))),"Redirect hostname outside provider scope",403)
                        backends=[]
                    else:
                        require(("target" in route) != ("backends" in route), "Supply target or weighted backends")
                    rewrite=f["rewrite"]
                    if rewrite and rewrite["hostname"]:
                        require(scoped(rewrite["hostname"],policy.get("rewrite_host_suffixes",policy.get("host_suffixes",[]))),"Rewrite hostname outside provider scope",403)
                    if redirect is not None:
                        pass
                    elif "backends" in route:
                        entries = route["backends"]
                        require(isinstance(entries,list) and 1 <= len(entries) <= 16, "Invalid backend pool")
                        pool = {}
                        for entry in entries:
                            strict(entry,("target","weight"),("target","weight"))
                            original = entry["target"]
                            require(isinstance(original,str),"Invalid backend target")
                            target = original if original in ("invalid","unavailable") else backend(original,policy,bool(tls or original in peers),dns_cache)
                            if original in peers:resolved_peers[target]=peers[original]
                            weight = entry["weight"]
                            require(type(weight) is int and 1 <= weight <= 1000000, "Invalid backend weight")
                            require(target not in pool, "Duplicate backend target")
                            pool[target] = weight
                        backends = [{"target":k,"weight":v} for k,v in sorted(pool.items())]
                    else:
                        original=route["target"]
                        require(isinstance(original,str),"Invalid backend target")
                        target=backend(original,policy,bool(tls or original in peers),dns_cache)
                        if original in peers:resolved_peers[target]=peers[original]
                        backends = [{"target":target,"weight":1}]
                    require(len(resolved_peers)==len(peers),"Unused or duplicate backend trust")
                    peers=f["backend_tls_peers"]=resolved_peers
                    if tls:
                        try:features.validate_tls_targets(tls,[b["target"] for b in backends])
                        except ValueError as e:require(False,str(e),400,"backend_tls")
                    if peers:
                        try:features.validate_tls_peers(peers,[b["target"] for b in backends])
                        except ValueError as e:require(False,str(e),400,"backend_tls")
                    if f["deadlines"] is not None or f["retry"] and f["retry"].get("backoff_ms"):
                        require(policy.get("allow_request_deadlines") is True,"Request deadlines not approved for this provider",403,"deadlines")
                        require(not f["retry"] or not f["retry"]["attempts"] or all(b["target"] not in ("invalid","unavailable") for b in backends),"Retries require valid backends")
                    retry=f["retry"]
                    if retry is not None and retry["attempts"]:
                        require(policy.get("allow_backend_retries") is True,"Backend retries not approved for this provider",403,"retry")
                        require((features.uses_deadline_engine(f) or len(backends)>=2) and all(b["target"] not in ("invalid","unavailable") for b in backends),"Retries require multiple valid distinct HTTP backends")
                    quarantined=route.get("quarantined",False)
                    require(type(quarantined) is bool,"Invalid quarantine flag")
                    require(not quarantined or (backends==[{"target":"invalid","weight":1}] and not (f["grpc"] or f["redirect"] or f["rewrite"] or f["request_headers"] or f["response_headers"] or f["mirrors"] or f["retry"] is not None or f["deadlines"] is not None or tls or peers) and not route.get("waf_profile") and not route.get("waf_pl")),"Quarantine must use the local error backend and baseline policy")
                    schemes=f["schemes"]
                    require(all(":" not in key or key in allowed_ports for key in schemes),"Extra listener not authorized",403,"schemes")
                    require(listeners is None or set(schemes)<=set(listeners),"Route scheme outside site listeners")
                    require(host!="*" or not any(ports.is_https(k) for k in schemes) or policy.get("allow_catch_all_tls") is True,"Catch-all HTTPS requires explicit provider authorization",403)
                    headers=f["header_matches"];queries=f["query_matches"];method=f["method"]
                    for scheme in schemes:
                        require((match,path,scheme,canonical(headers),canonical(queries),method) not in routes,"Conflicting route match",409)
                    profile = route.get("waf_profile", "") or policy.get("default_waf_profile", "")
                    require(isinstance(profile, str) and (not profile or PROVIDER.fullmatch(profile)), "Invalid WAF profile")
                    profiles = policy.get("waf_profiles", {})
                    require(isinstance(profiles,dict), "Invalid provider profile configuration", 500)
                    require(not profile or profile in profiles, "WAF profile is not approved for this provider", 403,"waf_profile")
                    # Profiles are resolved by the appliance, never supplied as raw rules by Kubernetes.
                    approved = profiles[profile] if profile else {}
                    require(isinstance(approved,dict) and set(approved)<={"min_waf_pl","plugins","disabled_rules"},"Invalid approved profile configuration",500)
                    floor=approved.get("min_waf_pl",min_pl)
                    require(type(floor) is int and min_pl <= floor <= 4,"Invalid approved profile WAF floor",500)
                    plugins=approved.get("plugins",[])
                    rules=approved.get("disabled_rules",[])
                    require(isinstance(plugins,list) and len(plugins)<=20 and all(isinstance(x,str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}",x) for x in plugins),"Invalid approved profile plugins",500)
                    require(isinstance(rules,list) and len(rules)<=100 and all(type(x) is int and 1<=x<=999999999 for x in rules),"Invalid approved profile exclusions",500)
                    pl = route.get("waf_pl", floor)
                    rate = route.get("rate_count", 0)
                    body = route.get("max_body", "")
                    require(type(pl) is int and floor <= pl <= 4, "WAF policy below required baseline", 403,"waf_pl")
                    require(type(rate) is int and 0 <= rate <= 999999, "Invalid rate")
                    require(isinstance(body, str) and (body == "" or re.fullmatch(r"[1-9][0-9]{0,6}[km]?", body)),
                            "Invalid body size")
                    ips = route.get("allow_ips",[])
                    require(isinstance(ips,list) and len(ips)<=128, "Invalid IP allowlist")
                    try:
                        ips = sorted({str(ipaddress.ip_network(x,strict=False)) for x in ips if isinstance(x,str)})
                    except ValueError:
                        raise Error(400,"Invalid allowlist CIDR") from None
                    require(all(isinstance(x,str) for x in route.get("allow_ips",[])), "Invalid allowlist CIDR")
                    health = route.get("health")
                    if health is not None:
                        strict(health,("enabled","path","interval","timeout","expected"),("enabled",))
                        require(type(health["enabled"]) is bool,"Invalid health check")
                        hp=health.get("path","/health")
                        interval=health.get("interval",30)
                        timeout=health.get("timeout",5)
                        expected=health.get("expected","200")
                        require(isinstance(hp,str) and PATH.fullmatch(hp) and len(hp)<=512,"Invalid health path")
                        require(type(interval) is int and 5<=interval<=3600 and type(timeout) is int
                                and 1<=timeout<=min(interval,60),"Invalid health check timing")
                        require(isinstance(expected,str) and re.fullmatch(r"[1-5](?:[0-9]{2}|xx)",expected),
                                "Invalid expected health status")
                        health={"enabled":health["enabled"],"path":hp,"interval":interval,"timeout":timeout,"expected":expected}
                    require(not redirect or not health or not health["enabled"],"Redirect cannot have backend health checks")
                    normalized = dict(match=match,path=path,**f,quarantined=quarantined,backends=backends,waf_pl=pl,waf_profile=profile,waf_plugins=sorted(set(plugins)),waf_disabled=sorted(set(rules)),rate_count=rate,max_body=body,allow_ips=ips,health=health)
                    for scheme in schemes:
                        routes[match,path,scheme,canonical(headers),canonical(queries),method]=normalized
                    total += 1
                except Error as e:
                    if e.status in (400,403,409):
                        e.location={"site_index":site_index,"route_index":route_index}
                        if e.field:e.location["field"]=e.field
                    raise
            tls = certificate(host, site["tls"],policy.get("allow_client_validated_frontend") is True) if "tls" in site else None
            extra_tls=site.get("tls_listeners",{})
            require(isinstance(extra_tls,dict) and len(extra_tls)<=16 and all(ports.valid_key(k) and k.startswith("https:") and k in allowed_ports and k in ports.mappings() for k in extra_tls),"Invalid extra TLS listener map")
            extra_tls={k:certificate(host,v,policy.get("allow_client_validated_frontend") is True) if v is not None else None for k,v in extra_tls.items()}
            if listeners is None:
                listeners=["http","https"] if tls else ["http"]
                listeners+=sorted({key for route in routes.values() for key in route["schemes"] if ":" in key}|set(extra_tls))
            tls_reject=site.get("tls_reject",False)
            require(type(tls_reject) is bool,"Invalid TLS rejection flag")
            require(not tls_reject or ("https" in listeners and tls is None and all("https" not in r["schemes"] for r in routes.values())),"TLS rejection cannot have a certificate or HTTPS routes")
            require("https" not in listeners or tls is not None or tls_reject,"HTTPS listener requires TLS certificate")
            require(set(extra_tls)=={k for k in listeners if k.startswith("https:")},"Each additional HTTPS listener requires an explicit certificate or rejection")
            require(host!="*" or not any(ports.is_https(k) for k in listeners) or policy.get("allow_catch_all_tls") is True,"Catch-all HTTPS requires explicit provider authorization",403)
            unique={}
            for route in routes.values():
                if route["schemes"] == ["https"]:
                    require(tls is not None, "HTTPS route requires TLS certificate")
                for key in route["schemes"]:
                    if key.startswith("https:"):
                        require(extra_tls.get(key) is not None,"Additional HTTPS route requires its listener certificate")
                unique[canonical(route)]=route
            result[host] = dict(host=host, routes=[unique[k] for k in sorted(unique)], tls=tls,tls_reject=tls_reject,tls_listeners=extra_tls,wildcard_single=wildcard_single,listeners=sorted(listeners))
        except Error as e:
            if e.status in (400,403,409) and e.location is None:
                e.location={"site_index":site_index}
            raise
        require(total <= 1000, "Too many routes")
    for host,site in result.items():
        if not site["wildcard_single"]:continue
        for other,other_site in result.items():
            require(not (other!=host and other.startswith("*.") and not other_site["wildcard_single"] and overlap(host,other)),"Single-label wildcard overlaps a Gateway wildcard",409)
    return [result[k] for k in sorted(result)]

def owner_inventory(data, provider, sites, submitted=None):
    old = set()
    desired = {s["host"] for s in sites}
    indexes={s["host"]:i for i,s in enumerate(submitted or [])}
    def reject_host(host,message):
        e=Error(409,message)
        if host in indexes:e.location={"site_index":indexes[host]}
        raise e
    for file in (data/"sites").glob("*.site"):
        record = kv(file)
        host = record.get("HOST", "").lower()
        aliases = set(record.get("ALIASES", "").lower().replace(",", " ").split())
        if record.get("PROVIDER") == provider:
            require(file.name == slug(host) + ".site" and not aliases, "Invalid owned inventory", 409)
            old.add(host)
        else:
            for requested in sorted(desired):
                if any(overlap(a,requested) for a in {host}|aliases):
                    reject_host(requested,"Hostname scope overlaps another site/provider")
    for host in desired-old:
        name=slug(host)
        if any(p.exists() for p in (data/"sites"/(name+".site"),data/"certs"/name,data/"sites"/(name+".routes"),data/"nginx"/"sites"/(name+".conf"),data/"imported"/"sites"/name)):
            reject_host(host,"Unowned configuration or certificate already exists")
    return old

def route_records(routes):
    # Conditional matching needs original logical paths so a failed exact
    # predicate can fall back to a segment prefix. No synthetic exact routes.
    if any(features.dispatch(r) for r in routes):
        return [(r["match"],r["path"],r) for r in routes]
    per_scheme = {}
    for route in routes:
        match,path=route["match"],route["path"]
        for scheme in route["schemes"]:
            if match=="prefix" and path!="/":
                per_scheme["prefix",path+"/",scheme]=route
                per_scheme.setdefault(("exact",path,scheme),route)
            else:
                per_scheme[match,path,scheme]=route
    for route in routes:
        if route["match"]=="exact":
            for scheme in route["schemes"]:
                per_scheme["exact",route["path"],scheme]=route
    # Consolidate identical records across listeners; differing listener routes
    # retain distinct IDs and never share WAF or rate-limit configuration.
    grouped={}
    for (match,path,scheme),route in sorted(per_scheme.items()):
        config={k:v for k,v in route.items() if k!="schemes"}
        key=(match,path,canonical(config))
        if key not in grouped:
            grouped[key]=dict(config,schemes=[])
        grouped[key]["schemes"].append(scheme)
    return [(match,path,route) for (match,path,_),route in sorted(grouped.items())]

def materialize(data, provider, sites, old):
    desired = {s["host"] for s in sites}
    for host in old-desired:
        (data/"sites"/(slug(host)+".site")).unlink()
        shutil.rmtree(data/"sites"/(slug(host)+".routes"), ignore_errors=True)
        shutil.rmtree(data/"certs"/slug(host), ignore_errors=True)
    for site in sites:
        host = site["host"]
        write_kv(data/"sites"/(slug(host)+".site"), {"HOST":host, "ALIASES":"", "ENABLED":"1", "PROVIDER":provider,"GW_LISTENERS":",".join(site["listeners"]), "GW_TLS_REJECT":int(site["tls_reject"]),"GW_TLS_REJECT_LISTENERS":",".join(sorted(k for k,v in site["tls_listeners"].items() if v is None)),"GW_WILDCARD_SINGLE":int(site["wildcard_single"]), "GW_DISPATCH":int(any(features.dispatch(r) for r in site["routes"]))})
        directory = data/"sites"/(slug(host)+".routes")
        shutil.rmtree(directory, ignore_errors=True)
        directory.mkdir()
        for match,path,route in route_records(site["routes"]):
            backends = route["backends"]
            target = backends[0]["target"] if backends else ""
            identity = sha(canonical([match,path,target,route["schemes"],route["header_matches"],route["query_matches"],route["method"]]))[:16]
            health=route["health"] or {"enabled":False,"path":"/health","interval":30,"timeout":5,"expected":"200"}
            write_kv(directory/(identity+".route"), {
                "ID":identity,"MATCH":match,"PATH":path,"TARGET":target,
                "BACKENDS":",".join(x["target"] for x in backends[1:]),
                "BACKEND_WEIGHTS":",".join(str(x["weight"]) for x in backends),
                "PROVIDER_ROUTE":"1","PROVIDER_QUARANTINED":int(route["quarantined"]),
                **features.record(route),
                "WAF":"1","WAF_PL":route["waf_pl"],"WAF_PROFILE":route["waf_profile"],
                "WAF_PLUGINS":",".join(route["waf_plugins"]),"WAF_DISABLED":",".join(map(str,route["waf_disabled"])),"WEBSOCKET":"1","TIMEOUT":"60",
                "FORCE_HTTPS":"0","METHODS":"ALL","RATE_COUNT":route["rate_count"],
                "RATE_UNIT":"s","MAX_BODY":route["max_body"],
                "ALLOW_IPS":",".join(route["allow_ips"]),
                "HEALTH_ENABLED":int(health["enabled"]),"HEALTH_PATH":health["path"],
                "HEALTH_INTERVAL":health["interval"],"HEALTH_TIMEOUT":health["timeout"],
                "HEALTH_EXPECT":health["expected"],"HEALTH_FALL":"3","HEALTH_RISE":"2","HEALTH_COOLDOWN":"300"})
        certdir = data/"certs"/slug(host)
        if certdir.exists():
            shutil.rmtree(certdir)
        def write_cert(directory,tls):
            atomic(directory/"fullchain.pem",tls["certificate"].encode(),0o644)
            atomic(directory/"privkey.pem",tls["private_key"].encode())
            atomic(directory/"mode",b"imported\n")
            atomic(directory/"domains",(host+"\n").encode())
        if site["tls"]:
            write_cert(certdir,site["tls"])
        for listener,tls in sorted(site["tls_listeners"].items()):
            if tls:
                write_cert(certdir/"listeners"/listener.replace(":","-"),tls)

def state_path(data, provider):
    return data/"sites"/(".provider-"+provider+".json")

def state(data, provider):
    return read_json(state_path(data,provider), {"revision":0,"digest":sha(b"[]"),"hosts":[]})

def owned_fingerprint(data,hosts):
    inventory=[]
    def visit(path):
        relative=str(path.relative_to(data))
        if path.is_symlink():
            inventory.append((relative,"symlink",os.readlink(path)))
        elif not path.exists():
            inventory.append((relative,"missing",""))
        elif path.is_dir():
            inventory.append((relative,"dir",""))
            for child in sorted(path.iterdir()):visit(child)
        elif path.is_file():
            inventory.append((relative,stat.S_IMODE(path.stat().st_mode),sha(path.read_bytes())))
        else:
            raise Error(503,"Unexpected managed configuration object")
    for host in sorted(hosts):
        name=slug(host)
        visit(data/"sites"/(name+".site"))
        visit(data/"sites"/(name+".routes"))
        visit(data/"certs"/name)
    return sha(canonical(inventory))

def generated_matches(data,hosts):
    for host in hosts:
        name=slug(host)+".conf"
        current=data/"nginx"/"sites"/name
        baseline=data/"nginx"/"baselines"/name
        if not current.is_file() or not baseline.is_file() or current.is_symlink() or baseline.is_symlink() or current.read_bytes()!=baseline.read_bytes():
            return False
        for route in (data/"sites"/(slug(host)+".routes")).glob("*.route"):
            raw=kv(route)
            if raw.get("GW_BACKEND_TLS_B64"):
                try:tls=features.from_record(raw,True)["backend_tls"]
                except (ValueError,TypeError,KeyError,OSError):return False
                if tls is None:return False
                content=(tls["ca_certificate"]+"\n").encode()
                ca=data/"nginx"/"waf-routes"/("backend-ca-"+sha(content)+".pem")
                if ca.is_symlink() or not ca.is_file() or ca.read_bytes()!=content:return False
    return True

def inherited_lock_fds():
    if os.environ.get("LITEEDGE_HA_DIR"):
        from ha_config import ACTIVE_LOCK_FDS
        return ACTIVE_LOCK_FDS
    return ()

def render(data):
    env = os.environ.copy()
    env["DATA_DIR"] = str(data)
    env["LITEEDGE_CONFIG_LOCK_HELD"] = "1"
    subprocess.run([str(RUNTIME/"bin/render-nginx.sh")],env=env,check=True,
                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=90,pass_fds=inherited_lock_fds())
    degraded = read_json(data/"nginx/degraded-sites.json", [])
    return {item["host"] for item in degraded}

def reload(data):
    from nginx_reload import reload as confirmed_reload
    confirmed_reload(RUNTIME/"sbin/nginx", data/"nginx/nginx.conf",pass_fds=inherited_lock_fds())

PARTS = ("sites","certs","nginx")
def journal(data):
    return data/".liteedge-provider-transaction"

def discard_journal(data):
    trash = Path(tempfile.mkdtemp(prefix=".liteedge-provider-completed-",dir=data))
    os.replace(journal(data),trash/"backup")
    sync_directory(trash)
    sync_directory(data)
    shutil.rmtree(trash)
    sync_directory(data)

def recover(data, reload_fn=None):
    backup = journal(data)
    if not backup.exists():
        return
    # Journal stays intact until all parts are restored, allowing retry after crash.
    for name in PARTS:
        path = data/name
        if path.exists():
            shutil.rmtree(path)
        if (backup/name).exists():
            shutil.copytree(backup/name,path,symlinks=True)
    for name in PARTS:
        if (data/name).exists():sync_tree(data/name)
    sync_directory(data)
    if reload_fn:
        reload_fn(data)
    discard_journal(data)

def normalize_streams(data,provider,payload,policy):
    raw=payload.get("streams",[])
    require(isinstance(raw,list) and len(raw)<=100,"Invalid transport route count")
    result=[]
    seen=set()
    for index,row in enumerate(raw):
        try:
            r=streams.normalize_one(row,policy)
            key=streams.route_key(r)
            if key in seen:raise ValueError("Duplicate transport route")
            seen.add(key)
            streams.check_ownership(data,provider,[r])
            result.append(r)
        except (ValueError,PermissionError,TypeError,KeyError) as exc:
            e=Error(403 if isinstance(exc,PermissionError) else 400,str(exc))
            e.location={"stream_index":index,"field":"streams"}
            raise e from None
    return sorted(result,key=streams.route_key)

def stream_fingerprint(data,provider):
    f=streams.file(data,provider)
    return sha(f.read_bytes()) if f.is_file() and not f.is_symlink() else sha(b"[]")

def stream_generated_matches(data):
    try:
        path=data/"nginx"/"streams.conf"
        return path.is_file() and not path.is_symlink() and path.read_text()==streams.render(data)
    except (ValueError,OSError,PermissionError):return False

def validate(data,provider,payload,policy):
    require(not journal(data).exists(), "Pending recovery; administrator intervention required", 503)
    current=state(data,provider)
    require(payload.get("revision") == current["revision"], "Revision conflict",409)
    sites=normalize(payload,policy)
    old=owner_inventory(data,provider,sites,payload["sites"])
    normalize_streams(data,provider,payload,policy)
    return current,sites,old

def apply(data, provider, payload, policy, render_fn=render, reload_fn=reload):
    # Caller holds shared configuration lock. Revalidate after preflight,
    # so policy changes and CAS races never authorize stale configuration.
    current,sites,old=validate(data,provider,payload,policy)
    transport=normalize_streams(data,provider,payload,policy)
    digest = sha(canonical({"sites":sites,"streams":transport})) if transport else sha(canonical(sites))
    if (digest==current["digest"] and old==set(current["hosts"])
            and current.get("owned_fingerprint",sha(b"[]") if not old else "")==owned_fingerprint(data,old)
            and current.get("stream_fingerprint",sha(b"[]"))==stream_fingerprint(data,provider)
            and (render_fn is not render or generated_matches(data,old) and stream_generated_matches(data))):
        return {**current,"changed":False}
    for name in PARTS:
        (data/name).mkdir(exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".liteedge-provider-stage-",dir=data))
    try:
        for name in PARTS:
            shutil.copytree(data/name,stage/name,symlinks=True)
        sync_tree(stage)
        os.replace(stage,journal(data))
        sync_directory(data)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    try:
        materialize(data,provider,sites,old)
        streamfile=streams.file(data,provider)
        if transport:atomic(streamfile,canonical(transport))
        else:streamfile.unlink(missing_ok=True)
        degraded = render_fn(data) or set()
        require(not degraded.intersection(s["host"] for s in sites),
                "LightEdge quarantined managed configuration", 422)
        result = {"revision":current["revision"]+1,"digest":digest,"hosts":[s["host"] for s in sites],"owned_fingerprint":owned_fingerprint(data,(s["host"] for s in sites)),"streams":transport,"stream_fingerprint":stream_fingerprint(data,provider)}
        atomic(state_path(data,provider),canonical(result))
        for name in PARTS:sync_tree(data/name)
        sync_directory(data)
        reload_fn(data)
    except Exception:
        try:
            recover(data,reload_fn)
        except Exception:
            raise Error(503,"Rollback requires administrator recovery") from None
        raise Error(422,"Configuration rejected; previous state restored") from None
    discard_journal(data)
    return {**result,"changed":True}

def unique_object(pairs):
    out = {}
    for key, value in pairs:
        require(key not in out, "Duplicate JSON field")
        out[key] = value
    return out

def cgi(data):
    try:
        path = os.environ.get("PATH_INFO","")
        m = re.fullmatch(r"/api/v1/providers/([a-z0-9][a-z0-9-]{0,62})/state",path)
        require(m is not None, "Unknown endpoint", 404)
        provider = m.group(1)
        require(os.environ.get("HTTPS") == "on", "HTTPS required", 403)
        method = os.environ.get("REQUEST_METHOD","GET")
        require(method in ("GET","PUT","POST"), "Method not allowed",405)
        header = os.environ.get("HTTP_AUTHORIZATION","")
        # Never enter HA synchronization or the writer lock for requests
        # without a structurally valid bearer credential.
        require(header.startswith("Bearer ") and TOKEN.fullmatch(header[7:]),
                "Unauthorized",401)
        from ha_config import enabled, session
        shared = enabled()
        if not shared:
            # Policy is atomically replaced; recheck under the lock below.
            auth(data,provider,header)
        payload = None
        if method != "GET":
            require(os.environ.get("CONTENT_TYPE","").split(";")[0] == "application/json",
                    "JSON required",415)
            length_text = os.environ.get("CONTENT_LENGTH","0")
            require(re.fullmatch(r"[0-9]{1,7}",length_text) is not None,"Invalid request size",413)
            length = int(length_text)
            require(0 < length <= MAX_BODY,"Invalid request size",413)
            raw = sys.stdin.buffer.read(length)
            require(len(raw) == length,"Incomplete body")
            payload = json.loads(raw, object_pairs_hook=unique_object,
                                 parse_constant=lambda _: require(False,"Invalid JSON number"))
            require(isinstance(payload,dict),"Expected JSON object")
        # HA authentication must use the synchronized policy, not a stale
        # replica's token after credential rotation.
        context = session(data) if shared else locked(data)
        with context as ha:
            policy = auth(data,provider,header)
            if method == "GET":
                response = state(data,provider)
            elif method in ("PUT","POST"):
                if method=="POST":
                    current,_,_=validate(data,provider,payload,policy)
                    response={**current,"changed":False}
                else:
                    if ha:
                        ha.begin_write()
                    try:
                        response = apply(data,provider,payload,policy)
                        if ha:
                            ha.publish()
                    except Exception:
                        if ha and not journal(data).exists():
                            if ha.local_matches():
                                ha.finish_write()
                            else:
                                ha.sync(force=True)
                        raise
            else:
                raise Error(405,"Method not allowed")
        response.pop("owned_fingerprint",None)
        response.pop("stream_fingerprint",None)
        status, response = 200, {"ok":True,**response}
    except Error as e:
        status,response = e.status, {"ok":False,"error":str(e)}
        if e.location is not None:
            # Stable diagnostic codes, never request values, keys or credentials.
            message = str(e)
            reasons = {
                "Certificate does not cover hostname":"CertificateHostnameMismatch",
                "Invalid TLS certificate or key":"InvalidTLSMaterial",
                "TLS certificate and key do not match":"TLSKeyMismatch",
                "Certificate requires exact wildcard SAN":"WildcardCertificateMismatch",
                "Hostname outside provider scope":"HostnameScopeDenied",
                "Backend address outside provider scope":"BackendScopeDenied",
                "Expected http://host:port (IPv4 or DNS)":"InvalidBackendURL",
                "WAF profile is not approved for this provider":"WAFProfileDenied",
                "WAF policy below required baseline":"WAFFloorDenied",
                "Catch-all requires explicit provider authorization":"CatchAllDenied",
                "Request mirroring not approved for this provider":"MirroringDenied",
                "Backend retries not approved for this provider":"BackendRetryDenied",
                "Request deadlines not approved for this provider":"RequestDeadlineDenied",
                "Verified backend TLS not approved for this provider":"BackendTLSDenied",
                "Extra listener not authorized":"ListenerPortDenied",
                "Extra listener not provisioned":"ListenerPortUnavailable",
                "Catch-all HTTPS requires explicit provider authorization":"CatchAllTLSDenied",
                "Catch-all TLS requires explicit provider authorization":"CatchAllTLSDenied",
                "HTTPS route requires TLS certificate":"MissingTLSCertificate",
                "HTTPS listener requires TLS certificate":"MissingTLSCertificate",
                "Route scheme not enabled on site":"ListenerSchemeMismatch",
                "Conflicting route match":"ConflictingRoute",
            }
            response["rejection"]={**e.location,"reason":reasons.get(message,"InvalidConfiguration")}
    except (ValueError,UnicodeError,RecursionError):
        status,response = 400, {"ok":False,"error":"Invalid request"}
    except Exception as e:
        from ha_config import HAError
        status,response = (503 if isinstance(e,HAError) else 500), {"ok":False,"error":"Shared configuration unavailable or rejected" if isinstance(e,HAError) else "Provider operation failed"}
    print(f"Status: {status}\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"+json.dumps(response),end="")

if __name__ == "__main__":
    data = Path(os.environ.get("DATA_DIR","/data"))
    if len(sys.argv)>1 and sys.argv[1]=="recover":
        with locked(data):
            recover(data)
    else:
        cgi(data)
