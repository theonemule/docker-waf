# Docker WAF v3 / LiteEdge

Docker WAF v3 is the appliance generation of the original `theonemule/docker-waf`
project. The appliance is named LiteEdge and is a lightweight reverse proxy and web
application firewall built around NGINX, ModSecurity, and the OWASP Core Rule Set.
It replaces the fixed demo proxy with a Bootstrap management UI and shell-only
control plane.

The original v1/v2 repository is preserved unchanged on the `legacy-v1-v2` branch.

The distributable product is a pre-built Alpine/musl release bundle. The same
bundle is consumed by both the hardened Docker image and the standalone Alpine
installer. Production deployments do not need a compiler toolchain.

The management plane is intentionally small:

- Alpine Linux runtime
- NGINX built from source with the ModSecurity-nginx connector compiled in
- libModSecurity with Lua 5.3 scripting support plus OWASP Core Rule Set
- Bash shell scripts only for application logic
- fcgiwrap to expose shell CGI behind NGINX
- HTTP Basic Authentication using an OpenSSL SHA-512 password hash
- Bootstrap 5.3.8 CSS pinned and verified during the appliance build
- Flat-file persistent configuration
- No Node.js, Python, PHP, database, or application framework

## Release contents

Each release asset contains the complete LiteEdge runtime under /opt/liteedge:

- NGINX
- libModSecurity
- OWASP Core Rule Set
- dehydrated ACME client
- LiteEdge shell control/API scripts
- CGI management UI
- Bootstrap assets
- NGINX and ModSecurity templates
- OpenRC service definition
- standalone Alpine installer
- build/version manifest and third-party licenses

The source build is pinned in build/versions.env. scripts/build-release.sh
performs a serial Alpine build by default so it also works on small build hosts.
The release workflow publishes the generated tarball, SHA-256 checksum,
version-bound Docker installer, and Compose file with checksum for version tags.
Currently, release assets and the runtime image target x86_64 only; Alpine
aarch64 installation is rejected until native aarch64 assets are published.

## Features

Each virtual host defines its host name and aliases, while reverse-proxy behavior is
owned by its routes. Routes support prefix, exact, and regex matches, separate upstream
URLs, WebSocket upgrades, timeouts, and HTTP-to-HTTPS redirection.

OWASP CRS policy is route-scoped. Each route can enable or disable the WAF, select
PL1 through PL4, select installed CRS plugins and application rule-exclusion plugins,
and maintain route-only disabled rule IDs. The OWASP page manages application profiles
and other plugins separately, allows editable plugin configuration with transactional
rollback, exposes core CRS rules through a searchable management dialog, and maintains
custom rules and global exclusions. LiteEdge periodically checks the official OWASP CRS
release feed, surfaces newer stable releases in the UI, and can download or manually
import a CRS source bundle. Updated CRS releases are stored in persistent LiteEdge data
and are staged, validated against NGINX and ModSecurity, and rolled back automatically
if activation fails. OWASP configuration exports include an active managed CRS release.

Each host supports three certificate modes:

- Imported PEM certificate and private key, validated before activation.
- Self-signed certificate generated locally for the host and aliases.
- Let's Encrypt using the shell-based dehydrated ACME client with HTTP-01.

Let's Encrypt certificates are checked twice daily by a small shell renewal loop.
No cron daemon or systemd is required inside the container.

## Docker install

Clone the repository and run:

    git clone https://github.com/theonemule/docker-waf.git
    cd docker-waf
    ./install.sh

Alternatively, download `install-docker.sh` from a v3 GitHub Release into an
empty directory and run it with Bash (downloads do not retain executable
permissions):

    bash install-docker.sh

To run it directly with `./install-docker.sh`, first use
`chmod +x install-docker.sh`. It downloads and verifies the matching release's
`docker-compose.yml` before installing. Released installers default to their
own versioned image tag; repository checkouts default to `latest`. Set
`LITEEDGE_REPO=OWNER/REPO` to use a different GHCR repository and release source.

On first run the installer creates .env, generates a random admin password,
prepares the persistent data directory for the unprivileged container user, pulls
`ghcr.io/theonemule/docker-waf`, and starts it.

Open:

    https://127.0.0.1:8443/

