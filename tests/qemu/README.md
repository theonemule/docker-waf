# Disposable three-VM Kubernetes integration

Run the actual appliance and controller images against a new Alpine/K3s
cluster on QEMU. This is an end-to-end integration test, not kind or a
simulation of kernel/network behavior.

## Prerequisites

- Linux x86_64 Docker host with approximately 7 GiB free RAM, 3 usable CPU
  threads and at least 15 GiB free disk. KVM acceleration is preferred;
  QEMU TCG fallback is slower and may need longer timeouts.
- Docker CLI, Bash, curl, openssl, coreutils, kubectl and Helm 3 on PATH.
- Network access to Alpine packages and GitHub release downloads on the
  first run. The large Alpine image and K3s airgap images are cached.
- Existing local appliance and controller images to test.

The wrapper creates an isolated Debian-based QEMU runner container, with
only /dev/kvm passed through if the Docker daemon supports it. There are
no host network, host directory, production kubeconfig or production
credentials mounts. VM SSH, Kubernetes API and public test forwarding
ports bind only to the runner's loopback. Fresh ephemeral SSH keys,
provider token, admin TLS key and HA key are generated for each test.
Only evidence files (not VM disks, private keys or kubeconfig) are copied
out when the runner exits. The cached Alpine cloud image is immutable
installation media, never a previously booted VM disk. Each run creates
three complete independent QCOW2 disks (no backing files), new cloud-init
seed media, SSH identities, Kubernetes installation, NFS storage and Helm
releases. Each guest validates its unique cloud-init token, completed
cloud-init, packages, kernel/cgroups, address and empty K3s/NFS state before
installation. Kubernetes node boot IDs must match those freshly booted VMs.

The CI wrapper labels its disposable containers, bridge, and fixture/harness
images with a run scope. The guest shuts down QEMU and destroys its private
disks and state on exit; the host forcibly removes the container and all
associated volumes, removes its bridge and images, and verifies absence.
An independent always-run CI step repeats cleanup and checks the result;
the next serialized CI QEMU job purges only stale CI-labelled resources.
No running manual lab or unrelated virtual machine is eligible for deletion.
A runner power failure can prevent immediate cleanup; preflight cleanup
recovers on the next run. No mutable guest state is cached.

## Repeat

From the repository root:

```sh
QEMU_CACHE_DIR="$HOME/.cache/lightedge-qemu" \
  bash tests/test-qemu-kubernetes.sh \
  liteedge:qemu-fs-group-fix lightedge-controller:3.2.0-rc.1 \
  "$PWD/qemu-evidence/$(date +%Y%m%d-%H%M%S)"
```

Use the current tested appliance image and matching controller; the
original rc.1 image contains the private-directory permission problem
identified by this test, so use a rebuilt image containing the fix.
The output directory must not exist before running. Never point this
script at an existing Kubernetes cluster.

Pinned inputs: Alpine 3.22.6 x86_64 BIOS NoCloud image (SHA512 checked
against the published manifest), K3s v1.34.3+k3s1 (upstream SHA256 checks
for binary and airgap archive), Gateway API v1.4.0 experimental CRDs (includes standard resources).
Alpine guest packages are installed from the versioned distribution
repository and may receive security updates between runs.

## Topology and acceptance

- One control-plane VM: 1 vCPU, 2 GiB RAM; two worker VMs:
  1 vCPU and 1.5 GiB RAM each by default. Override with
  `QEMU_WORKER_MEM_MB` and `QEMU_CONTROL_MEM_MB`. Private Ethernet bus: 192.168.77.0/24,
  Flannel pod network: 10.42.0.0/16, service CIDR: 10.43.0.0/16.
- An NFSv4.2 server inside the control-plane guest exports a dedicated
  directory to the isolated worker network. The chart mounts a genuine
  RWX NFS PV; each appliance's other data uses K3s local-path storage.
  The lab export uses no_root_squash **only in this disposable isolated
  network**. Do not copy this export policy into production.
- Helm installs the controller and a two-replica HA appliance
  StatefulSet with mandatory distinct-node scheduling. Values in
  `values.yaml` explicitly enable all supported listener types.
  The public service uses deterministic NodePorts for HTTP, HTTPS,
  extra HTTP/HTTPS, TCP, UDP and TLS passthrough. Every host forward
  binds exclusively to the runner's loopback.
- Two Hello World pods, one per worker, run the same Go fixture and
  listen for HTTP (8080), HTTPS (8443), cleartext HTTP/2 gRPC (12005),
  raw TCP (12001), UDP (12002), and raw TLS (12003).
  Every response includes pod/node identity, protocol and a unique
  request nonce. gRPC replies use protobuf StringValue envelopes,
  actual HTTP/2 and grpc-status trailers; HTTPS and passthrough use
  distinct certificates whose fingerprints and DNS identities are
  checked by the client. No insecure client TLS option is used.
- `hello.yaml` declares Deployment, headless Services, Gateway,
  HTTPRoute, GRPCRoute, TCPRoute, UDPRoute, TLSRoute, BackendTLSPolicy,
  and Ingress. No native routes are configured directly on the
  appliances. Headless Services make LightEdge choose individual
  backend addresses. The secure Service has explicit backend CA
  validation. The fixture's HTTPS backend is distinct from TLS
  passthrough.
