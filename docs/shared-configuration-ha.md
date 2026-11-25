# Shared configuration high availability

LightEdge does not require SQL, Redis, etcd or another database for HA.
Its native configuration files remain the source format. A group of trusted
appliances uses one authoritative filesystem, mounted separately from each
node's ordinary data directory. The Kubernetes controller uses **one**
provider endpoint for the shared group, rather than sending independent
copies of every snapshot to the members.

## Layout and trust

```text
/ha/                         # same persistent filesystem on every member
  cluster.json               # administrator-managed membership and bootstrap member
  key                        # optional cluster key; external key file preferred
  .writer.lock               # cross-member exclusive flock
  current.json               # atomically published HMAC-signed revision manifest
  history/                   # retained signed historical manifests
  acme/                      # shared ACME accounts, work files and HTTP-01 challenges
  revision-<number>-<sha256>/ # immutable native source for this revision
    sites/
    certs/                   # application certificates and private keys, not _admin
    waf/
    providers/
    server-settings.conf     # if present
/data/                       # a DIFFERENT local persistent volume on each member
  sites/, certs/, waf/, providers/  # last applied local source cache
  nginx/                    # mutable rendering workspace, local only
  .liteedge-nginx-generations/ # validated immutable active runtime generations
  logs/, observability/      # node-local operational state
  auth/                     # node-local management authentication
  .liteedge-ha-applied.json # last successfully applied shared revision
  .liteedge-ha-pending.json # crash-recovery marker during a configuration write
```

Never mount all of /data as the shared HA source. NGINX generated files,
process IDs, sockets, logs, local health state and admin TLS material must
not be shared. All members should run the same compatible appliance version
and have the same backend network reachability. Software binaries/images
are upgraded separately; this mechanism refreshes configuration, not code.

Example cluster.json (create it on the shared volume as UID/GID 10001,
restrict access to the cluster operators and members):

```json
{
  "cluster_id": "edge-cluster",
  "bootstrap_node": "edge-a",
  "members": {
    "edge-a": "edge-a.example.internal",
    "edge-b": "edge-b.example.internal"
  }
}
```

Generate a 256-bit cluster key using `openssl rand -hex 32`, store it in
a restricted file, and mount the same key on each member. A separate
Kubernetes Secret or other protected mount is preferred to storing it
alongside the shared configuration files. Member hostnames are recorded
for administration; there is no mandatory peer-to-peer notification port.
The shared signed manifest **is the signal**. HMAC establishes possession
of the group key, not cryptographic attribution to a particular member;
all members and administrators with the key are mutually trusted.

## Appliance configuration

| Environment variable | Meaning |
|---|---|
| LITEEDGE_HA_DIR | Separate shared mount, e.g. /ha. Empty disables HA. |
| LITEEDGE_HA_NODE_ID | Unique identity listed in cluster.json. |
| LITEEDGE_HA_KEY_FILE | Path to the 64-hex-character shared secret; defaults to /ha/key. |
| LITEEDGE_HA_BOOTSTRAP | Set to 1 only during intentional initial provisioning; only the designated member may initialize an empty source. |
| LITEEDGE_HA_POLL_SECONDS | Signed revision check interval, default 2 seconds, bounded to 1–60. |
| LITEEDGE_HA_LOCK_TIMEOUT_SECONDS | Shared writer lock contention retry deadline, default 60 seconds (1–600); does not bound kernel I/O on a hard NFS mount. |

Initialize the first appliance with its existing compatible native source
files and provider policy. Start it with bootstrap enabled. Once it has
published revision 1, start the other members with bootstrap disabled.
Existing revisions take precedence over the local cache. Remove the
bootstrap flag after successful provisioning. A missing current manifest
with existing revision directories requires operator recovery, never an
automatic reset.

## Write and refresh protocol

1. The chosen management member acquires the shared writer lock and its
   local configuration lock, reads the signed current revision, and
   catches up before processing a mutation. A provider revision is common
   to the group, so cross-member optimistic concurrency works as usual.
2. Existing LightEdge tools validate the candidate, render and reload local
   NGINX. The writer stages native source files, computes their SHA-256
   tree digest, persists a revision directory, then atomically publishes
   the signed manifest. Unchanged source is a no-op.
3. Other members periodically read the manifest. They verify the cluster,
   member, HMAC, increasing revision and source digest, copy native
   configuration into their local cache, render, validate and reload
   their own NGINX. They record the applied revision only on success.
4. A member that was stopped or missed the signal loads the newest valid
   revision on startup. A failed peer render rolls back locally. If the
   shared source is unavailable or invalid, running members preserve
   last-known-good traffic and shared writes fail rather than diverge. A
   durable pending-write marker forces reconciliation even when the shared
   revision did not change. An interrupted local provider journal is also
   recovered before synchronization.

