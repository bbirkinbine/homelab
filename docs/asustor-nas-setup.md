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
- NAS-side network bond / 10GbE setup — <!-- TODO: AS6706T has a
  10GbE port; record whether it's bonded with the 2.5GbE ports, what
  IP it uses, and which port is connected to which LAN switch. -->

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
3-node homelab; raise as a separate project if the threat model
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

## 5. (Optional, deferred) Additional shares

Likely future shares; not required for the cluster's current scope:

- **`proxmox-iso`** — `/volume1/proxmox-iso`, mounted on all nodes,
  registered in Proxmox as `nas-iso` content type `iso,vztmpl`. Lets
  the per-node ISO libraries (currently `local`) go away.
- **`proxmox-backup`** — `/volume1/proxmox-backup`, registered with
  content type `backup`. Pairs with a `vzdump` schedule. Cluster-wide
  backup target.
- **`obsidian-vault-mirror`** — read-only mirror of the workstation's
  Obsidian vault; not a homelab-cluster concern.

Each one is repeat the steps 2 + 3 above with a different folder
name. Add the corresponding `nas_*_export` fields to inventory and a
follow-on `pvesm add nfs` invocation. Don't pre-create empty shares
"in case I need them later" — wait for a concrete consumer.

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
