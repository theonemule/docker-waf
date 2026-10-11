# LiteEdge minimal bare-metal installer (x86-64)

This is a **separate bootable, offline installer** for physical x86-64 machines.
The existing VM ISO remains available and uses Alpine’s `linux-virt` kernel.
The bare-metal image installs the general-purpose Alpine `linux-lts` kernel
with SATA/SCSI, USB, NVMe, and RAID storage drivers, BIOS and UEFI boot,
plus selected Intel, Realtek, and Broadcom network firmware packages.
The image is intentionally CLI-only, without a desktop environment, and
includes the **complete LiteEdge NGINX/ModSecurity, OWASP CRS, UI, API and
management runtime**. The boot media carries signed, offline APK package
indexes and all runtime dependencies. No network or external repository is
required for the installation or first boot.

## Included in the release

- `liteedge-linux-musl-x86_64.tar.gz` and its `.sha256` file provide the
  standalone complete binary distribution for Alpine Linux.
- `liteedge-vm-installer-VERSION-x86_64.iso` and its `.sha256` use the VM
  kernel and are optimized for hypervisors.
- `liteedge-baremetal-installer-VERSION-x86_64.iso` and its `.sha256` use
  `linux-lts` for compatible physical x86-64 servers and appliances.
- Installer scripts, a Compose file and their SHA-256 checksums are included
  in the same GitHub release.

## Write the ISO to installation media

Verify the checksum on a workstation:

```sh
sha256sum -c liteedge-baremetal-installer-VERSION-x86_64.iso.sha256
```

Write the hybrid ISO to a removable USB drive, replacing `/dev/sdX` with the
**entire correct removable device**, not a partition. This action destroys
all data on the removable drive:

```sh
sudo dd if=liteedge-baremetal-installer-VERSION-x86_64.iso of=/dev/sdX \
  bs=4M status=progress conv=fsync
```

Boot the target machine from that USB drive in BIOS or UEFI mode. At the
Alpine shell, log in as root and run:

```sh
sh /etc/liteedge-offline/baremetal-iso-install.sh
```

The installer shows available disks and asks for a full-disk target such
as `/dev/sda`, `/dev/nvme0n1`, or `/dev/vda`. It rejects partitions,
mounted target disks, and the detected live installer device. It requires
an explicit `ERASE` confirmation before starting Alpine's `setup-alpine`.
**The selected target disk will be entirely erased.** The installer asks
for the root password and basic host/network setup. Its APK repository is
forced to the ISO, without internet downloads.

When installation completes, remove the USB drive and reboot. On the first
boot, the included OpenRC local service installs LiteEdge from the offline
payload, creates new administrator credentials on the target machine, and
writes them to `/root/liteedge-install.txt` (readable only by root).

LiteEdge's API/UI listen on the configured management HTTPS port; the
complete WAF runtime is installed as an OpenRC service. Review the generated
`/etc/conf.d/liteedge` and network/firewall settings before exposing it.

## Hardware scope and limitations

The minimal ISO targets generic **x86-64 BIOS or UEFI** hardware with locally
attached disks and supported wired NICs. Hardware requiring firmware outside
the included Intel/Realtek/Broadcom subset may need an additional firmware
package or a custom ISO. Wi-Fi onboarding, proprietary RAID utilities,
Secure Boot key enrollment, storage-encryption prompts, and multi-disk
redundancy are not automatically configured. Validate the disk target and
back up all data before installation.

## Build independently

Build native binaries first, then either or both installers:

```sh
./scripts/build-release.sh 3.1.0
./scripts/build-vm-iso.sh 3.1.0
./scripts/build-baremetal-iso.sh 3.1.0
```

Every ISO build verifies hybrid BIOS and UEFI boot records, its embedded
LiteEdge archive and first-boot hook, and the offline closure of signed APK
packages. The release workflow publishes all three artifacts together after
its validation, container, binaries, VM ISO, and bare-metal ISO jobs succeed.
