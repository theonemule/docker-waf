#!/usr/bin/env python3
"""Import pre-existing NGINX vhosts into LiteEdge's managed route inventory.

The original directives are retained as per-site templates and per-route snippets.
Re-import is idempotent and does not mutate the running configuration.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path

LOCATION = re.compile(r'(?m)^[ \t]*location[ \t]+(?:(=|\^~|~\*?|@)[ \t]+)?([^\s{]+)[ \t]*\{')
SERVER = re.compile(r'(?m)^[ \t]*server[ \t]*\{')
UPSTREAM = re.compile(r'(?m)^[ \t]*proxy_pass[ \t]+([^;\s]+)[ \t]*;')


def brace_end(data: str, brace: int) -> int:
    """Return byte-index after matching closing brace (comments/quotes ignored)."""
    depth, quoted, escaped, comment = 0, None, False, False
    for pos in range(brace, len(data)):
        c = data[pos]
        if comment:
            if c == '\n':
                comment = False
            continue
        if escaped:
            escaped = False
            continue
        if quoted:
            if c == '\\':
                escaped = True
            elif c == quoted:
                quoted = None
            continue
        if c == '#':
            comment = True
        elif c in ('"', "'"):
            quoted = c
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return pos + 1
    raise ValueError('Unbalanced NGINX configuration braces')


def safe_fields(text: str) -> str:
    if '\n' in text or '\r' in text:
        raise ValueError('Invalid route field')
    return text


def collect(src: Path, data_root: Path, dry_run: bool) -> dict:
    name = src.stem
    site = data_root / 'sites' / (name + '.site')
    if not site.exists():
        raise ValueError(f'Site {name} is not registered')
    text = src.read_text()
    imported = data_root / 'imported' / 'sites' / name
    replacements = []
    entries = []
    for server_match in SERVER.finditer(text):
        start = server_match.end() - 1
        end = brace_end(text, start)
        # The port determines whether a location belongs to HTTP or HTTPS.
        server_body = text[start+1:end-1]
        listen = re.search(r'(?m)^[ \t]*listen[ \t]+[^;]+;', server_body)
        scheme = 'https' if listen and 'ssl' in listen.group(0) else 'http'
        location_spans = []
        for match in LOCATION.finditer(text, start+1, end-1):
            span_end = brace_end(text, match.end()-1)
            if not (start < match.start() < span_end < end):
                continue
            # Only top-level location blocks; there are no nested location blocks
            # in the six supported imported vhosts.
            location_spans.append((match.start(),span_end,match))
        for st, ed, match in location_spans:
            item = text[st:ed]
            mode = match.group(1) or ''
            match_type = 'exact' if mode=='=' else 'regex' if mode.startswith('~') else 'prefix'
            path = safe_fields(match.group(2))
            upstream = UPSTREAM.search(item)
            action = 'proxy' if upstream else 'custom'
            target = safe_fields(upstream.group(1) if upstream else '')
            key = hashlib.sha256(f'{name}:{st}:{ed}'.encode()).hexdigest()[:16]
            id_value=hashlib.sha256((match_type+'\n'+path+'\n'+target).encode()).hexdigest()[:16]
            used = {x['id'] for x in entries}
            if id_value in used:
                id_value = key
            upgrade = 1 if re.search(r'(?m)^[ \t]*proxy_set_header[ \t]+Upgrade\b', item) else 0
            timeout = re.findall(r'(?m)^[ \t]*proxy_read_timeout[ \t]+(\d+)s[ \t]*;', item)
            timeout = int(timeout[-1]) if timeout else 60
            if not 1 <= timeout <= 86400:
                raise ValueError('Invalid timeout')
            entries.append(dict(id=id_value,key=key,scheme=scheme,match=match_type,path=path,
                                action=action,target=target,websocket=upgrade,timeout=timeout,
                                snippet=item,host=name))
            replacements.append((st,ed,'    # LITEEDGE_IMPORTED_LOCATION:'+key))
        replacements.append((end-1,end-1, '\n    # LITEEDGE_EXTRA_ROUTES:'+scheme+'\n'))
    if not entries:
        raise ValueError(f'No NGINX locations discovered for {name}')
    template = text
    for st, ed, repl in sorted(replacements, key=lambda x:(x[0],x[1]),reverse=True):
        template = template[:st]+repl+template[ed:]
    if not dry_run:
        (imported / 'locations').mkdir(parents=True, exist_ok=True)
        imported.chmod(0o700)
        (imported / 'locations').chmod(0o700)
        route_dir = data_root/'sites'/(name+'.routes')
        route_dir.mkdir(exist_ok=True)
        route_dir.chmod(0o700)
        template_path = imported/'template.conf'
        if template_path.exists() and template_path.read_text() != template:
            raise ValueError(f'Import template already changed for {name}; refusing overwrite')
        template_path.write_text(template)
        template_path.chmod(0o600)
        for ent in entries:
            snippet_path = imported/'locations'/(ent['key']+'.conf')
            if snippet_path.exists() and snippet_path.read_text() != ent['snippet']:
                raise ValueError('Imported location snippet changed; refusing overwrite')
            snippet_path.write_text(ent['snippet'])
            snippet_path.chmod(0o600)
            fields = [('ID',ent['id']),('MATCH',ent['match']),('PATH',ent['path']),
                    ('ACTION',ent['action']),('TARGET',ent['target']),('WEBSOCKET',str(ent['websocket'])),
                    ('TIMEOUT',str(ent['timeout'])),('WAF','0'),('FORCE_HTTPS','0'),('WAF_PL','1'),
                    ('WAF_PLUGINS',''),('WAF_DISABLED',''),('IMPORT_KEY',ent['key']),
                    ('IMPORT_ORIGINAL_TARGET',ent['target']),('IMPORT_ORIGINAL_TIMEOUT',str(ent['timeout'])),('IMPORT_SCHEME',ent['scheme'])]
            routefile = data_root/'sites'/(name+'.routes')/(ent['id']+'.route')
            expected = ''.join(f'{k}={v}\n' for k,v in fields)
            if routefile.exists() and routefile.read_text() != expected:
                raise ValueError(f'Refusing to overwrite modified managed route {routefile}')
            routefile.write_text(''.join(f'{k}={v}\n' for k,v in fields))
            routefile.chmod(0o600)
    return {'site':name,'locations':len(entries),'reverse_proxies':sum(x['action']=='proxy' for x in entries),
            'custom_locations':sum(x['action']=='custom' for x in entries),
            'http':sum(x['scheme']=='http' for x in entries),'https':sum(x['scheme']=='https' for x in entries)}


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--data',required=True)
    ap.add_argument('--dry-run',action='store_true')
    args=ap.parse_args()
    data=Path(args.data)
    srcdir=data/'migration'/'sites'
    out=[collect(p,data,args.dry_run) for p in sorted(srcdir.glob('*.conf'))]
    print(json.dumps({'site_count':len(out),'route_count':sum(x['locations'] for x in out),'inventory':out},indent=2))

if __name__=='__main__':main()