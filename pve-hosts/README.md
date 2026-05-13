# pve-hosts — layer-0 Proxmox VE host bootstrap

Ansible role that configures the three NUCs running Proxmox VE to a known-good baseline. This is **layer 0**: it runs against the hypervisor hosts themselves, not against any VM. The VM provisioning under `vms/<role>/` sits on top of this layer.

## Status

Role implemented — first run pending against real hardware. See [`CLAUDE.md`](CLAUDE.md) for the original spec and [`ansible/roles/pve-host/SCAFFOLD-NOTES.md`](ansible/roles/pve-host/SCAFFOLD-NOTES.md) for what was generated, the assumptions baked in, and the items Brian still needs to fill into `inventory.yml` before applying.

The install-time procedure that produces "a freshly-installed PVE 9.x host" — USB media prep, BIOS prerequisites, installer click-through, the `nuc12-fast` LVM-thin carve-out on `pve12t`, and TB4 cabling — lives in [`docs/proxmox-install.md`](../docs/proxmox-install.md). Read that first if you're rebuilding from scratch.

Before the first apply the NAS-side NFS export also has to exist — the role's `nfs.yml` task will fail otherwise. See [`docs/asustor-nas-setup.md`](../docs/asustor-nas-setup.md) for the Asustor ADM-side setup (NFS enablement, shared folder, export ACL with `no_root_squash` + `sync`).

## What the role does

Brings a freshly-installed Proxmox VE 9.x host (Debian 13 / trixie base) to a configured baseline:

- Switches APT from the enterprise repo to no-subscription (deb822 format).
- Installs a baseline package set useful for a hypervisor operator (`ifupdown2`, `iperf3`, `ethtool`, `chrony`, `tmux`, etc.).
- Configures `chrony` against Cloudflare + NTP pool; disables `systemd-timesyncd`.
- Templates `/etc/hosts`, `/etc/network/interfaces`, and the Thunderbolt overlay (systemd `.link` files + module loading + `ip_forward` on the transit node).
- Mounts the Asustor NFS share at `/mnt/nas-vms`.
- Drops a baseline `pve-firewall` cluster config.
- Installs the operator's SSH public key for `root`.
- Tunes sysctl for high-MTU TB-net flows.

## What the role does NOT do

Out of scope, deliberately. These have quorum or hardware risks that don't belong in declarative automation:

- Update BIOS to latest version
- The cluster join ceremony (`pvecm create` / `pvecm add`).
- Edits to `/etc/pve/corosync.conf` after initial cluster setup (pmxcfs propagates that file across nodes; touching it from multiple places fights the cluster).
- Storage definitions in `/etc/pve/storage.cfg` (same reason).
- VM configs — those are owned by OpenTofu under `vms/`.
- PCIe passthrough for the eGPU on `pve12t` — covered in `docs/proxmox-gpu-passthrough.md`.
- Drive partitioning, LUKS partition creation, or GRUB edits.

If something here implies one of those, surface it as a manual step in the role's output rather than doing it.

## Folder layout

```
pve-hosts/
├── README.md                          # this file
├── CLAUDE.md                          # AI-agent spec for filling in the role
└── ansible/
    ├── site.yml                       # top-level play
    ├── inventory.yml.example          # template inventory (3 nodes with placeholders)
    ├── requirements.yml               # Galaxy collections
    └── roles/
        └── pve-host/
            ├── defaults/main.yml
            ├── vars/main.yml
            ├── tasks/
            │   ├── main.yml
            │   ├── repo.yml
            │   ├── packages.yml
            │   ├── time.yml
            │   ├── hosts_file.yml
            │   ├── network.yml
            │   ├── thunderbolt.yml
            │   ├── nfs.yml
            │   ├── firewall.yml
            │   ├── users.yml
            │   └── tuning.yml
            ├── handlers/main.yml
            ├── templates/
            ├── files/
            └── meta/main.yml
```

## Quick start (once the role is implemented)

1. Copy the inventory template and fill in real values:
   ```bash
   cp pve-hosts/ansible/inventory.yml.example pve-hosts/ansible/inventory.yml
   $EDITOR pve-hosts/ansible/inventory.yml
   ```
   Look for `# TODO` markers — LAN IPs, NAS IP, your SSH pubkey. TB `pci_path` values are NOT declared here; the role discovers them from sysfs on first apply (see `tasks/thunderbolt.yml` step (c)).