The shared filesystem must provide coherent cross-host POSIX flock, atomic
same-filesystem rename, durable fsync and consistent reads. Confirm these
properties with the actual RWX CSI driver/NFS mount; an access mode alone
is not sufficient. Do not use object-store mounts with emulated locking.
The storage system itself must be highly available if configuration
management is to remain available during a storage outage.

This is eventual per-node activation, not distributed atomic activation.
The writer reloads before the shared commit; other members reload after
observing it. The NGINX reload signal is asynchronous, so the writer waits until a worker serves the exact new generation marker on a private node-local Unix socket. Use the applied revision for monitoring; it is not proof that every old worker has drained.
The Helm readiness probe excludes members with a known newer signed
revision pending; during source loss it preserves last-known-good service.
The external public Service/load balancer still controls client failover.

## Kubernetes Helm deployment

Provision an existing RWX PVC containing cluster.json. The identities for
release `test` in namespace `lightedge-system` are
`test-lightedge-appliance-0` and `test-lightedge-appliance-1`; their DNS
names are available through the chart's headless members Service. Set the
bootstrap member to ordinal 0 for the initial deployment. Create an
existing Secret with key `key` containing the hex HMAC secret. Use the
usual provider and admin TLS Secrets for the management Service DNS name.

```yaml
appliance:
  enabled: true
  ha:
    enabled: true
    replicas: 2
    requireDistinctNodes: true
    existingClaim: lightedge-shared-ha
    keySecret: lightedge-ha-key
    bootstrap: true  # first installation only
  storage:
    size: 1Gi       # local cache PVC per member
provider:
  targetsSecret: "" # shared group uses the single management Service
```

The chart uses a StatefulSet with stable identities, individual local RWO
claims, one shared RWX claim, and a separate key mount. Explicitly add
new members to cluster.json before scaling. The bootstrap flag is ignored
for non-bootstrap identities. The ordinary single-appliance deployment
is unchanged. This is a new opt-in topology; migration from an existing
single-appliance Deployment requires an operator-planned migration.

## Shared ACME issuance and renewal

Existing native Let’s Encrypt certificate actions are available in HA
mode. All members use /ha/acme for the mutable ACME account state and
HTTP-01 challenge directory. HTTP requests to any member can serve the
same challenge token. Application certificates and private keys are
still installed locally and published through signed native revisions.

Issuance runs under the shared writer lock. The periodic renewal worker
on each appliance rechecks the certificate under that lock, after
catching up to the current revision. It renews certificates due within
30 days, or whose host coverage changed; a second member skips renewal
once the first has installed a fresh covering certificate. The shared
account directory prevents unnecessary account registration. Issued
certificates must cover the site and aliases and match the private key
before installation. ACME challenges require an existing HTTP site and
public port 80 routing to all serving members.

The initial migration of existing standalone ACME accounts into the
protected shared ACME directory is an operator task. Do not copy private
account keys into public challenge storage. The shared writer lock is
held during ACME network operations, so slow issuance can delay other
configuration mutations; normal proxy traffic continues. Back up ACME
state separately from the signed revision directories.

Offline integration tests exercise the real issuance and renewal
orchestration with a test ACME client. They do not contact Let's Encrypt;
a live staging-CA test remains necessary.

## Signed configuration history and recovery

Run the following from a configured HA appliance as an authorized
operator:

```sh
python3 /opt/liteedge/bin/ha_config.py history
python3 /opt/liteedge/bin/ha_config.py restore-revision 12
python3 /opt/liteedge/bin/ha_config.py prune --keep 10
# After reviewing the preview and verifying external backups:
python3 /opt/liteedge/bin/ha_config.py prune --keep 10 --apply
```

Historical manifests are authenticated using the group HMAC key and their
source content is verified before restoration. Restoring a prior revision
publishes a new monotonically increasing revision; it never rewinds the
shared pointer. Kubernetes provider compare-and-swap revisions also
increase. Active Kubernetes controllers may subsequently reconcile their
desired state over a restored configuration. Restoration refuses a
historical provider authorization/credential change. Review the historical
configuration and certificate validity before restoring.

Pruning is explicitly operator initiated and defaults to preview. It
retains at least two signed revisions, including the current revision.
Only retained, signed historical revisions are eligible; orphan directories
from older builds or interrupted commits are left untouched. There is no
automatic deletion or automatic restoration if the shared pointer is lost.
External backups of the entire shared source, membership and key remain
essential. This is shared configuration recovery, not a full per-node
backup/restore.

## Scope and limitations

- Shared mode covers provider API mutations and the native managed source
  files, including manual site/route edits, WAF rules/settings, imported
  application certificates and coordinated native ACME issuance/renewal. Management authentication, admin TLS,
  observability/alert configuration, static website files, and runtime
  data remain local.
