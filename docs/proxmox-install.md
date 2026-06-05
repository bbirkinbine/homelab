# Proxmox VE 9.x bare-metal install

The install-time procedure for bringing a fresh NUC up to a state where the
[`pve-host` Ansible role](../pve-hosts/) can take over. This is **layer 0a**
— what the operator does sitting in front of the box with a USB stick.
Everything declarative is layer 0b ([pve-hosts/](../pve-hosts/)) and later.

The lab runs four nodes (`pve12t`, `pve13m`, `pve13t`, `pve12t2`); the steps are
identical across them except where called out. The decision to keep this
manual rather than building a PVE-autoinstall + remastered-ISO pipeline is
in the vault doc `Projects/Homelab/PVE Host Bootstrap — Manual Install +
Ansible Role.md` (TL;DR: the amortization math is wrong at 3-node scale).

## What this doc covers

- BIOS / UEFI prerequisites that have to be set before the installer boots.
- The PVE installer click-through, including the lab's filesystem and
  hostname conventions.
- Post-install steps that have to happen before `pve-host` runs:
  workstation SSH pubkey, per-node storage carve-outs (`pve12t` only).
- TB4 cabling — physical wiring of the line topology once all three
  nodes are installed; everything beyond plugging cables in (peer
  enrollment, module load, PCI-path discovery, interface pinning)
  is handled by the `pve-host` role.

## What this doc does NOT cover

- The `pve-host` Ansible baseline (repo swap, packages, chrony, networking
  templates, NFS mount, firewall, SSH hardening). That's [pve-hosts/README.md](../pve-hosts/README.md).
- The cluster join ceremony (`pvecm create` / `pvecm add`). Manual,
  quorum-aware; runs after baseline. Vault: `VM Mobility — 3-Node Cluster
  on 2.5GbE.md`.
- eGPU PCIe passthrough on `pve12t`. Reboots + GRUB edits; lives in
  [docs/proxmox-gpu-passthrough.md](proxmox-gpu-passthrough.md) and runs
  after `pve-host`.
- Packer / OpenTofu API user creation. Run after baseline; see
  [docs/proxmox-permissions.md](proxmox-permissions.md) and
  [docs/proxmox-tofu-permissions.md](proxmox-tofu-permissions.md).

---

## Prerequisites

### Install media

PVE 9.x ISO (Debian 13 / trixie base). <!-- TODO: pin the exact point
release you've validated against — pve-no-subscription ships rolling
updates, but the installer ISO is per-release. As of writing, PVE 9.x
is current; record the build here once the first rebuild is done. -->

Write the ISO to USB. The lab convention is <!-- TODO: Ventoy /
balenaEtcher / `dd` — record the tool you actually used so future-you
doesn't re-research it. The pragmatic default is Ventoy on a 32 GB stick
because it lets you keep multiple installers (PVE, Ubuntu, Windows,
memtest) on one drive. --> on a USB 3.0+ stick. The NUCs boot it cleanly
in UEFI mode.

### Network plan

Before booting the installer, know the values for:

| Field | Source |
|---|---|
| LAN IP (`/24`) | [pve-hosts/ansible/inventory.yml](../pve-hosts/ansible/inventory.yml.example) — `pve_lan_ip` per host |
| LAN gateway | inventory `pve_lan_gateway` |
| DNS server | inventory or your router's LAN address |
| Hostname (FQDN) | `pveXX.local` per node (see table below) |

The lab uses `pveXX` for Proxmox hostnames — `pve12t`, `pve13m`, `pve13t`.
**Do not use `nuc12` / `nuc13-mini` / `nuc13-tall`** even though that's
how the vault `Homelab Inventory.md` doc labels the physical chassis —
those are hardware tags, not OS hostnames, and mixing them propagates
into `/etc/hosts`, Corosync, and inventory in ways that are painful to
back out of.

### NAS-side NFS export (can run in parallel)

The [`pve-host` Ansible role](../pve-hosts/) mounts the Asustor NFS share
at `/mnt/nas-vms` on first apply. The NAS-side setup — enabling the NFS
server in ADM, creating the shared folder, configuring the export ACL
(`no_root_squash`, `sync`, restricted to the LAN subnet) — has to land
before that role runs. It does NOT have to land before this install
finishes, so it's safe to do in parallel while the PVE installer is
running. See [`docs/asustor-nas-setup.md`](asustor-nas-setup.md).

The Proxmox-layer storage registration (`pvesm add nfs nas-vms ...`) is
a separate post-baseline step covered below under "Where the install
hands off".

### Root password

