# Full backup and restore

In **Server Settings → Full Backup & Restore**, choose **Download full backup** to
save a `.tar.gz` archive of LiteEdge's persistent data directory. To recover
an appliance, choose **Restore from backup**, select the archive, and type
`RESTORE`. Both operations use the authenticated SPA JSON API, with no page
reload or native HTML postback.

## Included

All durable files and subdirectories under `/data` are included, including:

- Sites, routes, backend pools, imported configurations, static websites
- Certificates, private keys, ACME challenges and renewal state
- Admin accounts and password hashes
- NGINX/server settings, ModSecurity and CRS data, plugin state
- Alert rules, SMTP/collector configuration, and other observability settings

**Excluded:** any `logs` directory, `*.log`, `*.jsonl`, and log-processing
cursors or intermediate event chunks. Existing logs remain untouched when a
backup is restored. Restoring from another server does not bring over its
historical events or logs. It replaces saved configuration; it is not a merge.

The archive has a `manifest.json` with file SHA-256 checksums and symlink
metadata, enabling full integrity verification before anything is replaced.

## Restore safety

The API checks the archive format, version, directory paths, file checksums,
symlinks, and expanded size. Unsupported files and path traversal are rejected.
The restore stages files on the same data filesystem, saves existing state
privately, swaps configuration into place and regenerates and validates NGINX.
If NGINX fails validation or reload, the previous configuration is restored
and NGINX is reloaded with the previous files. Log files are never deleted or
replaced.

**A full restore also replaces administrative authentication.** You may need
to sign in again using credentials from the backup. Both backups and restored
configuration include private keys, password hashes, SMTP credentials and
collector tokens. Handle the archive as a secret, and never put it in a public
repository or unsecured shared folder.

The current HTTP upload limit is 256 MiB compressed and 1 GiB expanded.
Archives beyond this limit require an offline/command-line restore workflow.
The service temporarily needs enough disk space to stage the archive and the
new and previous configurations concurrently.

## Versioned HTTP API

`GET /api/v1/backup/export` downloads a full archive using browser-managed
HTTP Basic authentication.

`POST /api/v1/backup/restore` accepts the raw gzipped archive with headers
`Content-Type: application/octet-stream` and `X-LiteEdge-API: 1`.
The API returns JSON `{ "ok": true, "restored": true,
"logs_preserved": true }` on success, or an error describing why the
archive was rejected or the attempted restore was rolled back.
NGINX Basic authentication and same-origin CSRF protections apply.

For maintenance use, after authenticating, the CLI can verify an archive
without applying it:

```sh
DATA_DIR=/data python3 /opt/liteedge/bin/backupctl.py verify backup.tar.gz
```

The restore endpoint validates before writing, so the manual `verify` step is
optional. Test a saved archive on a non-production appliance if possible.