The web proxy uses public ports 80/443; administration is **not available on
those ports**. Admin HTTPS binds only to loopback by default. For private LAN
access, set `LITEEDGE_ADMIN_BIND_IP=10.0.1.2` (use the actual appliance LAN IP)
in `.env` and restart the Compose service. Never forward the admin port from
an internet router. The initial admin certificate is self-signed and Basic Auth
credentials are provided by the installer.

To enable Let's Encrypt, edit .env and set:

    ACME_EMAIL=you@example.com

Then restart:

    docker compose up -d

For HTTP-01 issuance, the host name and aliases must resolve to this server and TCP
port 80 must be reachable from the Internet.

### Container hardening

The Compose deployment runs LiteEdge as UID/GID 10001, uses a read-only root
filesystem, drops all Linux capabilities, enables no-new-privileges, sets a PID
limit, and provides only /data plus a small /tmp tmpfs as writable storage.
NGINX listens on container ports 8080 (website HTTP), 8443 (website HTTPS),
and 9443 (admin HTTPS), mapped to public host ports 80/443 and private host
8443 respectively. The CGI worker runs as the same unprivileged LiteEdge user.

## Standalone Alpine install

The same release bundle can be installed directly on Alpine Linux. After downloading
scripts/install-alpine.sh, run it as root:

    ./install-alpine.sh

To install a specific release:

    ./install-alpine.sh --version v0.1.0

The standalone service runs as the locked-down liteedge account. Only the NGINX
binary receives CAP_NET_BIND_SERVICE, allowing the unprivileged process to bind
ports 80 and 443. Persistent state is stored under /var/lib/liteedge, configuration
under /etc/conf.d/liteedge, and OpenRC manages the service.

`LITEEDGE_BIND_ADDRESS` controls the address used by every generated NGINX listener
and defaults to `0.0.0.0`. `LITEEDGE_PUBLIC_HTTPS_PORT` controls the port emitted in
HTTP-to-HTTPS redirects independently of the internal HTTPS listener. This allows an
appliance to bind LiteEdge only to `127.0.0.1` while a firewall publishes arbitrary
external HTTP and HTTPS ports through DNAT.

## Data layout

In Docker, persistent state is under the ./data bind mount:

    data/
      auth/       Basic Auth password file
      sites/      host and route definitions
      certs/      active host certificates
      acme/       ACME account, challenges, and issued certificates
      logs/       certificate renewal logs
      nginx/      generated runtime NGINX configuration
      waf/        CRS defaults, registry cache, plugins, and custom rules
      www/        local static site content

The UI never writes NGINX configuration directly. Shell utilities validate submitted
values, render generated virtual-host configuration, run nginx -t, and only keep
the generated configuration if validation succeeds.

## Shell utilities

The UI calls the same scripts that can be used manually inside the container:

    /opt/liteedge/bin/sitectl.sh list

    /opt/liteedge/bin/sitectl.sh save \
      app.example.com proxy http://app:8080 "" "" 1 1 0

    /opt/liteedge/bin/sitectl.sh route-add \
      app.example.com prefix /socket/ http://socket:9000 1

    /opt/liteedge/bin/certctl.sh selfsigned app.example.com
    /opt/liteedge/bin/certctl.sh letsencrypt app.example.com

## Security model

The management UI is protected by Basic Auth on a separate HTTPS listener.
Unknown public HTTP hostnames receive 404 and unknown public HTTPS SNI is rejected.
The browser-side UI doesn't depend on inline styles or inline scripts. The UI uses no
client-side application framework and loads its Bootstrap stylesheet locally.

Generated NGINX configuration receives baseline security headers. Route WAF policies
use ModSecurity with the bundled OWASP Core Rule Set and optional installed CRS
plugins. HTTPS virtual hosts use TLS 1.2 and 1.3 plus HSTS.

All mutable application state and generated NGINX configuration live outside
/opt/liteedge. The release tree is immutable at runtime. Configuration mutations
are transactional: generated NGINX configuration is validated before activation and
state is rolled back if validation or reload fails.

Per-site Advanced NGINX edits are tracked as a delta from the last generated baseline.
When UI or certificate changes regenerate a site, LiteEdge uses a three-way merge to
carry forward only the manual delta. Conflicts stop activation rather than overwriting
manual changes. Per-site CRS rule IDs can also be disabled and re-enabled from the UI.

Sites can be exported and imported as portable `.tar.gz` bundles. A bundle contains
site settings, routes, WAF overrides, and the Advanced NGINX manual delta rather than
generated NGINX files. Site or all-sites exports can optionally include active
certificates and private keys. Imports are transactional and certificates are only
replaced when certificate import is explicitly selected.

