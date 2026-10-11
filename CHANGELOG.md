## October 11, 2026 — Logs dropdown dismissal fix

- Close the Logs host/alias and route multi-select menus when clicking outside.
- Opening one menu closes the other, preventing overlapping panels.
- Escape closes the open menu and returns keyboard focus to its trigger.
- Preserve selected host/route filters and maintain the SPA without page reloads.
- Added behavior-level dropdown regression tests to CI and verified in Chrome.

## October 11, 2026 — Full v3.1.1 artifact rebuild and release

- Publish the complete source-based Alpine/musl appliance, offline VM and bare-metal ISOs, and runtime container from current `master`.
- Restore the default-branch CI trigger, publish immutable `v3.1.1` and commit-SHA container tags, and upload all installer assets to GitHub Releases.
- Includes the restored Logs multi-select SPA and automatic check-only OWASP CRS update detection.

## October 11, 2026 — SPA log selectors and CRS update checks

- Restored searchable, multi-select hosts and aliases in the SPA Logs filters,
  with dependent multiple-route selections and inventory-validated scopes.
- Persisted selected log scopes through SPA navigation and used identical
  selections for both event searches and CSV/JSONL exports.
- Opening OWASP now checks the official CRS release feed via authenticated
  check-only JSON API, displays available updates, and never installs a release
  without an explicit separate action.
- Added scoped-query/forgery checks, no-install release-check API checks,
  and SPA selector regression tests.

## October 11, 2026 — Full backup and restore in Server Settings

- Added **Server Settings → Full Backup & Restore** with an authenticated SPA
  download and a validated restore action, without full-page postbacks.
- Captures all persistent `/data` configuration including sites, imported
  routes, WAF rules, ACME/certificate private keys, admin authentication,
  alert rules, collector and SMTP settings, and static website files.
  Explicitly excludes access/security/event logs and log-processing cursors.
- Restores through a checked archive manifest with file SHA-256 hashes,
  traversal/symlink protection, size limits, confirmation, NGINX validation,
  and automatic rollback if activation fails. Logs remain untouched.
- Added disposable end-to-end restore regression tests and bundled Python 3
  with the Docker, Alpine and offline VM/bare-metal installer distributions.

## October 11, 2026 — Offline bare-metal ISO and bundled release

- Added a separate, **minimal x86-64 bare-metal ISO** with the Alpine LTS
  kernel, basic hardware storage support and selected wired NIC firmware,
  BIOS/UEFI boot, offline signed APK packages and the full LiteEdge runtime.
- Added a dedicated installer with disk safety checks, interactive erase
  confirmation, local-only APK repository and first-boot LiteEdge setup.
- Extended CI to build, verify and publish **standalone binaries, the VM ISO
  and the bare-metal ISO** as assets of the same `v3.1.0` GitHub release.
- Preserved the existing VM ISO and Docker release pipelines.

# Changelog

## Unreleased — SPA and authenticated JSON API (feature branch only)

- Static Bootstrap SPA using hash-based navigation and JavaScript `fetch`
  instead of HTML postbacks, document reloads or redirect-after-save.
- Versioned `/api/v1` JSON read models and mutation endpoints for sites,
  routes, WAF, alerts, logs and server settings, plus API upload/download.
- NGINX Basic authentication on every request, browser-managed credentials,
  additional same-origin/Fetch Metadata protection for API writes.
- Compatibility redirects for legacy HTML bookmarks; isolated regression
  tests can opt into old HTML views without changing production behavior.
- Added client contract, authenticated HTTP API, import/export round-trip,
  and browser no-document-reload verification.
- **Not merged to `main` or deployed.**

Significant LiteEdge changes, grouped by user-facing functionality. This
update reviews the approximately 25 commits through October 10, 2026.
See the Git history for individual implementation and corrective commits.

## October 11, 2026 — Undeployed SPA/API refactor

- **Single-page management UI.** Separates Bootstrap presentation into static
  HTML and JavaScript; navigation, modal edits, and saves use authenticated
  API fetch requests without reloading the document.
- **JSON management contract.** Versioned /api/v1 read models, JSON mutation
  responses and import feedback, binary downloads, and server-side validation.
  Existing management scripts remain available for external compatibility.
- **Security.** NGINX Basic authentication protects the SPA, assets, and every
  API endpoint. Mutations require same-origin checks and a custom header.
  Browser-managed credentials are never stored in application JavaScript.
- **Verification.** Adds API, authentication, CSRF, import/export, no-postback,
  and browser navigation tests to complement the existing 147 assertions.

**Not deployed.** Work is isolated for review before a production rollout.
See [SPA/API architecture](docs/spa-api.md).

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