2. Install collections (one-time per workstation):
   ```bash
   just pve-hosts-deps
   ```

3. Dry-run against all three nodes:
   ```bash
   just pve-hosts-check
   ```

4. Apply:
   ```bash
   just pve-hosts
   ```

5. After the play reports `network` template changes, reload networking **from console** (not over SSH — TB interface name changes can drop the connection):
   ```bash
   ifreload -a
   ```

## Post-baseline manual steps

The role gets each host to baseline. Several follow-ups remain operator-driven — they have quorum, GRUB, or reboot risk that doesn't fit declarative automation:

1. **Cluster join (all three nodes, one-time).** Full runbook in [`docs/cluster-bring-up.md`](../docs/cluster-bring-up.md) — covers `pvecm create homelab` on pve12t, `pvecm add` on the joiners, corosync ring1 over the TB fabric, pmxcfs replication verification, and recovery from common failures. Manual + quorum-aware; never automated. The architecture rationale is in the vault doc `[[VM Mobility — 3-Node Cluster on 2.5GbE]]`.

2. **TB fabric end-to-end verification.** The initial `ifreload -a` happened in Quick-start step 5; this is the *post-cluster* validation pass. Force-migrate tests need cluster quorum to be meaningful, which is why this lands after step 1. Run the iperf3 + force-migrate suite from the vault doc `[[Thunderbolt Mesh Networking — 3-Node Cluster Option]]` (Phase 6 + Phase 8 of its bring-up runbook).

