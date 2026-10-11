# LiteEdge SPA and versioned API

Status: deployed SPA with authenticated, versioned API.

## Before and after

The original control plane used CGI-generated HTML for navigation and forms. Although JavaScript intercepted many operations, redirects to new HTML documents remained.

The refactor serves a single static HTML shell at the root URL and uses a dedicated browser client in ui/spa.js. Client navigation changes the fragment route while keeping the same Document instance. The main views are Sites, Site configuration, OWASP, Logs, Alerts and Server Settings. Data comes from structured HTTP API responses, not HTML fragments.

## API contract

The new JSON endpoints are protected read and management resources.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | /api/v1/sites | Site inventory |
| GET | /api/v1/site?host=example.com | Routes, backends, WAF, TLS metadata and configuration |
| GET | /api/v1/server | Server and sanitized SMTP/export settings |
| GET | /api/v1/alerts | Alert rules and host/route catalog |
| GET | /api/v1/catalog | Host/alias/route selectors |
| GET | /api/v1/owasp | CRS status, plugin inventory and config, custom rules |
| GET | /api/v1/owasp/rules | CRS rule inventory |
| GET | /api/v1/owasp/crs/check | Check official CRS latest release metadata without downloading/installing |
| GET | /api/v1/logs?type=http&limit=100 | Filtered events |
| GET | /api/v1/logs?scopes_json=... | Filtered events for multiple inventory-validated hosts/aliases/routes |
| GET | /api/v1/logs/export?... | Binary CSV/JSONL download |
| GET | /api/v1/export?... | Binary site/configuration export |
| GET | /api/v1/owasp/export | Binary OWASP export |
| GET | /api/v1/backup/export | Full configuration backup excluding logs (gzip archive) |
| POST | /api/v1/backup/restore | Validated full restore with log preservation and rollback |
| POST | /api/v1/actions/{operation} | Existing validated management mutations |
| POST | /api/v1/import | Binary site configuration import |
| POST | /api/v1/owasp/import | Binary WAF configuration import |
| POST | /api/v1/owasp/crs/import | Binary CRS import |

Mutations accept URL-encoded key/value parameters (Content-Type application/x-www-form-urlencoded) and return JSON success or error with appropriate HTTP status instead of CGI redirects. Import endpoints accept application/octet-stream and return JSON. Archive downloads use JavaScript fetch and a Blob object; they do not navigate away from the application.

The backend still invokes the established Bash control scripts for validation, NGINX testing, application, and rollback. Presentation lives in static JavaScript and never parses CGI-generated markup.

## Authentication and security

NGINX requires HTTP Basic authentication for the SPA entry page, static assets, and every API call. It validates the administrator username and password on each request using the existing htpasswd store. The browser maintains its own Basic authentication credentials and automatically supplies Authorization on same-origin fetch requests (credentials same-origin). The UI does not read, persist, or transmit a JavaScript copy of the administrator password. The API does not return password hashes, SMTP passwords, or log-export tokens.

Mutating calls require the X-LiteEdge-API: 1 header and reject cross-site Fetch Metadata and foreign Origin headers. There is no permissive CORS policy. API responses use Cache-Control: no-store. Use HTTPS in production.

Changing the administrator password invalidates old cached Basic credentials; a subsequent browser API request prompts for new credentials. Do not embed passwords in URLs or application JavaScript.

## Navigation, imports, and compatibility

The SPA uses fragment routes at /#/sites, /#/site/HOST, /#/owasp, /#/logs, /#/alerts, and /#/server. Normal navigation and saving form state uses fetch and updates the existing DOM. It does not submit native forms, reload the document, or call window.location.assign.

Former management-page GET URLs redirect to the corresponding SPA view. Legacy /admin/* form actions are retained for integration compatibility, but no SPA operation invokes them. The previous HTML interface is available only in disposable regression containers when LITEEDGE_ALLOW_LEGACY_UI=1 is set.

The Logs SPA has searchable checkbox-based multi-select controls for hosts and
aliases, followed by dependent route selections. The selected scopes serialize
into `scopes_json` for both API searches and CSV/JSONL exports. Selections
survive SPA navigation without document reloads; queries remain explicit and
unfiltered queries are rejected. Opening the OWASP page asynchronously GETs
`/api/v1/owasp/crs/check` and updates the current/latest versions in place,
without installing CRS. Manual **Check updates** runs the same GET.

A site may have a 1–16 endpoint backend pool. The SPA edits each URL in its own independently addable/removable row, serializing to the existing target and backends fields when saving.

## Verification and release

Run tests against a locally built image (not the live appliance):

    node tests/test-spa-static.js
    node tests/test-spa-log-filters.js
    bash tests/test-spa-api.sh liteedge:spa-api-qa
    bash tests/test-http-api-regression.sh liteedge:spa-api-qa
    shellcheck -x cgi/*.sh bin/*.sh entrypoint.sh

The new API integration test verifies authentication, JSON contracts, authorization failures, CSRF protections, mutations, secret redaction, binary uploads, API downloads, and legacy compatibility. Existing 147 management endpoint regression assertions still run in their legacy opt-in container.

A Chrome browser test confirmed six SPA views, JSON resource retrieval, and the backend editor interactions without document reloads. The test observed a single document request during navigation.

The live deployment uses the SPA/API. Full configuration backup and restore
is available in **Server Settings** and documented in [full backup and restore](full-backup-restore.md).
