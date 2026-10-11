# Changelog

Significant LiteEdge changes, grouped by user-facing functionality. This
update reviews the approximately 25 commits through October 10, 2026.
See the Git history for individual implementation and corrective commits.

## October 10, 2026 — Site and route operations

- **SMTP moved to Server Settings.** Email alert delivery has a dedicated SMTP
  configuration form and save operation. Log Export updates no longer
  overwrite SMTP settings; existing credentials remain in persistent data.
- **Reversible site disable/enable.** The Sites list and Manage page expose
  status controls. Disabled sites respond with HTTP 503 but retain their
  hostnames, routes, policies and TLS certificates.
- **Modal route configuration.** Add and Configure now open dialogs, keeping
  the route inventory compact.
- **Backend pools.** Routes can combine one primary with additional HTTP
  backend URLs. Choose round-robin, least-connections, client-IP hash, or
  `liteedge_affinity` cookie hashing. NGINX supports per-backend
  `max_fails` and `fail_timeout` passive failure handling.
- **Active backend monitoring.** Optional direct HTTP probes allow a custom
  path, expected code/class, timeout, interval, down/recovery thresholds,
  and notification cooldown. Transitions appear in Logs and can trigger
  health-down/recovery alerts through existing webhook or email channels.
- **Sensitive MCP access logs.** Added opt-in `liteedge_mcp_json` for
  logging HTTP outcomes without leaking private URL paths or route labels.
- **Retained log filters.** Corrected the literal `$search` default and
  retained host, route, status, text and other filters across searches and
  navigation in the same browser tab.

**Limits:** Active probes provide monitoring and alerting, but do not
dynamically control NGINX upstream selection. Passive NGINX failure detection
handles traffic failover. Disabled sites also return 503 for ACME HTTP-01
requests, so re-enable before renewal. Redacted MCP logging must be opted
into per sensitive location.

See [Site routing and health operations](docs/site-routing-and-health.md).

## October 9, 2026 — Installer, management and ACME

- **Offline hypervisor installation.** Added Alpine x86_64 VM ISO output
  using BIOS/UEFI boot support and dependency-complete on-media APK packages.
  The ISO and Docker image consume the same compiled appliance runtime.
  First-boot setup runs after system installation and confirmation of
  disk-erasing operations. Image-building fetches from official Alpine
  GitHub mirror where appropriate.
- **Admin password management.** Added the authenticated, persistent
  administrator password-change UI under Server Settings.
- **Responsive management actions.** Improved progress and failure/success
  feedback, including import forms and API actions.
- **Regression coverage.** Added the authenticated management HTTP
  regression suite, import/export coverage, and checks that CGI POST routes
  have tests. The current matrix covers 35 POST actions.
- **On-demand Logs.** Opening Logs no longer queries event storage.
  Search requires an explicit filter and user action.
- **Certificates and migration.** Added per-site Let's Encrypt email
  configuration, corrected renewal/account scope and imported ACME challenge
  handling, and preserved migration maps during config regeneration.
- **Build reliability.** Added digest-pinned public Alpine build sources,
  clean native release builds, and VM first-boot/package closure checks.

Earlier October updates added structured request/WAF logs, external
collectors, notifications and inventory-backed host/route selectors for
Logs and Alerts; see the [README](README.md) for their use.
