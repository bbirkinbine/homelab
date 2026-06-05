# Asustor NAS setup for the Proxmox cluster

NAS-side prerequisites that have to land **before** the
[`pve-host` Ansible role](../pve-hosts/) tries to mount the shared
storage, and **before** the post-baseline `pvesm add nfs` step
registers it as Proxmox storage.

The shared-storage strategy itself (NFS-on-Asustor for cluster-mobile
VMs; node-local LVM-thin for hardware-pinned roles) is decided in the
vault doc `Projects/Homelab/VM Mobility — 3-Node Cluster on
2.5GbE.md`. This doc is the operational runbook on the NAS side.

## Scope

- Asustor ADM-side enablement and configuration: NFS server, shared
  folders, export ACLs.
- Verification from the workstation before the PVE cluster tries to
  mount.

## Out of scope

- The PVE-side mount itself (handled by [pve-hosts/ansible/roles/pve-host/tasks/nfs.yml](../pve-hosts/ansible/roles/pve-host/tasks/nfs.yml)).
- The Proxmox-layer storage registration (manual `pvesm add nfs` after
  cluster join — see [docs/proxmox-install.md](proxmox-install.md#where-the-install-hands-off)
  step 5 and [pve-hosts/README.md](../pve-hosts/README.md#post-baseline-manual-steps) step 4).
- btrfs pool / RAID configuration on the NAS — ADM handles that at
  initial setup; <!-- TODO: record the actual pool layout (RAID level,
  drives, capacity) so a rebuild from scratch has the numbers. -->
- NAS-side network setup — one 2.5GbE port carries everything (main
  LAN; `nas_ip` in inventory). The second 2.5GbE port and the 10GbE
  port are **unallocated**, available for a future dedicated backup
  link or LAG bond if/when the throughput case materializes. The
  PBS↔NAS dedicated-network option was evaluated and deferred —
  rationale lives in
  [`pbs-hosts/CLAUDE.md` § "Network shape"](../pbs-hosts/CLAUDE.md).
  No VLAN tagging on the active port.

## Hardware

- **Model:** Asustor AS6706T (6-bay, Intel Celeron N5105, 4 GB DDR4
  base — likely upgraded; <!-- TODO: confirm RAM upgrade if any -->).
- **ADM version:** <!-- TODO: record the ADM major version this doc
  was validated against (4.x as of writing). Major-version upgrades
  occasionally shuffle the UI; this doc's click-paths assume ADM 4. -->
- **Filesystem:** btrfs (chosen for snapshot + send/receive; ZFS is
  off the table per the repo's active context).
- **Network:** <!-- TODO: which port is the active NFS interface;
  IP / VLAN if any; LACP bond config if 10GbE is bonded with 2.5GbE.
  The PVE cluster mounts via this IP, recorded in
  pve-hosts/ansible/inventory.yml as `nas_ip`. -->

## 1. Enable the NFS server in ADM

ADM ships with NFS disabled. Turn it on once:

1. ADM web UI → **Services** → **NFS Server**.
2. Toggle **NFS Service** to **Enable**.
3. **NFS Version:** `4.2` (or `4` if 4.2 isn't selectable on this ADM
   build — the PVE-side mount in [defaults/main.yml](../pve-hosts/ansible/roles/pve-host/defaults/main.yml#L48)
   uses `vers=4.2,_netdev,noatime,rsize=1048576,wsize=1048576`, and
   the kernel will negotiate down to 4.1 if the server can't do 4.2).
4. **Apply.** ADM restarts the NFS daemon in place; no NAS reboot.

Verification from the NAS:

```bash
# SSH into the NAS as admin (if SSH is enabled), or check via ADM logs:
systemctl status nfs-server   # if NAS exposes systemd
showmount -e localhost        # confirms NFS is listening
```

## 2. Create the shared folder

The PVE cluster expects one shared folder for VM disks. Name it to
match `nas_nfs_export` in [pve-hosts/ansible/inventory.yml.example](../pve-hosts/ansible/inventory.yml#L33).
Inventory currently has `/volume1/proxmox-vms` as the placeholder
default; either keep that or change both this doc and the inventory.

1. ADM web UI → **Access Control** → **Shared Folders** → **Add**.
2. **Volume:** `volume1` (or the volume that's actually the btrfs
   pool — <!-- TODO: confirm which volume number, if you have more
   than one. -->).
3. **Folder name:** `proxmox-vms`.
4. **Description:** "Proxmox cluster shared VM storage (NFS)".
5. **Access permissions:** at this step, ADM is asking about its
   *user/group* ACL (SMB-style). For an NFS-only share intended for
   Proxmox, set:
   - **`admin`** — Read/Write (or whatever ADM-side user manages
     backups; not used by PVE).
   - **`guest`** — No access.
   - **everyone else** — No access.
   NFS-side access is gated separately in step 3 below; this ACL is
   just the underlying filesystem ownership.
6. **Advanced:** leave compression / encryption off unless you have a
   reason (btrfs compression is fine but adds CPU on every read; PVE
   already does qcow2 compression at the disk level for templates).
7. **Apply.**

After creation, the folder appears at `/volume1/proxmox-vms` on the
NAS filesystem.

## 3. Configure the NFS export

This is the load-bearing step — incorrect squash or subnet settings
will silently break VM disk writes after the cluster starts using
the share.

1. ADM web UI → **Access Control** → **Shared Folders** → select
   `proxmox-vms` → **Edit** → **NFS** tab (or "NFS Privileges").
2. **Add an export rule** with these values:

   | Field | Value | Why |
   |---|---|---|
   | **Allowed IP / Host** | your PVE LAN subnet (e.g. `192.0.2.0/24` from the inventory example — must match `pve_lan_subnet`) | Restrict to LAN; never `*` for a homelab on a flat network. |
   | **Privilege** | Read/Write | PVE writes VM disks. |
   | **Squash option** | **No root squash** (`no_root_squash`) | Proxmox stores VM disk images as `root:root`. With root-squash on, every write gets remapped to `nobody` and disk creation fails with EPERM. |
   | **Anonymous GID/UID** | leave blank | Only relevant when root-squash is on. |
   | **Sync mode** | **Sync** | Acknowledges writes only after the NAS has persisted them. Slower than `async` but safer — `async` can corrupt a VM disk on NAS power loss. |
   | **Insecure ports** | **Enabled** | Allows NFS clients to use source ports > 1024. PVE's NFS client defaults to a high port; without this, the mount succeeds but I/O fails. |
   | **Subtree check** | **Disabled** | Default on modern NFS; `subtree_check` is legacy and causes file-handle problems with rename. |

3. **Apply.** ADM regenerates `/etc/exports` and runs `exportfs -ra`.

The export should now show up in `showmount -e <nas_ip>` from any
LAN host.

### How NFS authentication actually works here

NFS does not authenticate with a username/password the way SMB does.
The three layers above (export ACL + squash + POSIX permissions) are
the *entire* auth model. Concretely:

- **The trust boundary is the network.** Anything that can route to
  the NAS on port 2049 from an IP inside `pve_lan_subnet` can mount
  the export. There is no per-client credential check, no Kerberos
  ticket, no shared secret.
- **The "user" the NAS sees is whatever UID the client claims.** When
  Proxmox writes a VM disk as root (UID 0), the NFS wire payload says
  "UID=0" and the NAS believes it. `no_root_squash` is what lets that
  write land as root on disk; with `root_squash` on, the same write
  would be remapped to `nobody` and fail.
- **The `admin` user from step 2 is filesystem ownership, not auth.**
  NFS clients never see usernames — they see UID/GID numbers and
  apply squash rules. The ADM-side per-user ACL only matters if you
  also expose the share via SMB.

**When this model is fine:** trusted LAN, no untrusted devices on it,
firewall blocks port 2049 from outside the subnet, no untrusted code
runs as root on any cluster node. This is the homelab's current
posture, and the standard NFS-on-NAS tradeoff.

**Upgrade path if it stops being fine:** NFSv4 with `sec=krb5` —
actual cryptographic per-user auth via Kerberos tickets, the closest
analogue to SMB's model. Requires standing up a KDC, keytabs on every
client + server, and tight time sync. Heavy infrastructure for a
4-node homelab; raise as a separate project if the threat model
changes.

## 4. Verify from the workstation

Before applying the PVE-side Ansible role, confirm the export is
reachable, mounts cleanly, and accepts a root-owned write:

```bash
# List exports (sanity check the path)
showmount -e <nas_ip>
# Expected: /volume1/proxmox-vms  <your LAN subnet, e.g. 192.0.2.0/24>

# Mount it
sudo mkdir -p /mnt/nas-test
sudo mount -t nfs4 -o vers=4.2 <nas_ip>:/volume1/proxmox-vms /mnt/nas-test

# Write as root (this is the test that catches root-squash misconfig)
sudo touch /mnt/nas-test/probe
sudo ls -la /mnt/nas-test/probe   # owner should be root:root
sudo rm /mnt/nas-test/probe

# Tear down
sudo umount /mnt/nas-test
sudo rmdir /mnt/nas-test
```

If `touch` fails with "Operation not permitted", root-squash is still
on. Go back to step 3, fix it, `exportfs -ra` on the NAS, retry.

If the mount itself hangs, NFS server isn't running (step 1) or the
firewall on the NAS is blocking the LAN subnet.

## 5. Export for the PBS bulk datastore

PBS lives on dedicated hardware (`pbs01`) and needs its **own** NFS
export — separate from the `proxmox-vms` share above. The two workloads have different IO profiles: PVE VM disks
are large sequential reads/writes; the PBS chunk store is millions
of small files (deduplicated chunks under `.chunks/0000/` …
`.chunks/ffff/`) with metadata-heavy GC and verify passes. Mixing
them on one export ACL lets one workload's burst starve the other's
cache, and the NAS-side R/W cache is tuned per share anyway.

The PBS host mounts this export at `/mnt/pbs-bulk` and creates its
datastore at `/mnt/pbs-bulk/datastore`. The PVE cluster does NOT
mount this share — backups flow PVE → PBS API → NFS, not PVE → NFS
directly.

**This section is self-contained.** PBS setup happens at a different
time than the PVE-side share above, so the click paths are restated
here instead of pointing back to § 2-3.

### 5a. Create the `proxmox-backups` shared folder

1. ADM web UI → **Access Control** → **Shared Folders** → **Add**.
2. **Volume:** `volume1` (same underlying btrfs pool as `proxmox-vms`).
3. **Folder name:** `proxmox-backups` (matches `nas_pbs_nfs_export` in
   [pbs-hosts/ansible/inventory.yml.example](../pbs-hosts/ansible/inventory.yml.example);
   change both if you pick a different name).
4. **Description:** "PBS chunk store (NFS, dedicated)".
5. **Access permissions** (filesystem ACL — NFS-side gating is in
   § 5b below):
   - **`admin`** — Read/Write.
   - **`guest`** — No access.
   - **everyone else** — No access.

   NFS clients never see usernames; this ACL is just the underlying
   filesystem ownership. The NFS export ACL is the real trust
   boundary.
6. **Advanced:** leave compression / encryption off. PBS already
   deduplicates chunks and optionally encrypts at the client; adding
   btrfs compression on top burns CPU on every read for little space
   win, and share-level encryption is redundant with PBS's own.
7. **Apply.**

After creation the folder lives at `/volume1/proxmox-backups` on the
NAS filesystem. The PBS host's `pbs_datastore.yml` task will create
its `datastore/` subdirectory inside on first apply — pre-creating
it is harmless but not required.

### 5b. Configure the NFS export

1. ADM web UI → **Access Control** → **Shared Folders** → select
   `proxmox-backups` → **Edit** → **NFS** tab (or "NFS Privileges").
2. **Add an export rule** with these values:

   | Field | Value | Why |
   |---|---|---|
   | **Allowed IP / Host** | the PBS host's single LAN IP, `/32` form (e.g. `192.0.2.20/32`) | Tighter than the subnet-wide ACL on the PVE share — there's exactly one consumer. Widening later is a one-click change. |
   | **Privilege** | Read/Write | PBS writes chunks. |
   | **Squash option** | **No root squash** (`no_root_squash`) | PBS's chunk store is owned by the daemon `backup` user (uid 34 on PBS 4.x). The role's `pbs_datastore.yml` chowns the datastore directory to `backup:backup` on first apply; with root-squash on, the chown gets remapped to nobody and fails. |
   | **Anonymous GID/UID** | leave blank | Only relevant when root-squash is on. |
   | **Sync mode** | **Sync** | `async` risks corrupting the chunk store on NAS power loss. PBS verify would surface the corruption eventually but recovery costs a full re-backup. |
   | **Insecure ports** | **Enabled** | PBS's NFS client uses source ports > 1024; without this the mount succeeds but I/O fails. |
   | **Subtree check** | **Disabled** | Legacy; causes file-handle problems with rename. |

3. **Apply.** ADM regenerates `/etc/exports` and runs `exportfs -ra`.

The NAS does **not** need a matching `backup` user/group on its side.
The client sends UID 34 in the NFS wire payload; with
`no_root_squash` the NAS accepts it and writes files owned by uid 34
on the btrfs filesystem. Whether the NAS has a name for that uid is
cosmetic (`ls -ln` will show `34` instead of `backup`).

The "How NFS authentication actually works here" subsection under § 3
applies identically to this export — trust boundary is the network
ACL, not the UID claim.

### 5c. Verify from the workstation

```bash
showmount -e <nas_ip> | grep proxmox-backups
# Expected: /volume1/proxmox-backups  <pbs01_ip>/32

# Mount test — run from the PBS host's LAN IP, or temporarily widen the
# ACL to include your workstation IP for this test then revert.
sudo mkdir -p /mnt/pbs-test
sudo mount -t nfs4 -o vers=4.2 <nas_ip>:/volume1/proxmox-backups /mnt/pbs-test
sudo touch /mnt/pbs-test/probe && sudo ls -la /mnt/pbs-test/probe   # owner root:root
sudo rm /mnt/pbs-test/probe
sudo umount /mnt/pbs-test
sudo rmdir /mnt/pbs-test
```

If the role's chown step later fails during `just pbs-hosts`, root-
squash is still on. Go back to § 5b, fix it, `exportfs -ra` on the
NAS, retry.

### 5d. PBS-specific NAS notes

- **Inode budget.** PBS stores chunks as separate files under 65,536
  nested directories (`.chunks/0000/` … `.chunks/ffff/`). File count
  at low-double-digit TB will be in the millions. btrfs handles that
  cleanly; just be aware if any NAS monitoring or quota system counts
  files rather than bytes.
- **NAS-side snapshots are redundant.** Every PBS snapshot is already
  immutable in the chunk store, and PBS handles retention via prune
  jobs. A btrfs snapshot schedule on `proxmox-backups` is storage you
  don't need to spend — leave that share off any ADM snapshot policy
  you set for `proxmox-vms`.

## 6. (Optional, deferred) Additional shares

Likely future shares; not required for the cluster's current scope:

- **`proxmox-iso`** — `/volume1/proxmox-iso`, mounted on all nodes,
  registered in Proxmox as `nas-iso` content type `iso,vztmpl`. Lets
  the per-node ISO libraries (currently `local`) go away.
- **`obsidian-vault-mirror`** — read-only mirror of the workstation's
  Obsidian vault; not a homelab-cluster concern.

Each one is repeat the steps 2 + 3 above with a different folder
name. Add the corresponding `nas_*_export` fields to inventory and a
follow-on `pvesm add nfs` invocation. Don't pre-create empty shares
"in case I need them later" — wait for a concrete consumer.

> **Note on legacy `proxmox-backup` share:** earlier drafts of this
> doc listed a `proxmox-backup` share registered as PVE storage with
> content type `backup` (the `vzdump`-to-NFS path). That's a different
> mechanism from the PBS host above and is no longer the lab's
> backup-of-record. `proxmox-backups` (the export in § 5) is the
> active design.

## Related docs

- [pve-hosts/README.md](../pve-hosts/README.md) — the Ansible role
  that mounts the share at the filesystem layer (`/mnt/nas-vms`).
- [pve-hosts/ansible/roles/pve-host/tasks/nfs.yml](../pve-hosts/ansible/roles/pve-host/tasks/nfs.yml)
  — the actual mount task.
- [docs/proxmox-install.md](proxmox-install.md) — layer-0a install
  doc; this NAS setup is a prerequisite before the first
  `just pve-hosts` run.
- Vault: `Projects/Homelab/VM Mobility — 3-Node Cluster on
  2.5GbE.md` — decision rationale for NFS-on-Asustor as the
  cluster-shared-storage strategy.
- Vault: `Projects/Homelab/Homelab Inventory.md` — hardware
  inventory including AS6706T specifics.
