#!/usr/bin/env python3
"""Fail CI if management CGI POST routes gain endpoints without HTTP tests."""
from pathlib import Path
import re

root=Path(__file__).resolve().parents[1]
cgi=(root/'cgi/admin.sh').read_text()
test=(root/'tests/test-http-api-regression.sh').read_text()
post=cgi[cgi.index('handle_post() {'):cgi.index('\npath="${PATH_INFO:-/}"')]
expected=set()
for match in re.findall(r'(?m)^    (/admin/[^)\n]+)\)',post):
    expected.update(match.split('|'))
assert expected, 'Failed to parse backend POST cases'
matrix=test[test.index('routes=('):test.index('\nfor pair in "${routes[@]}"')]
covered=set(re.findall(r"'(/admin/[^:']+):[A-Za-z0-9_.-]+'",matrix))
# The newer HTTPS-only JSON actions are exercised by dedicated live
# integration tests, rather than by the legacy CGI postback matrix.
provider=(root/'tests/test-provider-integration.sh').read_text()
assert '/api/v1/actions/provider/$action' in provider
covered.update('/admin/provider/'+action for action in
               re.findall(r'(?m)^admin_action (save|rotate|delete)\b',provider))
transport=(root/'tests/test-stream-routes.sh').read_text()
assert '/api/v1/actions/stream/save' in transport
assert 'test "$(api "$routes")" = 200' in transport
assert "test \"$(api '[]')\" = 200" in transport
covered.add('/admin/stream/save')
missing=expected-covered
extra=covered-expected
assert not missing, f'POST paths missing from HTTP API regression: {sorted(missing)}'
assert not extra, f'Regression matrix contains removed CGI POST paths: {sorted(extra)}'
for endpoint in ('/admin/export','/admin/import','/admin/owasp/export',
                 '/admin/owasp/import','/admin/owasp/crs/import'):
    assert endpoint in test, f'Raw management handler omitted: {endpoint}'
for endpoint in ('/admin/logs','/admin/logs/export','/admin/alerts',
                 '/admin/collector','/admin/site','/admin/owasp',
                 '/admin/server'):
    assert endpoint in test, f'HTTP API GET path missing: {endpoint}'
print(f'PASS HTTP API contract: all {len(expected)} POST actions and 5 raw import/export endpoints covered')
