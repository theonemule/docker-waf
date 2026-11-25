#!/usr/bin/env python3
"""Fresh, scoped management reads. No persisted or cross-request state."""
import json
import os
import re
import sys
from pathlib import Path

ROUTE_KEYS = "ID MATCH PATH TARGET BACKENDS BACKEND_WEIGHTS SCHEMES WAF_PROFILE PROVIDER_ROUTE PROVIDER_QUARANTINED TYPED_ROUTE ACTION WEBSOCKET TIMEOUT WAF FORCE_HTTPS WAF_PL WAF_PLUGINS WAF_DISABLED LB_MODE MAX_FAILS FAIL_TIMEOUT HEALTH_ENABLED HEALTH_PATH HEALTH_EXPECT HEALTH_INTERVAL HEALTH_TIMEOUT HEALTH_FALL HEALTH_RISE HEALTH_COOLDOWN METHODS REWRITE_ENABLED REWRITE_PATTERN REWRITE_REPLACEMENT ALLOW_IPS RATE_COUNT RATE_UNIT MAX_BODY".split()
SUMMARY_KEYS = "ID MATCH PATH TARGET BACKENDS WAF WAF_PL LB_MODE WAF_PROFILE PROVIDER_QUARANTINED".split()

def kv(file):
    values = {}
    for line in file.read_text().split("\n"):
        key, sep, value = line.partition("=")
        if sep:
            values.setdefault(key, value)
    return values

def optional(file, default=""):
    try:
        return file.read_text().rstrip("\n")
    except FileNotFoundError:
        return default

def slug(host):
    return re.sub(r"[^a-z0-9.-]", "_", host.lower())

class InvalidRequest(ValueError):
    pass

def site_record(root, host):
    if host != "*" and not re.fullmatch(r"(?:\*\.)?(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", host):
        raise InvalidRequest("Invalid hostname.")
    record = kv(root / "sites" / (slug(host) + ".site"))
    if record.get("HOST", "").lower() != host.lower() or ("*" in host and not record.get("PROVIDER")):
        raise FileNotFoundError("Site not found.")
    return record

def route_files(root, host):
    return sorted((root / "sites" / (slug(host) + ".routes")).glob("*.route"))

def basic(root, record):
    host = record["HOST"]
    cert = root / "certs" / slug(host)
    return dict(host=host, aliases=record.get("ALIASES", ""), enabled=record.get("ENABLED") != "0",
                tls=optional(cert / "mode", "none"), provider=record.get("PROVIDER", ""),
                route_count=len(route_files(root, host)))

def inventory(root):
    return {"ok": True, "sites": sorted((basic(root, kv(p)) for p in (root / "sites").glob("*.site")), key=lambda s: s["host"])}

def route_summary(record):
    out = {k.lower(): record.get(k, "") for k in SUMMARY_KEYS}
    out["weights"] = [int(w) for w in record.get("BACKEND_WEIGHTS", "").split(",") if w]
    out["features"] = {"grpc": record.get("GW_GRPC") == "1",
                       "redirect": bool(record.get("GW_REDIRECT_B64")),
                       "rewrite": bool(record.get("GW_REWRITE_B64")),
                       "schemes": (record.get("SCHEMES") or "http,https").split(",")}
    return out

