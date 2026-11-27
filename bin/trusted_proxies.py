#!/usr/bin/env python3
"""Render an explicit, narrow NGINX client-IP trust boundary."""
import ipaddress
import os
import re
import sys

def render(raw):
    if len(raw) > 4096:
        raise ValueError("Trusted proxy list is too long")
    entries = re.split(r"[,\s]+", raw.strip()) if raw.strip() else []
    if len(entries) > 128:
        raise ValueError("Too many trusted proxy networks")
    networks = []
    for entry in entries:
        if "%" in entry:
            raise ValueError("Scoped addresses are not supported")
        network = ipaddress.ip_network(entry, strict=True)
        if network.prefixlen == 0:
            raise ValueError("Trusting every address is prohibited")
        if network not in networks:
            networks.append(network)
    if not networks:
        return "# No trusted proxies; ignore incoming client IP headers."
    return "\n".join([*(f"set_real_ip_from {network};" for network in networks),
                       "real_ip_header X-Forwarded-For;", "real_ip_recursive on;"])

if __name__ == "__main__":
    try:
        print(render(os.environ.get("LITEEDGE_TRUSTED_PROXY_CIDRS", "")))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
