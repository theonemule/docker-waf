#!/usr/bin/env python3
"""Administrator-only provider inventory and credentials; never expose hashes."""
import json
import os
from pathlib import Path
import re
import sys
import providerctl as p

SCOPES = ("host_suffixes", "backend_dns_suffixes", "backend_cidrs",
          "redirect_host_suffixes", "rewrite_host_suffixes")
FLAGS = ("allow_wildcards", "allow_catch_all", "allow_catch_all_tls", "allow_request_mirroring","allow_backend_retries","allow_backend_tls","allow_request_deadlines","allow_grpc","allow_stream","allow_client_validated_frontend")
FIELDS = set(SCOPES + FLAGS + ("min_waf_pl", "waf_profiles", "default_waf_profile","extra_http_ports","extra_https_ports","stream_ports"))

def validate(policy):
    p.strict(policy, FIELDS)
    for key in SCOPES:
        values = policy.get(key, [])
        p.require(isinstance(values, list) and len(values) <= 100, "Invalid or excessive provider scopes")
    for key in FLAGS:
        p.require(type(policy.get(key, False)) is bool, "Invalid authorization flag")
    p.require(policy.get("host_suffixes") or policy.get("allow_catch_all") or policy.get("allow_stream") and policy.get("stream_ports"), "A hostname scope is required")
    p.require(not policy.get("allow_catch_all_tls") or policy.get("allow_catch_all"), "TLS catch-all requires catch-all authorization")
    p.normalize({"revision": 0, "sites": []}, policy)
    profiles = policy.get("waf_profiles", {})
    p.require(isinstance(profiles, dict) and len(profiles) <= 32, "Invalid approved WAF profiles")
    floor = policy.get("min_waf_pl", 1)
    for name, profile in profiles.items():
        p.require(isinstance(name, str) and p.PROVIDER.fullmatch(name), "Invalid WAF profile name")
        p.strict(profile, ("min_waf_pl", "plugins", "disabled_rules"))
        level = profile.get("min_waf_pl", floor)
        plugins = profile.get("plugins", [])
        rules = profile.get("disabled_rules", [])
        p.require(type(level) is int and floor <= level <= 4, "Invalid WAF profile level")
        p.require(isinstance(plugins, list) and len(plugins) <= 20 and all(isinstance(v,str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}",v) for v in plugins), "Invalid WAF plugins")
        p.require(isinstance(rules, list) and len(rules) <= 100 and all(type(v) is int and 1 <= v <= 999999999 for v in rules), "Invalid WAF exclusions")
    default = policy.get("default_waf_profile", "")
    p.require(isinstance(default,str) and (not default or default in profiles), "Default WAF profile must be approved")
    return policy

def inventory(data, provider):
    current = p.state(data, provider)
    hosts = set(current["hosts"])
    for path in (data / "sites").glob("*.site"):
        site = p.kv(path)
        if site.get("PROVIDER") == provider:
            hosts.add(site.get("HOST", path.stem))
    for row in current.get("streams",[])+p.streams.inventory(data).get(provider,[]):
        hosts.add(row["protocol"]+":"+str(row["port"])+("/"+row["hostname"] if row["hostname"] else ""))
    return current["revision"], sorted(hosts)

def list_providers(data):
    result = []
    for path in sorted((data / "providers").glob("*.json")):
        if not p.PROVIDER.fullmatch(path.stem) or path.is_symlink():
            continue
        try:
            raw = p.read_json(path)
            policy = validate({k:v for k,v in raw.items() if k in FIELDS})
            revision, hosts = inventory(data, path.stem)
            result.append({"id":path.stem,"policy":policy,"revision":revision,"hosts":hosts,
                           "credential_configured":bool(re.fullmatch(r"[0-9a-f]{64}",str(raw.get("token_sha256",""))))})
        except (ValueError, TypeError, KeyError, AttributeError, OSError, p.Error):
            result.append({"id":path.stem,"invalid":True,"hosts":[]})
    return result

def mutate(data, operation, provider, stream):
    p.require(os.environ.get("LITEEDGE_CONFIG_LOCK_HELD") == "1", "Configuration lock required")
    p.require(p.PROVIDER.fullmatch(provider), "Invalid provider ID")
    path = data / "providers" / (provider + ".json")
    p.require(not path.is_symlink(), "Invalid provider file")
    existing = p.read_json(path)
    revision, hosts = inventory(data, provider)
    if operation == "delete":
        p.require(existing is not None, "Unknown provider")
        p.require(not hosts, "Drain all owned sites before deleting the provider")
        path.unlink()
        p.sync_directory(path.parent)
        # Preserve revision tombstone so recreation cannot reuse an old CAS.
        return
    token = stream.readline(258).rstrip("\n")
    if operation == "rotate":
        p.require(isinstance(existing,dict), "Unknown provider")
        p.require(p.TOKEN.fullmatch(token), "Use a 43–256 character base64url token")
        policy = dict(existing)
    elif operation == "save":
        p.require(not hosts, "Drain all owned sites before changing authorization")
        raw = stream.read(65537)
        p.require(len(raw) <= 65536, "Policy too large")
        policy = validate(json.loads(raw, object_pairs_hook=p.unique_object))
        if existing is not None:
            p.require(not token, "Use the separate credential rotation action")
            policy["token_sha256"] = existing["token_sha256"]
        else:
            p.require(p.TOKEN.fullmatch(token), "Use a 43–256 character base64url token")
    else:
        raise p.Error(400,"Unknown operation")
    if token:
        policy["token_sha256"] = p.sha(token.encode())
    p.atomic(path,p.canonical(policy))

def main():
    data = Path(os.environ.get("DATA_DIR", "/data"))
    args = sys.argv[1:]
    try:
        if args == ["list"]:
            print(json.dumps({"ok":True,"providers":list_providers(data)}))
        elif len(args)==2:
            mutate(data,*args,sys.stdin)
            print('{"ok":true}')
        else:
            raise p.Error(400,"Invalid provider administration action")
    except p.Error as exc:
        print(str(exc),file=sys.stderr)
        return 1
    except (ValueError, TypeError, KeyError, AttributeError, OSError):
        print("Invalid provider policy or configuration state",file=sys.stderr)
        return 1
    return 0

if __name__=="__main__":
    sys.exit(main())