def overview(root, record):
    out = basic(root, record)
    host, provider = out["host"], out["provider"]
    cert = root / "certs" / slug(host)
    routes = [route_summary(kv(p)) for p in route_files(root, host)]
    listeners = record.get("GW_LISTENERS")
    listeners = listeners.split(",") if listeners else sorted({"http", "https"} | {s for r in routes for s in r["features"]["schemes"] if ":" in s})
    rejected = record.get("GW_TLS_REJECT_LISTENERS", "").split(",")
    tls_status = {}
    for listener in listeners:
        if listener != "https" and not listener.startswith("https:"):
            continue
        d = cert / "listeners" / listener.replace(":", "-") if provider and ":" in listener else cert
        tls_status[listener] = ("rejected" if listener in rejected or (listener == "https" and record.get("GW_TLS_REJECT") == "1") else
                                "configured" if all((d / name).is_file() and (d / name).stat().st_size for name in ("fullchain.pem", "privkey.pem")) else "missing")
    disabled = optional(root / "sites" / (slug(host) + ".waf-disabled")).splitlines()
    out.update(routes=routes, route_count=len(routes), listeners=listeners, tls_listeners=tls_status,
               tls_reject=record.get("GW_TLS_REJECT") == "1", wildcard_single=record.get("GW_WILDCARD_SINGLE") == "1",
               cert_email=optional(cert / "acme-email").split("\n")[0] or os.getenv("ACME_EMAIL", ""),
               disabled_rules=sorted({x for x in disabled if re.fullmatch(r"[0-9]{1,9}", x)}, key=int))
    return {"ok": True, "site": out}

def route_detail(root, record, ident):
    if not re.fullmatch(r"[a-f0-9]{16}", ident):
        raise InvalidRequest("Invalid route ID.")
    r = kv(root / "sites" / (slug(record["HOST"]) + ".routes") / (ident + ".route"))
    if r.get("ID") != ident:
        raise FileNotFoundError("Route not found.")
    import base64
    import route_features
    result = {k.lower(): r.get(k, "") for k in ROUTE_KEYS}
    result["weights"] = [int(w) for w in r.get("BACKEND_WEIGHTS", "").split(",") if w]
    result["features"] = route_features.from_record(r, r.get("PROVIDER_ROUTE") == "1")
    result["x_headers"] = base64.b64decode(r.get("X_HEADERS_B64", "")).decode("utf-8", errors="replace").rstrip("\n")
    return {"ok": True, "route": result, "provider": record.get("PROVIDER", "")}

def configuration(root, record):
    if record.get("PROVIDER"):
        raise PermissionError("Site is managed by a Kubernetes provider.")
    name = slug(record["HOST"])
    nginx = root / "nginx"
    return {"ok": True, **{key: optional(Path(os.getenv(env, str(nginx / folder))) / (name + ext))
        for key, env, folder, ext in (("configuration","NGINX_SITE_DIR","sites",".conf"),
                                     ("conflict","NGINX_CONFLICT_DIR","conflicts",".conflict"),("delta","NGINX_DIFF_DIR","diffs",".diff"))}}

def plugins(root):
    path = Path(os.getenv("WAF_PLUGIN_DIR", str(root / "waf" / "plugins")))
    installed = []
    for d in sorted(path.glob("*")):
        if d.is_dir():
            try: meta = kv(d / ".liteedge-plugin")
            except FileNotFoundError: meta = {}
            installed.append({"name": d.name, "kind": meta.get("TYPE",""), "category": meta.get("CATEGORY") or "plugin"})
    return {"ok": True, "installed": installed}

def main():
    root = Path(os.getenv("DATA_DIR", "/data"))
    command, *args = sys.argv[1:]
    try:
        if command == "inventory": result = inventory(root)
        elif command == "plugins": result = plugins(root)
        else:
            record = site_record(root, args[0])
            if command == "overview": result = overview(root, record)
            elif command == "route": result = route_detail(root, record, args[1])
            elif command == "configuration": result = configuration(root, record)
            else: raise ValueError("Unknown read.")
        code = 200
    except PermissionError:
        code, result = 403, {"ok":False,"error":"Site is managed by a Kubernetes provider."}
    except FileNotFoundError:
        code, result = 404, {"ok":False,"error":"Site or route not found."}
    except InvalidRequest as e:
        code, result = 400, {"ok":False,"error":str(e)}
    except (ValueError, OSError, KeyError, TypeError, IndexError):
        code, result = 500, {"ok":False,"error":"Unable to read configuration."}
    print(f"Status: {code}\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n",end="")
    print(json.dumps(result, separators=(",",":")))

if __name__ == "__main__":
    main()
