# Proxmox Backup Server 4.x bare-metal install

The install-time procedure for bringing a fresh PBS host up to a state where the [`pbs-host` Ansible role](../pbs-hosts/) can take over. This is **layer 0a** for PBS — what the operator does sitting in front of the box with a USB stick. Everything declarative is layer 0b ([pbs-hosts/](../pbs-hosts/)) and later.

The lab runs one PBS host (`pbs01`). Parallel doc for the PVE cluster: [docs/proxmox-install.md](proxmox-install.md).

## What this doc covers

- BIOS / UEFI prerequisites that have to be set before the installer boots.
- The PBS installer click-through, including the lab's filesystem and hostname conventions.
- Post-install steps that have to happen before `pbs-host` runs: workstation SSH pubkey.

## What this doc does NOT cover

- The `pbs-host` Ansible baseline (repo swap, packages, chrony, NFS mount, ufw, datastores, API token, scheduled jobs). That's [pbs-hosts/README.md](../pbs-hosts/README.md).
- The PVE-side storage registration (`pvesm add pbs ...`). One-time manual step against any cluster member after the PBS host is online with a working API token; lives in the [cluster bring-up runbook](cluster-bring-up.md) as a post-Phase-2 follow-up.
- TLS certificate replacement. PBS ships a self-signed cert; the eventual swap to a cert from the offline Root CA on the CardLogix HSM is a future task with its own runbook.

---

## Prerequisites

### Install media

PBS 4.x ISO (Debian 13 / trixie base). Download from <https://www.proxmox.com/en/downloads/proxmox-backup-server>. <!-- TODO: pin the exact point release you've validated against. -->