3. **Cluster-wide `pve-firewall` enable.** The role drops the cluster.fw template via `delegate_to` on a single node, with `enable: 0` so the firewall is staged-but-inert pre-cluster. After Step 1 lands, pmxcfs replicates cluster.fw to all nodes and you can safely turn it on — either via the UI (Datacenter → Firewall → Options → Enable, which writes `enable: 1` to cluster.fw) or directly editing `/etc/pve/firewall/cluster.fw` on any node. Verify SSH still works to all nodes before walking away. Pre-cluster enabling produces asymmetric state (delegate filters, peers don't, TB transit breaks) — discovered 2026-05-13.

4. **Enable `snippets` content type on `local`.** Required before the first `tofu apply` — without it, the `bpg/proxmox` provider's snippet upload silently no-ops, `cicustom` references a non-existent file, and VMs boot with no cloud-init customization (caught us 2026-05-10; see `scripts/preflight.sh`). The repo's tooling defaults `snippets_storage = "local"`; Proxmox doesn't enable the `snippets` content type on `local` by default.

   ```bash
   # On any cluster member after join (storage.cfg replicates via pmxcfs):
   pvesm set local --content snippets,iso,vztmpl,backup,images,rootdir
   ```

   Or UI: Datacenter → Storage → `local` → Edit → Content → check "Snippets". The role doesn't manage `/etc/pve/storage.cfg` — pmxcfs-replicated; writing from N hosts is a race (see `CLAUDE.md` § "What this role MUST NOT do"). `snippets` on `nas-vms` is handled in step 5's registration command.

5. **NFS storage registration in Proxmox** (also enables `snippets` on the share). Register the NFS export at `/mnt/nas-vms` as cluster storage `nas-vms`. Include `snippets` in `--content` from the start so cluster-mobile VMs whose snippet sits on shared storage stay reachable post-live-migration:

   ```bash
   pvesm add nfs nas-vms --server <nas-ip> --export /volume1/proxmox-vms \
       --content images,backup,snippets --options vers=4.2
   ```

   Or UI: Datacenter → Storage → Add → NFS, tick `Disk image`, `VZDump backup file`, and `Snippets` under Content. The role mounts the NFS share at the filesystem level (`/mnt/nas-vms`); this tells Proxmox's storage layer about it. If you used the UI and forgot the Snippets tick, fix with `pvesm set nas-vms --content snippets,images,backup`.

6. **Proxmox API users + tokens (Packer + OpenTofu).** Required before any Packer build or OpenTofu apply against the cluster. Two separate users with least-privilege roles:
   - **Packer** — see [`docs/proxmox-permissions.md`](../docs/proxmox-permissions.md). User `packer@pve` + role `packer-build`, token name `builder`. Used by `packer build` to create the universal Ubuntu/Windows base templates.
   - **OpenTofu** — see [`docs/proxmox-tofu-permissions.md`](../docs/proxmox-tofu-permissions.md). User `tofu@pve` + role `tofu-provision` (Packer's role minus `VM.Config.CDROM` and `VM.Console`). Used by `tofu apply` to clone templates into per-role VMs.

   Run **once on any cluster member after join** — `pveum` users + tokens + ACLs are stored in `/etc/pve/`, which pmxcfs replicates cluster-wide. Pre-cluster the docs describe a per-node flow; post-cluster it's a single setup. Token secrets land in your KeePassXC vault; the workstation's `hydrate.sh` reads them at apply time.

7. **eGPU passthrough plumbing on `pve12t` (one-time, then forget).** The Razer Core X + RTX 3090 passthrough to the LLM VM is **not covered by this role** — vfio module loading, IOMMU kernel parameters via GRUB, modprobe driver-binding options, and the per-VM PCI passthrough config. **After the baseline is applied on `pve12t`, follow `docs/proxmox-gpu-passthrough.md` (and the vault doc `[[NUC12-Proxmox-eGPU-Passthrough]]`) to plumb it through.** Requires reboots and GRUB edits; out of scope for the Ansible role for stability reasons (see `CLAUDE.md` under "What this role MUST NOT do").

## Optional follow-ups

These aren't blockers for `just pve-hosts` or for any VM deploy, but they're real manual steps and worth capturing so the inventory is complete.

- **Outbound mail destination.** The Proxmox installer prompted for an email at install time, but PVE 9.x has no SMTP relay configured by default — SMART warnings, cron output, and backup-job failure notices accumulate in `/var/spool/postfix/maildrop/` unread. To actually receive them: install + configure `postfix` in satellite mode pointing at an SMTP relay you trust (Cloudflare Email Routing, Fastmail, Gmail SMTP with an app password, or a local relay). The `pve-host` role does NOT manage mail — wire up only when the lab has a stable SMTP target.

- **Non-root `pveum` admin user for daily web UI access.** Logging into the web UI as `root@pam` works but treats every UI session as the highest-privilege identity. Convention is to add `admin@pve` (or `<name>@pam` if you make a local Linux user) with the built-in `Administrator` role and reserve `root@pam` for break-glass + Ansible's SSH path. Add via Datacenter → Permissions → Users → Add, then assign Administrator at the Datacenter level. Optional hardening; not currently in the design.

## When to run this role

- **First time on a fresh PVE install.** Brings the node to baseline before cluster join.
- **After a node reinstall** (e.g. disaster recovery). Same flow.
- **When `inventory.yml` changes** (added DNS entries, new SSH key, etc.). Re-running is idempotent on healthy nodes.

## When NOT to run this role

- During an active cluster ceremony (`pvecm create`/`pvecm add`).
- Before BIOS prerequisites are in place. See [`docs/proxmox-install.md`](../docs/proxmox-install.md#bios--uefi-prerequisites) for the install-time BIOS checklist (IOMMU on, Secure Boot off, USB-first boot order). Thunderbolt security is NOT a BIOS prereq on ASUS NUC13 / NUC12 hardware (firmware doesn't expose the setting); the role handles persistent peer-host trust via `boltctl enroll --policy=auto` in `thunderbolt.yml` step (b).
- Over SSH if network templates would change and you don't have console access. Surface a console terminal first.

## Per-node specifics

| Node | Hardware | TB role | TB ports used | Notes |
|---|---|---|---|---|
| `pve12t` | NUC12 Pro Tall, i7-1260P | leaf | 1 (the other holds the eGPU) | Hosts the LLM VM via RTX 3090 passthrough |
| `pve13m` | NUC13 Pro slim, i7-1360P | transit | 2 (both TB ports used as line midpoint) | Runs `net.ipv4.ip_forward=1` |
| `pve13t` | NUC13 Pro Tall, i7-13620H | leaf | 1 (1 TB port spare) | Highest core count; default landing spot for general workloads |

## Related

- Authoritative TB topology design and bring-up runbook: `[[Thunderbolt Mesh Networking — 3-Node Cluster Option]]` in the Obsidian vault.
- Cluster + NFS architecture: `[[VM Mobility — 3-Node Cluster on 2.5GbE]]` in the vault (filename retained for wikilink stability; doc covers the broader cluster design including the TB overlay).
- Hardware specifics: `[[Homelab Inventory]]` in the vault.
- The vault MOC `[[00-Homelab-MOC]]` is the index over all of those.
