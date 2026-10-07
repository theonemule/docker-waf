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
The release workflow publishes the generated tarball and SHA-256 checksum for
version tags.

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
    cd LiteEdge
    ./install.sh

On first run the installer creates .env, generates a random admin password,
prepares the persistent data directory for the unprivileged container user, pulls
`ghcr.io/theonemule/docker-waf`, and starts it.

Open:

    https://SERVER_IP/

Requests to the management listener over HTTP are redirected to HTTPS before Basic
Auth credentials are requested. The initial HTTPS management certificate is
self-signed. Use the Basic Auth credentials printed by install.sh.

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
NGINX listens on unprivileged container ports 8080 and 8443, which are mapped to
host ports 80 and 443. The CGI worker runs as the same unprivileged LiteEdge user.

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

The management UI is protected by NGINX HTTP Basic Auth over HTTPS. HTTP requests to
the management listener are redirected before authentication. The UI uses no
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