- Wait for node readiness, Helm rollout, Gateway Programmed, every
  route parent Programmed/ResolvedRefs, backend policy Accepted,
  and both appliances' local revision/digest matching the signed
  shared current revision plus a direct request.
- Preserve the initial 40 external and 12-per-appliance HTTP checks,
  plus WAF rejection (403). The protocol matrix below runs through
  each guest ingress address and directly through every active
  appliance. Every measured probe must succeed, return the requested
  nonce and protocol, and show both distinct backend identities in
  each appliance's sample. Public samples use fresh connections.
- Negative tests verify unknown SNI rejection and invalid UDP-to-TCP
  Service port rejection plus unrelated HTTP/gRPC traffic and UDP
  recovery. A protocol-specific warm-up is bounded; measured requests
  are never retried or silently omitted. Each request has an absolute
  15-second deadline and logs measured latency; the stream and HA logs
  are retained for diagnosis.
- Repeat the entire protocol matrix with one appliance absent; update
  the HTTPRoute through Kubernetes; scale back to two replicas and
  require the new response header and matching signed revision/digest.
  Repeat the matrix on both rejoined appliances. Route convergence
  polls are not a zero-downtime assertion.
- A zero exit code and PASS QEMU FULL INTEGRATION indicate acceptance.
  Inspect run.log for transient errors even when the final check passes.

## Protocol matrix

| Case | Frontend | Backend |
|---|---|---|
| Gateway HTTP | HTTPRoute / HTTP | HTTP |
| Gateway HTTPS | HTTPRoute / HTTPS | HTTP |
| Additional HTTP port | HTTPRoute / 8081 | HTTP |
| Additional HTTPS port | HTTPRoute / 8443 | HTTP |
| HTTP to verified HTTPS | HTTPRoute / HTTP | HTTPS, BackendTLSPolicy |
| HTTPS to verified HTTPS | HTTPRoute / HTTPS | HTTPS, BackendTLSPolicy |
| Ingress HTTP | Ingress / HTTP | HTTP |
| Ingress HTTPS | Ingress / HTTPS | HTTP |
| gRPC h2c | GRPCRoute / HTTP/2 | gRPC h2c |
| gRPC TLS termination | GRPCRoute / HTTPS HTTP/2 | gRPC h2c |
| TCP | TCPRoute / 9000 | TCP |
| UDP | UDPRoute / 9001 | UDP |
| TLS passthrough | TLSRoute / 9444 | Raw TLS with backend certificate |

The standard Ingress API has no TCP/UDP/TLS passthrough or GRPCRoute
equivalent. These protocols use Gateway API. Kubernetes gRPC upstream
TLS policy, mixed termination/passthrough on one socket, and advanced
bidirectional streaming are not claimed. This is a protocol and HA
integration regression, not a replacement for the upstream core and
extended conformance suites. The test runs in build-and-publish.yml
after the candidate images exist and before publication. A failure
blocks publishing. Hosted workflow execution still requires GitHub CI.

Evidence includes node and pod placement, serial logs, K3s logs, public
request samples, per-appliance request samples, load distribution,
route status, replica rejoin revision/digest, controller and appliance
logs, cluster events and host/guest exit status. A failing run also
retains available evidence. This lab does not prove a multi-control-plane
Kubernetes quorum, independent physical host availability, a production
storage outage, or bare-metal installer boot.

### First qualification results

The original 3.2.0-rc.1 run successfully routed and balanced traffic but
failed on recreated-pod startup due to fsGroup changing permissions of
the private generated configuration directory. After repairing the
startup mode on the owned directory and applying OnRootMismatch, the
fresh three-VM run passed all functional assertions: 40/40 external
requests (20 per backend), 12/12 through each appliance (6 per backend),
WAF rejection, 12/12 after replica removal, route update and identical
signed revision on rejoin. One five-second request timeout occurred
during route convergence with a single replica, so the test does not
claim zero-downtime updates. The final run exposed a logging/cleanup
wait deadlock after functional success; the wrapper now waits only
for QEMU child processes, and a focused cleanup test passed. The
functional result was 0; the original host wrapper reported 141 when
its stuck logger was terminated. Release artifacts must be rebuilt
with the appliance and Helm fixes.

### Multi-protocol qualification (2026-11-24)

Run04 passed all 13 baseline cases (624 measured probes) with both
appliances and backend pods, plus 40 public and 24 direct HTTP requests,
WAF rejection and unknown-SNI rejection. Both 1024 and 1536 MiB worker
runs encountered memory exhaustion while applying the deliberately
invalid UDP backend-port update. At 1536 MiB, worker2 reported zero
available memory and the UDPRoute's status had not observed the changed
generation. The runner was stopped to release resources. Do not treat
this as a full-suite pass: UDP withdrawal/recovery and the repeated
single-replica and rejoin matrices remain unqualified. Investigate
reload memory pressure before release. The CI gate remains fail-closed.

Evidence: development workspace
`lightedge-qemu-evidence/multi-protocol-run04/` (also run01 through run03).
The original release candidate must be rebuilt with the prior fsGroup
fix. Hosted CI execution is still pending.
