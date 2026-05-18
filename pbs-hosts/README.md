# pbs-hosts — Proxmox Backup Server baseline

Ansible role that configures the dedicated PBS host(s) to a known-good baseline. This is **layer 0** for the backup tier: it runs against the bare-metal PBS hardware, not against any VM. The PVE-side storage registration (`pvesm add pbs ...`) sits on top of this layer.

See [`CLAUDE.md`](CLAUDE.md) for the design spec and [`ansible/roles/pbs-host/SCAFFOLD-NOTES.md`](ansible/roles/pbs-host/SCAFFOLD-NOTES.md) for what was generated, the assumptions baked in, and what to fill into `inventory.yml` before a first apply.

The install-time procedure that produces a "freshly-installed PBS 4.x host" — USB media, BIOS, installer click-through — lives in [`docs/pbs-install.md`](../docs/pbs-install.md). Read that first if you're rebuilding from scratch.

Before the first apply the NAS-side NFS export for the bulk datastore has to exist (separate share from `proxmox-vms`; see [`docs/asustor-nas-setup.md` § 5](../docs/asustor-nas-setup.md#5-export-for-the-pbs-bulk-datastore)) — `nfs.yml` fails otherwise.

## What the role does

Brings a freshly-installed Proxmox Backup Server 4.x host (Debian 13 / trixie base) to a configured baseline:

- Switches APT from the enterprise repo to no-subscription (deb822 format).
- Installs a baseline package set useful for a PBS operator (`chrony`, `htop`, `iperf3`, `tmux`, `ufw`, `nfs-common`, etc.).
- Configures `chrony` against the same NTP targets as the PVE cluster; disables `systemd-timesyncd`.
- Templates `/etc/hosts` with the PBS host(s), the PVE cluster, and the NAS.
- Mounts the Asustor NFS export at `/mnt/pbs-bulk` for the bulk datastore.
- Creates datastores via `proxmox-backup-manager` and applies per-datastore prune policy.
- Creates an API user + token for PVE backup ingress; surfaces the token secret once for the operator to paste into KeePassXC.
- Schedules verify + GC jobs per datastore.
- Drops a baseline `ufw` config and enables the firewall.
- Installs the operator's SSH public key for `root`.
- Tunes sysctl for high-throughput chunk transfers.

## What the role does NOT do

Out of scope, deliberately. These have install-time, hardware, or operator-state risk that doesn't belong in declarative automation:

- The PBS ISO install itself (USB prep, partitioning, hostname/IP entry).
- PVE-side configuration. Adding the PBS server as a storage target on the PVE cluster lives in [`docs/cluster-bring-up.md`](../docs/cluster-bring-up.md); it's a one-time `pvesh create /storage` (or UI) action scoped to a single PVE node because `/etc/pve/storage.cfg` is pmxcfs-replicated.
- TLS certificate management beyond PBS's self-signed default. The eventual migration to a cert from the offline Root CA on the CardLogix HSM pair (see vault doc `[[CardLogix as Offline Root CA]]`) is a future task tracked in `docs/pbs-tls-migration.md` (TBD).
- GRUB or kernel parameter edits.
- Drive partitioning or LUKS. Both datastore paths assume their underlying filesystem already exists (NFS mount for the bulk datastore, a pre-existing local filesystem for the optional fast datastore).
- Reboots.
- `apt upgrade` / `apt dist-upgrade`. Package state is `present`, not `latest`.

## Folder layout

```
pbs-hosts/
├── README.md                          # this file
├── CLAUDE.md                          # AI-agent spec for filling in the role
└── ansible/
    ├── site.yml                       # top-level play
    ├── inventory.yml.example          # template inventory (1 host with placeholders)
    ├── requirements.yml               # Galaxy collections
    └── roles/
        └── pbs-host/
            ├── defaults/main.yml
            ├── vars/main.yml
            ├── tasks/
            │   ├── main.yml
            │   ├── repo.yml
            │   ├── packages.yml
            │   ├── time.yml
            │   ├── hosts_file.yml
            │   ├── nfs.yml
            │   ├── tuning.yml
            │   ├── firewall.yml
            │   ├── users.yml
            │   ├── pbs_datastore.yml
            │   ├── pbs_users.yml
            │   └── pbs_jobs.yml
            ├── handlers/main.yml
            ├── templates/
            └── meta/main.yml
```

## Quick start

1. Copy the inventory template and fill in the `# TODO` markers (LAN IP, NAS IP, SSH pubkey, datastore names):
   ```bash
   cp pbs-hosts/ansible/inventory.yml.example pbs-hosts/ansible/inventory.yml
   $EDITOR pbs-hosts/ansible/inventory.yml
   ```

2. Install collections (one-time per workstation):
   ```bash
   just pbs-hosts-deps
   ```

3. Dry-run, then apply:
   ```bash
   just pbs-hosts-check
   just pbs-hosts
   ```

4. Capture the API token secret printed by the play into KeePassXC under `pbs01 / pveingress@pbs!cluster`. PBS never re-emits the cleartext secret — if you miss it, regenerate via `proxmox-backup-manager user delete-token` + re-run.

## Post-baseline manual steps

1. **PVE-side storage registration.** Datacenter → Storage → Add → Proxmox Backup Server (or one-time `pvesh` from any cluster member). Uses the token from `pbs_users.yml`. Stored in `/etc/pve/storage.cfg`, pmxcfs-replicated — scope to one node.

2. **Schedule a PVE backup job.** Datacenter → Backup → Add. Pick VMs, set retention, optionally encrypt with a key from OpenBao.

3. **TLS cert migration (future).** PBS ships a self-signed cert; PVE pins it by fingerprint. Migration to a cert from the offline Root CA (`[[CardLogix as Offline Root CA]]`) is a separate task.

## When to run this role

- **First time on a fresh PBS install.** Brings the host to baseline.
- **After a host reinstall** (disaster recovery). Same flow.
- **When `inventory.yml` changes** (new datastore, new SSH key). Re-running is idempotent.

## When NOT to run this role

- Before BIOS prerequisites are in place (UEFI on, Secure Boot off, USB-first boot order). See [`docs/pbs-install.md`](../docs/pbs-install.md).
- Before the NAS-side NFS export exists — `nfs.yml` will fail with no useful diagnostic.

## Per-host specifics

| Host | Hardware | Role |
|---|---|---|
| `pbs01` | GMKtec G3 Pro Mini PC — Intel Core i3-10110U, 16 GB DDR4, 512 GB NVMe, 2.5GbE | Primary backup target for the PVE cluster |

Hardware selection rationale lives in the vault doc `[[Proxmox Backup Server — Capabilities and Tiered Storage]]` § "PBS host hardware".

## Related

- Authoritative PBS architecture + tiering: `[[Proxmox Backup Server — Capabilities and Tiered Storage]]` in the Obsidian vault.
- NAS setup: `[[NAS Offsite Backup Strategy]]` in the vault.
- Cluster + NFS architecture: `[[VM Mobility — 3-Node Cluster on 2.5GbE]]`.
- Hardware specifics: `[[Homelab Inventory]]`.
- Sibling layer-0 pattern: [`pve-hosts/README.md`](../pve-hosts/README.md).
- The vault MOC `[[00-Homelab-MOC]]` is the index over all of these.
