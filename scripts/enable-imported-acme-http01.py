#!/usr/bin/env python3
"""Make HTTP-01 validation reachable in imported NGINX HTTP redirect vhosts.

Preserves existing host-specific redirects and any explicitly imported ACME
location. This is a guarded, repeatable data upgrade for imported templates.
"""
import argparse
import re
from pathlib import Path

SERVER = re.compile(r'(?m)^[ \t]*server[ \t]*\{')
IF_REDIRECT = re.compile(
    r'(?ms)^[ \t]*if[ \t]*\((\$host[ \t]*==?[ \t]*[^)]*)\)[ \t]*\{[ \t]*'
    r'(return[ \t]+301[ \t]+[^;]+;)[ \t]*\}[ \t]*(?:\#.*)?\n?'
)
SERVER_RETURN = re.compile(r'(?m)^[ \t]*(return[ \t]+(?:301|404)[ \t]*[^;]*;)[ \t]*(?:\#.*)?$')

def close_brace(data, opening):
    depth = 0
    quoted = None
    for i in range(opening, len(data)):
        c = data[i]
        if quoted:
            if c == quoted:
                quoted = None
        elif c in ('"', "'"):
            quoted = c
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    raise ValueError('Unbalanced imported NGINX server block')

def patch_host(data, host, *, write):
    p = data / 'imported' / 'sites' / host / 'template.conf'
    if not p.exists():
        return False
    text = p.read_text()
    output = text
    for server in reversed(list(SERVER.finditer(text))):
        stop = close_brace(text, server.end() - 1)
        block = text[server.start():stop]
        if not re.search(r'(?m)^\s*listen\s+(?:[^;: ]+:)?(?:80|8080)\s*;', block):
            continue
        if 'ssl' in block.split('server_name')[0]:
            continue
        imported_route = data / 'sites' / (host + '.routes')
        existing_http_acme = False
        if imported_route.is_dir():
            for route in imported_route.glob('*.route'):
                fields = dict(line.split('=',1) for line in route.read_text().splitlines() if '=' in line)
                if fields.get('PATH') == '/.well-known/acme-challenge/' and fields.get('IMPORT_SCHEME') == 'http':
                    existing_http_acme = True
                    break
        if 'LITEEDGE_ACME_HTTP01_MANAGED' in block:
            block = re.sub(r'(?ms)^[ \t]*if[ \t]*\(\$host[ \t]*=[^)]*\)[ \t]*\{[ \t]*\}[ \t]*(?:\#.*)?\n?', '', block)
            if existing_http_acme or 'location ^~ /.well-known/acme-challenge/' in block:
                output = output[:server.start()] + block + output[stop:]
                continue
            challenge = '''
    location ^~ /.well-known/acme-challenge/ {
        root /data/acme/challenges;
        auth_basic off;
        default_type text/plain;
        try_files $uri =404;
    }
'''
            marker = '    # LITEEDGE_ACME_HTTP01_MANAGED'
            block = block.replace(marker, marker + challenge, 1)
            output = output[:server.start()] + block + output[stop:]
            continue
        redirects = IF_REDIRECT.findall(block)
        block = IF_REDIRECT.sub('', block)
        returns = SERVER_RETURN.findall(block)
        block = SERVER_RETURN.sub('', block)
        if not returns and not redirects:
            # No unconditional server-scope redirect to bypass.
            continue

        acme = '' if existing_http_acme else '''
    location ^~ /.well-known/acme-challenge/ {
        root /data/acme/challenges;
        auth_basic off;
        default_type text/plain;
        try_files $uri =404;
    }
'''
        # Return the same redirect/404 status for other paths, preserving the
        # previous Certbot host-specific condition wherever it was present.
        actions = []
        for condition, directive in redirects:
            actions.append(f'        if ({condition}) {{ {directive} }}')
        for directive in returns:
            actions.append(f'        {directive}')
        if not actions:
            raise ValueError(f'No fallback response in {host}')
        fallback = '\n    location / {\n' + '\n'.join(actions) + '\n    }\n'
        replacement = '\n    # LITEEDGE_ACME_HTTP01_MANAGED\n' + acme + fallback
        idx = block.rfind('}')
        block = block[:idx] + replacement + block[idx:]
        if 'LITEEDGE_ACME_HTTP01_MANAGED' not in block:
            raise ValueError('Failed to mark imported NGINX ACME patch')
        output = output[:server.start()] + block + output[stop:]
    if output == text:
        return False
    if write:
        p.write_text(output)
        p.chmod(0o600)
    return True

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', required=True)
    ap.add_argument('--apply', action='store_true')
    args = ap.parse_args()
    data = Path(args.data)
    targets = sorted(x.parent.name for x in (data/'imported/sites').glob('*/template.conf'))
    changed = [h for h in targets if patch_host(data, h, write=args.apply)]
    print(f'HTTP-01 templates to update: {len(changed)} / {len(targets)}')
    for host in changed:
        print(f'  {host}')
if __name__ == '__main__':
    main()