Write the ISO to USB. The lab convention is the same tool used for the PVE installs (Ventoy on a multi-installer stick is the pragmatic default — see [docs/proxmox-install.md § Install media](proxmox-install.md#install-media)). GMKtec G3 Pro boots USB cleanly in UEFI mode.

### Network plan

Before booting the installer, know the values for:

| Field | Source |
|---|---|
| LAN IP (`/24`) | [pbs-hosts/ansible/inventory.yml.example](../pbs-hosts/ansible/inventory.yml.example) — `pbs_lan_ip` per host |
| LAN gateway | router LAN address |
| DNS server | router LAN address |
| Hostname (FQDN) | `pbs01.local` |

### NAS-side NFS export (can run in parallel)

The [`pbs-host` Ansible role](../pbs-hosts/) mounts a **dedicated** Asustor NFS share at `/mnt/pbs-bulk` on first apply — separate from the `proxmox-vms` export used by the PVE cluster (chunk-store IO profile differs enough from VM disk IO that mixing them on one export ACL is the wrong shape). The NAS-side setup — creating the `proxmox-backups` shared folder, configuring the export ACL (`no_root_squash`, `sync`, restricted to the PBS host's LAN IP) — has to land before the role runs. It does NOT have to land before this install finishes, so it's safe to do in parallel. See [docs/asustor-nas-setup.md § Export for the PBS bulk datastore](asustor-nas-setup.md#export-for-the-pbs-bulk-datastore).

### Root password

Generate before the install. Stored in KeePassXC (unlocked with YubiKey HMAC per repo convention) as `pbs01-root`. The installer asks once; if you lose it, the only recovery is single-user boot. Do not type a memorable password — generate a long one and copy it across when prompted.

### BIOS access

GMKtec G3 Pro: **DEL or F7 at the boot logo** (DEL drops you into AMI BIOS setup; F7 is the one-time boot menu). If you miss the prompt, hold DEL from the moment you press power.

Once in BIOS, check the firmware version against GMKtec's support page and flash an update if one is newer than what's running. A fresh install is the cleanest moment for it — vendor BIOS pushes commonly carry microcode, fan-curve, and USB-stability fixes, and the settings table below will be re-applied afterward anyway.

---

## BIOS / UEFI prerequisites

Set these once before the install:

| Setting | Value | Why |
|---|---|---|
| **VT-x** | Enabled | Not strictly required for PBS (no virtualization workload) but the default; leave on. |
| **VT-d (IOMMU)** | Enabled | Same — default on; harmless. |
| **Secure Boot** | Disabled | PBS 4.x will boot with it on, but disabling avoids surprises with DKMS modules and custom kernels if you ever go off-stock. One less thing to fight. |
| **Boot order** | USB first | Temporary, for the install. Revert to NVMe-first after the install completes so the box doesn't try to USB-boot on every power cycle. |
| **Wake-on-LAN** | Enabled (optional) | Lets you wake the host remotely if you've ever powered it off. PBS is normally on 24/7, so this is operator preference. |

Save and exit. Insert the USB. Power-cycle.

---

## Installer click-through

The PBS installer is a 6–8 step GUI, near-identical to the PVE installer. Defaults are mostly fine; the choices that matter for this lab are called out below.

1. **Boot the installer.** "Install Proxmox Backup Server (Graphical)". Text-mode works if the framebuffer misbehaves.

2. **Accept the EULA.**

3. **Target Harddisk → Options.** PBS-specific notes:
   - **Filesystem: `ext4`.** Not ZFS — same reasoning as the PVE side (ZFS is off the table for this lab; RAM overhead + no ECC + small dataset = wrong tool). PBS chunk-store integrity comes from PBS's own hash-on-write, not the filesystem.
   - **Target disk: the internal NVMe** (`nvme0n1`, the only block device on a stock G3 Pro). The 512 GB NVMe holds only the OS + journal; bulk backup data lives on the NAS NFS mount (managed by the `pbs-host` role).
   - Leave `hdsize`, `swapsize`, `maxroot` at the installer defaults. PBS doesn't carve out a `local-lvm` analog by default; the disk is one big root partition.

4. **Country / Time zone / Keyboard.** US / `America/New_York` / `en-US`. Match the PVE cluster's timezone — chrony in the `pbs-host` role syncs against the same NTP targets as PVE, but a matching timezone keeps log timestamps comparable across hosts.

5. **Administration Password + Email.** Paste a per-host root password from KeePassXC (`pbs01-root`). Local Linux `root` lives in `/etc/shadow`; PBS's separate `root@pam` PBS-realm user uses the same password by default but operates independently of the OS user. The `pbs-host` role installs the operator SSH pubkey into `root@<host>` so post-install access runs on keys; the password is essentially a console-recovery credential. <!-- TODO: email — your inbox or a dummy. PBS uses it for job-failure notifications if you wire postfix up later; pbs-host role does not configure outbound mail. -->

6. **Management Network Configuration.**
   - **Management Interface:** the single 2.5GbE port. The PBS installer doesn't rename it the way the PVE installer does (PVE 9.x writes `50-pmx-nic0.link`; PBS leaves systemd's predictable name like `enp1s0`).
   - **Hostname (FQDN):** `pbs01.local`.
   - **IP Address / CIDR / Gateway / DNS Server:** from the network plan above.

7. **Summary.** Verify hostname, IP, disk, filesystem. **Tick "Reboot after install"** before clicking Install.

8. **Wait ~3–5 minutes.** PBS installs faster than PVE because there's less to install — no qemu, no `pveproxy`, no Ceph. When the box reboots, remove the USB stick immediately so it boots from NVMe.

The first boot drops to a console login (`Proxmox Backup Server 4.x …`) and prints the web UI URL (`https://<ip>:8007`). Verify both from your workstation:

```bash
ping pbs01.local                   # or the IP directly if mDNS isn't set up
curl -k https://pbs01.local:8007   # 200 = web UI alive (self-signed cert; -k skips verify)
```

---

## Post-install: pre-Ansible

### Drop the workstation SSH pubkey

The `pbs-host` role connects as `root` over SSH using your workstation's key. Get the key onto the box before the first Ansible run:

```bash
# From the workstation:
ssh-copy-id root@pbs01.local
# Prompts once for the install-time root password; never again after.
```

That's the only manual post-install step. PBS doesn't need the equivalent of `pve12t`'s `nuc12-fast` carve-out — the bulk datastore lives on the NAS NFS mount, and the local NVMe is the OS-only filesystem.

---

## Where the install hands off

At this point a fresh PBS host is:

- Booted to PBS 4.x.
- Reachable on the LAN at its planned IP.
- Authenticated to your workstation via SSH key.

If those three are all true, this doc is done — its scope ends at "the installer click-through produced a usable PBS 4.x host."

Everything beyond that — `pbs-host` Ansible baseline (`just pbs-hosts`), API token capture for the PVE cluster, PVE-side `pvesm add pbs` storage registration, first backup job — is the `pbs-hosts/README.md` and [docs/cluster-bring-up.md](cluster-bring-up.md) sequence.

---

## Per-host specifics

| Host | Hardware | Notes |
|---|---|---|
| `pbs01` | GMKtec G3 Pro Mini PC — Intel Core i3-10110U (2C/4T, Comet Lake-U), 16 GB DDR4, 512 GB NVMe, 1× 2.5GbE | Primary backup target for the PVE cluster. Bulk datastore on Asustor NFS. |

The i3-10110U is a 2-core / 4-thread Comet Lake-U at ~2.1 GHz base. PBS's hot path (chunk hashing, GC, verify) is single-threaded per worker, so core count matters less than IPC + I/O. The 2.5GbE LAN port is the throughput ceiling for backup ingest from the PVE cluster; the CPU is comfortably ahead of the network.

---

## Related docs

- [pbs-hosts/README.md](../pbs-hosts/README.md) — layer 0b: the Ansible baseline that runs on top of this install.
- [pbs-hosts/CLAUDE.md](../pbs-hosts/CLAUDE.md) — full spec for the baseline role, including everything that's deliberately out of scope.
- [docs/asustor-nas-setup.md § Export for the PBS bulk datastore](asustor-nas-setup.md#export-for-the-pbs-bulk-datastore) — the NAS-side NFS export this install assumes will be ready before the role's first apply.
- [docs/proxmox-install.md](proxmox-install.md) — parallel doc for the PVE cluster. Many of the same patterns (KeePassXC, SSH pubkey, ext4-on-LVM) apply.
- [docs/0-scratch-build-order.md](0-scratch-build-order.md) — master index for the whole-lab build sequence. PBS is its own phase between cluster bring-up and per-role deploys.
- Vault: `Projects/Homelab/Proxmox Backup Server — Capabilities and Tiered Storage.md` — authoritative architecture (tiering, future Root-CA-signed TLS).