## Building a release

A Docker engine is required. The build compiles ModSecurity and NGINX inside pinned
Alpine and packages the complete runtime:

    ./scripts/build-release.sh 0.1.0

The default native build concurrency is one job. A larger build machine may opt into
parallel compilation with BUILD_JOBS, but release validation does not require it.

Artifacts are written to dist/:

    liteedge-linux-musl-x86_64.tar.gz
    liteedge-linux-musl-x86_64.tar.gz.sha256

## Development validation

Validate the shell sources with:

    for f in install.sh entrypoint.sh bin/*.sh cgi/*.sh scripts/*.sh; do
      bash -n "$f"
    done

Run ShellCheck:

    shellcheck -x install.sh entrypoint.sh bin/*.sh cgi/*.sh scripts/*.sh

Validate Compose:

    ADMIN_PASSWORD=test docker compose config


## Build and release pipeline

The standalone appliance is the primary build artifact. GitHub Actions compiles
ModSecurity and NGINX in a dedicated appliance build job using the pinned Alpine
toolchain and publishes the resulting Alpine/musl runtime bundle, checksum, and
installers as workflow artifacts.

The Docker build is deliberately separate. The Dockerfile does not compile NGINX
or ModSecurity. It only installs runtime libraries and expands the already-built
appliance bundle into the image. This keeps the standalone appliance and container
on the exact same binaries.

Successful `main` builds publish the container to:

    ghcr.io/theonemule/docker-waf:latest
    ghcr.io/theonemule/docker-waf:v3
    ghcr.io/theonemule/docker-waf:sha-<commit>

Tags matching `v3.*` publish the matching immutable container tag and attach the
standalone appliance bundle and installers to a GitHub Release.
## Logs, alert rules and collection

The **Logs** page combines structured NGINX access events and normalized ModSecurity
rule matches. Events include timestamp, hostname, route match/pattern, external
listener port, internal listener and upstream address (including backend port),
HTTP method/status, path, client IP, request ID and WAF rule/message/disposition.
Filter by hostname, route, method, HTTP status or status class (2xx–5xx), port,
free-text, and Unix timestamp. Download up to 1,000 filtered events as JSONL or
CSV; the view also searches up to seven compressed rotated log archives.
Only the URI path is collected from NGINX; query strings, request/response bodies,
credentials and cookies are not copied into centralized JSON event logs.

The **Alerts** page defines conditions over HTTP/WAF events with event-count
thresholds, rolling windows and cooldown periods. Each rule delivers to an HTTPS
webhook or SMTP email. WAF prevention is done by the OWASP CRS intervention engine,
not by ad-hoc alert scripts. Rule matches and blocked decisions appear in the Logs
screen. The exporter/notification worker runs independently of NGINX so a failed
collector doesn't interrupt the reverse proxy.

The **Log Export** page configures one external sink, either RFC 5424 syslog
(UDP, TCP, or certificate-verified TLS) or HTTPS JSON. HTTPS adapters support
Splunk HEC, Datadog Logs, and Elasticsearch Bulk. Configure SMTP with STARTTLS
for email notifications. Tokens and SMTP passwords are stored in mode 0600 files
under `/data/observability` and never displayed in the form after saving.
Events live under `/data/logs/events.jsonl`; ModSecurity source audit logs are
stored in `/data/logs/modsec_audit.json` and normalized into central events.
A rotation policy limits each active log to 25 MiB with seven compressed copies,
using copytruncate for uninterrupted writes. Worker failures appear in
`/data/logs/observability-worker.log`; the worker retries export/notifications,
with delivery cursors and alert cooldown state persisted under `/data/observability`.

Run `bash tests/test-observability.sh` to exercise filtering, synthetic WAF
normalization, alert delivery/cooldown, redaction and collector validation.

### Inventory-backed alert scopes

The Alerts editor uses multi-select dropdowns populated from the configured site
inventory. Select one or more site hostnames or aliases; the route dropdown then
shows only the NGINX locations or managed routes associated with those sites.
A selected alias filters events by that actual requested hostname, while route
choices remain associated with their owning site. The editor supports editing
existing rules. No host selection means any host, and no route selection means
any route for the selected hosts; choosing routes narrows alerts to the selected
host-and-route combinations. For migrated NGINX sites, route definitions are
also discovered from the saved `location` blocks, even if `.route` files have
not been created. Paths are matched for prefix/exact patterns when the migrated
NGINX configuration does not emit explicit route labels. Selections are validated
against the server-side inventory on save, and older scalar host/route rules
continue matching as before. Test via `bash tests/test-alert-selectors.sh`.

### Inventory-backed log filters

The **Logs** screen now uses the same multi-select host/alias and filtered route
dropdowns as Alerts. Hostnames and aliases come from the configured site
inventory. Route options are read from managed routes and migrated NGINX
`location` blocks. Select multiple hostnames or aliases, then optionally
restrict each selected host to one or more of its routes. Leaving host selection
blank means all hosts; leaving routes blank for a selected hostname includes
all its requests. Matching uses actual request hostnames and either NGINX route
labels or request URI prefix/exact/regex matches for imported routes.

Filters persist across submissions and are applied server-side to the Logs
screen, CSV downloads and JSONL downloads. The backend validates requested
host/route combinations against the current inventory. Older host/route query
parameters still work for bookmarked URLs. Run `bash tests/test-log-selectors.sh`
for multi-site, aliases, WAF events, status classes and tampered-filter cases.

### Import native NGINX virtual hosts into managed routes

LiteEdge can convert preserved NGINX virtual hosts into managed site and route
records without dropping legacy location-level behavior. Import is an explicit,
**offline staging operation**, never a blind startup overwrite:

```bash
python3 scripts/import-native-nginx.py --data /path/to/copied/data --dry-run
python3 scripts/import-native-nginx.py --data /path/to/copied/data
```

The importer reads `data/migration/sites/*.conf` and already-registered
`data/sites/*.site`, producing a `.route` for each native `location` and
per-site templates under `data/imported/sites/`. NGINX server-level settings
and location-specific auth, request limits, redirects, health checks, ACME
exceptions, WebSocket headers, and certificate references remain preserved.
Proxy target, location path/match, timeout and WAF enablement on imported proxy
routes participate in generated NGINX configuration, and route additions or
deletions also affect the output. Imported custom return/ACME locations appear
in the Routes inventory and remain editable via Advanced NGINX rather than
being incorrectly presented as reverse proxies.

The runtime checks for `data/imported/sites/<hostname>/template.conf` and
regenerates the site from managed route records, replacing the former opaque
config-copy approach. No certificates, private keys, or API keys are checked
into source control. The original native configuration and site state should
be backed up and its behavior verified on isolated ports before cutover.

An imported TLS certificate is retained as `mode=imported` and **is not
silently enrolled for automatic renewal**. Configure and validate automated
renewal separately before certificate expiration. Run
`bash tests/test-native-nginx-migration.sh` to check importer idempotence,
custom locations, managed proxy edits, WAF, timeouts and route creation.


### Per-site ACME email and migrated HTTP-01 support

Each site's TLS panel stores its own validated Let's Encrypt contact email in
the persistent certificate directory and provides **Save email** independently
of **Issue / renew**. A global ACME_EMAIL environment value is an optional
fallback for sites without an override. ACME accounts and registration metadata
are isolated by hostname under /data/acme/sites, allowing different accounts
and contact addresses. Renewal reuses the saved contact for each issued site.

Migrated NGINX sites originally containing unconditional HTTP redirects must
serve /.well-known/acme-challenge/ without redirecting. For those imported
sites, use scripts/enable-imported-acme-http01.py on a copied data directory
before production migration. The script preserves ordinary redirect behavior,
recognizes existing HTTP challenge routes, and is idempotent.

Global NGINX migration maps are now included in every regenerated runtime
configuration, not solely by a one-time startup patch. Remove the legacy
one-time map injection from a migrated custom entrypoint before deploying this
change. This prevents OWASP CRS updates from losing $allow_access and other
custom variables.

### Management regression suite and deliberate Logs loading

CI runs fast backend validation and test fixtures, then builds the appliance
and executes **the management HTTP regression suite against a disposable,
authenticated Docker container** before publishing the image. Tests exercise
all 31 current management POST actions (using isolated mocked backends for
network/destructive actions), real site/route CRUD, server settings, alerts,
collector configuration, certificate-contact validation, authentication,
unsafe-input rejection, raw import/export method restrictions, filterable HTTP
and WAF log events, CSV and JSONL exports. A route-contract test fails when a
POST handler is added or removed without updating the HTTP regression matrix.

Run locally with a built container image:

```bash
bash tests/test-http-api-regression.sh ghcr.io/theonemule/docker-waf:latest
python3 tests/test-http-api-coverage.py
node tests/test-logs-ui.js
```

The API test container has **no mount of production data**, and the fast
non-container test suite runs before building the image. Calls that would
contact the CA, fetch CRS updates, or reach external notification systems are
stubbed in the HTTP *dispatcher* phase; the actual certificate/CRS/alerts
implementations retain their separate backend tests. This is broad automated
regression coverage, not a substitute for a dedicated end-to-end test against
external ACME and notification providers.

Opening **Logs** no longer queries event files. Choose at least one hostname,
event type, status, method, port, timestamp or text filter and then click
**Search logs**. An accessible loading state appears during the request, and
results/empty states render after it completes. Blank queries, including blank
CSV/JSONL exports, are rejected. Search state and selected hosts/routes are
retained across filter submissions and browser Back navigation.

### Change administrator password

Go to **Server Settings → Administrator password** and enter the current password, a new password, and confirmation. The authenticated password-change endpoint validates the existing SHA-512-crypt HTTP Basic Auth credential, atomically updates the persisted data-volume htpasswd file, and requires the new password for subsequent requests. Passwords are transmitted to the helper over standard input, not command-line arguments, and never logged. This change survives container rebuilds. If the current password is lost, the machine administrator must reset the authentication file from the host; no unauthenticated web reset is provided.

## Offline virtual-machine installer ISO

Each release now also produces **liteedge-vm-installer-VERSION-x86_64.iso** and
its SHA-256 checksum, alongside the standalone Linux binaries and Docker image.
GitHub Actions builds the standalone binaries **once**. The Docker and ISO
jobs consume that same verified artifact, so their included LiteEdge version
matches. A tagged v3 release publishes the ISO as a GitHub Release asset;
main-branch and PR builds retain the ISO as a workflow artifact for 30 days.

The bootable ISO is made with Alpine Linux 3.22's native `mkimage` tool,
using the x86_64 LTS kernel, BIOS (ISOLINUX) and UEFI (GRUB) boot loaders.
It contains the full signed, dependency-closed Alpine APK repository needed
for the OS installation and LiteEdge runtime, plus the compiled LiteEdge
archive and checksum. **Building** the ISO requires internet access;
**installing** an Alpine/LiteEdge VM from the ISO does **not**. The VM must
have at least 2 GB RAM, a 4 GB virtual disk (8 GB recommended), a network
adapter, and a mounted virtual CD/DVD drive. Use an ordinary virtual BIOS
or UEFI VM. UEFI Secure Boot is **not** supported by the unsigned GRUB loader.

### Installing in Proxmox, Hyper-V, VMware, VirtualBox or KVM

1. Verify the ISO against its adjacent `.sha256` and mount it on the VM.
   Boot the VM from the ISO, and log in as `root` (no password in the
   installer live environment).
2. Run `sh /etc/liteedge-offline/vm-iso-install.sh`. Select the target
   **virtual disk**, explicitly confirm erasure, and complete Alpine's normal
   prompts to set the *OS root password* and network/SSH configuration.
   The installer configures the on-ISO APK repository and runs
   `setup-alpine` in system-installation mode. It does **not** download
   packages, look up GitHub releases, or need a working internet connection.
3. Once Alpine reports disk installation complete, **eject the ISO** and
   reboot. The included one-time OpenRC `local.d` service extracts and
   installs LiteEdge from the offline bundle on first boot. It generates a
   random administrator password **inside the VM**.
4. Log into the VM console as root and inspect
   `cat /root/liteedge-install.txt` (root-readable only) for the LiteEdge
   credentials. Open `https://VM_IP:8443/` to administer LiteEdge. Routes
   listen on 80/443. The state is persisted under `/var/lib/liteedge`.
   To change the password later, use **Server Settings**.

The installer preserves no baked-in user password, SSH host keys, API tokens,
or signing private key. The live disk installer requires intentional disk
selection and typing **ERASE**. The ISO's Alpine APK signing index is generated
at build time, and its public signing key is embedded by the Alpine image
builder. This is a fresh installation, not a backup/restore of the existing
LiteEdge appliance. The first-boot service fails closed if a dependency or
release checksum is missing or invalid; its diagnostic output is stored in
`/root/liteedge-install.txt`.