- Advanced raw NGINX editing, imported site bundles and full backup restore
  remain deliberately blocked in shared mode; they need portable override
  and restore workflows. Existing imported or manually edited configurations
  are rejected at initial bootstrap. Use signed configuration history for
  shared-source recovery.
- Configure provider policies on the bootstrap member before the first
  revision. Direct edits to a member's local cache are not authoritative;
  the next shared mutation reconciles to the canonical source.
- Shared revisions contain secrets. Protect and back up the filesystem
  and key; use explicit signed-history retention only after reviewing
  backups. Do not manually change the pointer or revision
  directories. HMAC detects tampering by parties without the key, not a
  compromised trusted member or administrator with access to the key.
- Actual production RWX mount qualification, key rotation, live ACME
  staging validation, NAS outage/reboot and production migration remain
  operational gates. The real NFSv4.2 storage primitives have been tested
  on two independent clients; see below. Independent multi-target controller replication is
  still available for truly independent appliances, but is not required
  for members of one shared-source group.

## Verification

```sh
python3 tests/test-ha-config.py
bash tests/test-shared-config-ha.sh liteedge:kubernetes-dev
bash tests/test-shared-config-ha-kind.sh liteedge:kubernetes-dev lightedge-controller:kubernetes-dev
```

The Docker integration test uses two live appliances, a shared volume and
independent local volumes. The kind harness uses a simulated shared hostPath volume; HA_MULTINODE=1
requires distinct Kubernetes worker nodes but still uses one physical
Docker host. Neither simulation qualifies a production RWX driver.


## Real shared-storage qualification (2026-11-24)

Two independent Linux clients (the application-server VM and the
workstation) accessed isolated scratch directories on the same NAS.
No serving appliance, existing mount, or application records were
changed. Results:

| Configuration | Result |
|---|---|
| Mixed NFSv4.2 / SMB3.1.1 | **Rejected:** both clients could acquire exclusive flock concurrently. |
| Default NFSv4.2 on both clients | Exclusive lock exclusion and handoff passed; negative metadata lookup visibility delayed peer notification about 28 seconds. |
| NFSv4.2, hard, local_lock=none, actimeo=1, lookupcache=none | Bidirectional lock exclusion, atomic rename, file and directory fsync, and lock handoff passed. One marker round trip measured 0.112 seconds. |
| Abrupt test holder termination | Peer acquired exclusive lock in 0.001 seconds on the tuned mount. |

The low-cache tests used isolated Docker NFS volumes with
`nosharecache` to avoid inheriting unrelated mounts' cache options.
Do not use multiple overlapping client mounts with conflicting caching
options for the same live configuration. Provision a **dedicated NFSv4.2
export** for HA, restricted to the members, mounted consistently, with
server-side locking and suitable attribute/lookup cache behavior. Never
access the same live HA source through SMB and NFS simultaneously.
The scratch test directories and volumes were removed. These are
observed storage-primitives results, not a real production outage,
NAS restart, multi-member ACME or production application failover test.

The same tuned NFS export was subsequently tested with two disposable
appliances on the independent hosts. The peer initially applied a new
signed configuration about 30.39 seconds after manifest publication.
Switching shared writer lock acquisition to bounded nonblocking flock
retries reduced observed peer convergence to 2.68 seconds. Both
appliances served the updated route and agreed on the signed revision.
A stopped member then rejoined, applied a new revision committed by the
surviving member, and served the new route. Temporary resources were
removed. These measurements are observations, not a guaranteed latency
SLA; they do not qualify storage-server failure or NAS reboot recovery.

For a real RWX Kubernetes installation, provision an isolated namespace
labelled lightedge.io/qualification=true and use:

```sh
scripts/qualify-ha-storage.sh /path/to/kubeconfig CONTEXT lightedge-qualify-site RELEASE
```

This requires two Ready replicas on distinct Kubernetes nodes and a real
RWX PV (not hostPath/local). It tests isolated scratch locks, durable
replacement visibility and equal signed revision without changing the
serving configuration. Verify the actual PV/CSI mount options and test
node/storage failure recovery separately before production rollout.

### QEMU/KVM fresh-cluster regression

`tests/test-qemu-kubernetes.sh` provisions three Alpine/K3s VMs and a
dedicated in-guest NFSv4.2 RWX volume, installs the Helm chart, validates
two independently placed appliances, backend distribution and a
replica removal/update/rejoin sequence. See `tests/qemu/README.md`.
The initial rc.1 test exposed Kubernetes fsGroup remount permissions
broadening the private local NGINX generation directory on a recreated
pod. Startup now restores mode 0700 only on an appliance-owned
non-symlink directory before any master is started; runtime publication
still requires private permissions. The chart uses OnRootMismatch to
avoid unnecessary recursive permission changes. This is not a
relaxation of runtime certificate or configuration confidentiality.