Generate before the install. Stored in KeePassXC (unlocked with the
YubiKey + backup-YubiKey enrollment per repo convention). The installer
asks once; if you lose it the only recovery is single-user boot. Do not
type a memorable password — generate a long one in KeePassXC and copy
it across when prompted.

### BIOS access

NUC12 / NUC13 BIOS: **F2 at the boot logo** (or F10 for the one-time
boot menu). NUC13 sometimes boots fast enough to skip the prompt; if
you miss it, hold F2 from the moment you press power.

---

## BIOS / UEFI prerequisites

Set these once per node before the install. Most are dual-purpose —
some are install-time only (Secure Boot, boot order), some are for
later runtime features (IOMMU for passthrough).
[docs/proxmox-gpu-passthrough.md](proxmox-gpu-passthrough.md#1-bios--uefi)
covers the GPU-specific BIOS subset; this section is the minimum
**every** node needs.

| Setting | Value | Why |
|---|---|---|
| **VT-x** | Enabled | KVM virtualization. Required everywhere. |
| **VT-d (IOMMU)** | Enabled | Required for PCIe passthrough (eGPU on `pve12t`, USB-HSM on `vms/rootca/`). Set on all nodes for parity. |
| **Secure Boot** | Disabled | PVE 9.x will boot with it on, but it complicates DKMS modules, custom kernel parameters, and the eGPU vfio plumbing. Off is one less thing to fight. |
| **Boot order** | USB first | Temporary, for the install. Revert to NVMe-first after the install completes so the box doesn't try to PXE / USB on every boot. |

> **On Thunderbolt security:** ASUS NUC13 / NUC12 firmware does not expose a "Thunderbolt Security Level" setting (older Intel-branded NUC firmware did). The kernel reports `security=user` (SL1) by default. This is fine — the `pve-host` Ansible role's `thunderbolt.yml` task handles persistent peer-host trust via `boltctl enroll --policy=auto` on first run. No operator action needed before or during the install for the TB fabric beyond plugging the cables in. Vault: `Thunderbolt Mesh Networking — 3-Node Cluster Option.md`.

For `pve12t` specifically (eGPU node), also set: **Above 4G Decoding =
Enabled**, **Resizable BAR = Enabled**, **Primary Display = iGPU /
Internal**. Detail in [docs/proxmox-gpu-passthrough.md](proxmox-gpu-passthrough.md#1-bios--uefi).

NUC BIOS menus group these under "Advanced" → "PCI" / "Power" / "Boot
Configuration"; exact paths drift between NUC12 and NUC13 generations.
If the box won't POST after a BIOS change, clear CMOS and re-enable
one setting at a time.

Save and exit. Insert the USB. Power-cycle.

---

## Installer click-through

The PVE installer is a 6–8 step GUI. Defaults are mostly fine; the
choices that matter for this lab are called out below.

1. **Boot the installer.** "Install Proxmox VE (Graphical)". The
   text-mode installer works too if the framebuffer misbehaves, but
   graphical is the path validated below.

2. **Accept the EULA.**

3. **Target Harddisk → Options.** This is the only screen with a
   load-bearing decision:
   - **Filesystem: `ext4`.** Not ZFS (off the table for this lab — RAM
     overhead + no ECC + small dataset = wrong tool), not btrfs (btrfs
     lives on the NAS, not on PVE hosts).
   - **Target disk: the internal NVMe** (the only block device on a
     stock NUC). `nvme0n1` typically.
   - Leave `hdsize`, `swapsize`, `maxroot`, `maxvz`, `minfree` at the
     installer defaults unless you have a reason. The defaults reserve
     a `local-lvm` (LVM-thin) pool sized for VMs; the `pve-host` role
     and the `proxmox-vm` OpenTofu module assume `local-lvm` exists by
     default. <!-- TODO: if you discover that the installer's default
     local-lvm sizing is too small for the workloads you actually run,
     record the override values here. -->

4. **Country / Time zone / Keyboard.** US / `America/New_York` /
   `en-US`. <!-- TODO: confirm timezone matches NTP plan; chrony in the
   pve-host role syncs against Cloudflare + pool.ntp.org so timezone is
   cosmetic-only. -->

5. **Administration Password + Email.** Paste a **per-node** root
   password from KeePassXC — separate entries for `pve12t`, `pve13m`,
   `pve13t` (e.g. `pve12t-root`, `pve13m-root`, `pve13t-root`). Local
   Linux `root` lives in each node's own `/etc/shadow` regardless of
   cluster state; only `pveum`-managed users (the Packer / OpenTofu
   API users) replicate via pmxcfs after cluster join. The role
   installs the operator SSH pubkey into `root@<host>` so inter-node
   `pvecm` / `pvesh` / `rsync` runs on keys; the password is
   essentially a console-recovery credential. Per-node passwords
   contain blast radius if any single node is compromised, at
   zero UX cost with KeePassXC + YubiKey. <!-- TODO: email — your
   inbox or a dummy. The installer uses it for cron output / SMART
   warnings if you wire postfix up later; pve-host role does not
   configure outbound mail. -->

6. **Management Network Configuration.**
   - **Management Interface:** the 2.5GbE port (the PVE 9.x installer
     shows the interface under whatever name systemd would predict
     — typically `enpXsY` on NUC12 / NUC13; pick the one with a cable
     in it). Post-install, the installer renames it to `nic0` via
     `/usr/local/lib/systemd/network/50-pmx-nic0.link` matched on MAC,
     so subsequent docs and the `pve-host` role refer to it as `nic0`.
   - **Hostname (FQDN):** `pveXX.local` per the table:

     | Node | FQDN | Hardware (vault label only) |
     |---|---|---|
     | `pve12t` | `pve12t.local` | NUC12 Pro Tall, i7-1260P |
     | `pve13m` | `pve13m.local` | NUC13 Pro slim, i7-1360P (TB transit) |
     | `pve13t` | `pve13t.local` | NUC13 Pro Tall, i7-13620H |

   - **IP Address / CIDR / Gateway / DNS Server:** from the network
     plan above. <!-- TODO: record the actual LAN subnet here once
     inventory.yml is filled in — keeping it in inventory.yml plus
     here is duplicative but lets a rebuild proceed without consulting
     the IaC repo. -->

7. **Summary.** Verify hostname, IP, disk, filesystem. **Tick "Reboot
   after install"** before clicking Install — saves you a step.

8. **Wait ~5–10 minutes.** When the box reboots, remove the USB
   stick immediately so it boots from NVMe.

The first boot drops to a console login (`Proxmox VE 9.x …`) and prints
the web UI URL. Verify both from your workstation:

```bash
ping pve12t.local                  # or the IP directly if mDNS isn't set up
curl -k https://pve12t.local:8006  # 200 = web UI alive
```

---

## Post-install: pre-Ansible carve-outs

### 1. Drop the workstation SSH pubkey (every node)

The `pve-host` role connects as `root` over SSH using your workstation's
key. Get the key onto the box before the first Ansible run:

```bash
# From the workstation:
ssh-copy-id root@pve12t.local
# Prompts once for the install-time root password; never again after.
```

The role will harden `sshd_config` (`PasswordAuthentication no`,
`PermitRootLogin prohibit-password`) on its first run, so this is the
last time you'll need the install-time password over SSH.

### 2. `pve12t` only — create the `nuc12-fast` LVM-thin pool

The LLM VM (deferred work; not yet provisioned) needs a fast scratch
pool for model weights, separate from `local-lvm` so a runaway model
download doesn't fill the VMs pool. The `pve-host` role assumes this
exists on `pve12t` (see [pve-hosts/CLAUDE.md](../pve-hosts/CLAUDE.md) §
"Drive partitioning, LVM-thin pool creation, LUKS partitions" — out of
scope for the role; install-time concern).

**Recommended approach: dedicated second drive in the NUC12 Pro Tall's
2.5" SATA bay.** Any SSD ≥256 GB works; this lab uses a 1 TB SATA SSD.
The drive becomes its own VG (`nuc12fast_vg`), the thinpool fills it,
and the NVMe stays untouched as `local-lvm`. Zero install-time
partition-size math, and a clean failure domain (drive death loses
re-downloadable models, NVMe stays intact).

```bash
# Verify the new drive shows up (sda is typical; adjust if different):
lsblk

# Wipe any prior signatures, create a single full-disk GPT partition:
wipefs -a /dev/sda
sgdisk -N 1 /dev/sda

# PV → VG → thinpool, sized to fill the drive (99% leaves headroom for
# thinpool metadata growth):
pvcreate /dev/sda1
vgcreate nuc12fast_vg /dev/sda1
lvcreate -T nuc12fast_vg/nuc12-fast -l 99%FREE

# Register with Proxmox, pinned to pve12t so other cluster members
# don't try to read a thinpool that doesn't exist on them:
pvesm add lvmthin nuc12-fast --vgname nuc12fast_vg --thinpool nuc12-fast \
  --content images,rootdir --nodes pve12t

# Sanity:
pvesm status | grep nuc12-fast
cat /etc/pve/storage.cfg | awk '/^lvmthin: nuc12-fast/,/^$/'
```

The `--nodes pve12t` flag is mandatory for cluster correctness — without it,
other nodes will try to activate a VG they can't see and log errors.

#### Fallback: carve `nuc12-fast` out of the NVMe (no second drive)

If `pve12t` has only the one NVMe and you can't add a SATA SSD,
`nuc12-fast` has to come out of the `pve` VG alongside `local-lvm`.
This is messier — the installer's default `maxvz` consumes the whole VG
into the `data` thinpool, so post-install you have to shrink `data`
to free extents:

```bash
# Make sure local-lvm is empty (no VMs yet, otherwise back them up first):
pvesm list local-lvm   # should return nothing
lvs --noheadings -o data_percent pve/data   # should be 0.00

# Shrink data by 200 GiB (150 for nuc12-fast + 50 headroom):
lvreduce -L -200G pve/data

# Then carve:
lvcreate -T pve/nuc12-fast -L 150G
pvesm add lvmthin nuc12-fast --vgname pve --thinpool nuc12-fast \
  --content images,rootdir --nodes pve12t
```

`lvreduce` refuses if `data`'s allocated extents won't fit in the new
size, so it's safe on a fresh install but won't work after you've put
VM disks on `local-lvm`. The dedicated-drive approach above sidesteps
this entirely.

The Root CA VM **does not** need a host-side LUKS partition anymore —
encryption was moved inside the guest on 2026-05-11. See [vms/rootca/](../vms/rootca/).

### 3. Other nodes (`pve13m`, `pve13t`)

No carve-outs. The installer's defaults give you `local` (for ISOs)
and `local-lvm` (for VMs); that's everything `pve-host` and the
OpenTofu module assume. Cluster-shared NFS storage (`nas-vms`) is
mounted by the role itself once the NAS export is online — not at
install time.

---

## TB4 cabling

Once all four nodes are installed and reachable on the LAN, plug
in the two TB4 cables to form the line topology: `pve12t ── pve13m
── pve13t`. `pve13m` is the transit midpoint with both ports used.
The eGPU keeps its TB port on `pve12t`. See vault `Thunderbolt Mesh
Networking — 3-Node Cluster Option.md` for the wiring diagram.

The TB fabric is additive — the cluster forms over the 2.5GbE LAN
first; TB carries live migration + Corosync ring1.

Everything beyond plugging the cables in (peer enrollment, module
load, PCI-path discovery, `.link` interface pinning, IPs and routes)
is handled by the `pve-host` Ansible role on first apply. Spec in
[pve-hosts/CLAUDE.md](../pve-hosts/CLAUDE.md) (`thunderbolt.yml` task).

---

## Where the install hands off

At this point a fresh node is:

- Booted to PVE 9.x.
- Reachable on the LAN at its planned IP.
- Authenticated to your workstation via SSH key.
- On `pve12t`: has the `nuc12-fast` LVM-thin pool ready (or staged with
  free extents in the `pve` VG, depending on your carve plan).

If those four are all true, this doc is done — its scope ends at "the
installer click-through produced a usable PVE 9.x host."

Everything beyond that — `pve-host` Ansible baseline, cluster join,
firewall enable, snippets content type, NFS storage registration, API
users for Packer + OpenTofu, eGPU passthrough — is sequenced in
[docs/0-scratch-build-order.md](0-scratch-build-order.md) (resume at
Phase 1 step 4 if you've been following that index, otherwise read it
top-to-bottom for the full picture). That doc is the single source of
truth for the post-install ordering; this section deliberately doesn't
restate it to avoid drift.

---

## Related docs

- [docs/0-scratch-build-order.md](0-scratch-build-order.md) — master
  index for the whole-cluster build sequence; read this first if
  you're rebuilding from bare metal.
- [pve-hosts/README.md](../pve-hosts/README.md) — layer 0b: the Ansible
  baseline that runs on top of this install.
- [pve-hosts/CLAUDE.md](../pve-hosts/CLAUDE.md) — full spec for the
  baseline role, including everything that's deliberately out of scope.
- [docs/proxmox-gpu-passthrough.md](proxmox-gpu-passthrough.md) —
  install-time BIOS prerequisites for the eGPU node; full passthrough
  plumbing happens after baseline.
- [docs/proxmox-permissions.md](proxmox-permissions.md) — Packer API
  user; runs per-node after baseline.
- [docs/proxmox-tofu-permissions.md](proxmox-tofu-permissions.md) —
  OpenTofu API user; runs per-node after baseline.
- Vault: `Projects/Homelab/PVE Host Bootstrap — Manual Install +
  Ansible Role.md` — decision rationale for skipping PVE autoinstall.
- Vault: `Projects/Homelab/Thunderbolt Mesh Networking — 3-Node
  Cluster Option.md` — TB topology + BIOS prereqs in more depth.
- Vault: `Projects/Homelab/VM Mobility — 3-Node Cluster on 2.5GbE.md`
  — cluster + NFS architecture this install targets.
