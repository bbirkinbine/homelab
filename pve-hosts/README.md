# pve-hosts — layer-0 Proxmox VE host bootstrap

Ansible role that configures the three NUCs running Proxmox VE to a known-good baseline. This is **layer 0**: it runs against the hypervisor hosts themselves, not against any VM. The VM provisioning under `vms/<role>/` sits on top of this layer.

See [`CLAUDE.md`](CLAUDE.md) for the design spec and [`ansible/roles/pve-host/SCAFFOLD-NOTES.md`](ansible/roles/pve-host/SCAFFOLD-NOTES.md) for what was generated, the assumptions baked in, and the items to fill into `inventory.yml` before a first apply.

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
- Optionally installs a **UPS shutdown guardian** (opt-in) that gracefully powers the node down on a UPS low-battery event, before the NAS cuts power — see [UPS shutdown guardian](#ups-shutdown-guardian-opt-in) below.

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
    ├── inventory.yml.example          # template inventory (4 nodes with placeholders)
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

## Quick start

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

3. Dry-run against all four nodes:
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

1. **Cluster bring-up + post-formation storage/policy.** Full runbook in [`docs/cluster-bring-up.md`](../docs/cluster-bring-up.md) — covers `pvecm create homelab` on pve12t, `pvecm add` on the joiners, corosync ring1 over the TB fabric, migration-network setting, cluster-wide `pve-firewall` enable, `snippets` content type on `local`, and NFS storage registration as `nas-vms`. Manual + quorum-aware; never automated. The architecture rationale is in the vault doc `[[VM Mobility — 3-Node Cluster on 2.5GbE]]`.

2. **TB fabric end-to-end verification.** The initial `ifreload -a` happened in Quick-start step 5; this is the *post-cluster* validation pass. Force-migrate tests need cluster quorum to be meaningful, which is why this lands after step 1. Run the iperf3 + force-migrate suite from the vault doc `[[Thunderbolt Mesh Networking — 3-Node Cluster Option]]` (Phase 6 + Phase 8 of its bring-up runbook).

3. **Proxmox API users + tokens (Packer + OpenTofu).** Required before any Packer build or OpenTofu apply against the cluster. Two separate users with least-privilege roles:
   - **Packer** — see [`docs/proxmox-permissions.md`](../docs/proxmox-permissions.md). User `packer@pve` + role `packer-build`, token name `builder`. Used by `packer build` to create the universal Ubuntu/Windows base templates.
   - **OpenTofu** — see [`docs/proxmox-tofu-permissions.md`](../docs/proxmox-tofu-permissions.md). User `tofu@pve` + role `tofu-provision` (Packer's role minus `VM.Config.CDROM` and `VM.Console`). Used by `tofu apply` to clone templates into per-role VMs.

   Run **once on any cluster member after join** — `pveum` users + tokens + ACLs are stored in `/etc/pve/`, which pmxcfs replicates cluster-wide. Pre-cluster the docs describe a per-node flow; post-cluster it's a single setup. Token secrets land in your KeePassXC vault; the workstation's `hydrate.sh` reads them at apply time.

4. **eGPU passthrough plumbing on `pve12t` (one-time, then forget).** The Razer Core X + RTX 3090 passthrough to the LLM VM is **not covered by this role** — vfio module loading, IOMMU kernel parameters via GRUB, modprobe driver-binding options, and the per-VM PCI passthrough config. **After the baseline is applied on `pve12t`, follow `docs/proxmox-gpu-passthrough.md` (and the vault doc `[[NUC12-Proxmox-eGPU-Passthrough]]`) to plumb it through.** Requires reboots and GRUB edits; out of scope for the Ansible role for stability reasons (see `CLAUDE.md` under "What this role MUST NOT do").

## Optional follow-ups

These aren't blockers for `just pve-hosts` or for any VM deploy, but they're real manual steps and worth capturing so the inventory is complete.

- **Outbound mail destination.** The Proxmox installer prompted for an email at install time, but PVE 9.x has no SMTP relay configured by default — SMART warnings, cron output, and backup-job failure notices accumulate in `/var/spool/postfix/maildrop/` unread. To actually receive them: install + configure `postfix` in satellite mode pointing at an SMTP relay you trust (Cloudflare Email Routing, Fastmail, Gmail SMTP with an app password, or a local relay). The `pve-host` role does NOT manage mail — wire up only when the lab has a stable SMTP target.

- **Non-root `pveum` admin user for daily web UI access.** Logging into the web UI as `root@pam` works but treats every UI session as the highest-privilege identity. Convention is to add `admin@pve` (or `<name>@pam` if you make a local Linux user) with the built-in `Administrator` role and reserve `root@pam` for break-glass + Ansible's SSH path. Add via Datacenter → Permissions → Users → Add, then assign Administrator at the Datacenter level. Optional hardening; not currently in the design.

## UPS shutdown guardian (opt-in)

On mains failure the lab runs on an APC Back-UPS RS (BR1500MS2). The Asustor NAS is the NUT primary (the UPS is on its USB) and serves the NFS that backs both the cluster-mobile VM disks (`nas-vms`) and the PBS chunk store. The NAS auto-powers-off when the UPS hits its low-battery flag (`battery.charge.low` = 10%). Nothing stock tells the NFS clients to go first — so if the NAS cuts power while a node is mid-write, you get hung I/O and a dirty guest filesystem (or a corrupted PBS datastore).

This role can install a small, autonomous guardian that fixes the ordering. It is **opt-in** because it powers the host off on trigger.

**How it works.** A systemd timer runs `/usr/local/sbin/nas-ups-guardian` every ~20s. Each poll reads the UPS over the network with `upsc` (read-only; no upsd user provisioning on the NAS). When the UPS is **on battery** and **`battery.charge` ≤ `pve_host_ups_charge_threshold`** (default 50%), it gracefully `qm shutdown`s every running guest on that node, force-stops any straggler, then powers the node off. On line power every poll is a no-op, so the timer firing during an Ansible apply is harmless.

**Ordering across the lab** is a battery-charge gap, not the NUT primary/secondary handshake (the Asustor upsd does not wait for network clients):

| Tier | Trigger | Action |
|---|---|---|
| pbs01 | ~60% charge | drain backup/verify/GC, power off first (highest-value NFS client — see `pbs-hosts/README.md`) |
| PVE nodes | ~50% charge | `qm shutdown` guests, power off |
| NAS | ~10% charge (its LB flag) | powers off last |

Shutting the PVE guests — the LLM VM especially — also collapses the GPU load, which makes the UPS recompute runtime upward and widens the margin for everything downstream.

**Preconditions.** Both the node **and the LAN switch** carrying this poll must be on the UPS; if the switch drops on mains failure, no node can read the UPS and nothing triggers. Corosync ring0 rides the same switch, so it is likely already on the UPS — confirm it.

**Enable it:**

1. Set the target and (optionally) the threshold in `inventory.yml`:
   ```yaml
   pve_host_manage_ups_guardian: true
   pve_host_ups_nut_target: "asustor@<nas-ip>"   # verify: upsc asustor@<nas-ip>
   ```
2. **Test first with a dry run** — set `pve_host_ups_dry_run: true`, apply, then simulate an outage (pull mains, or watch a real one) and confirm the journal logs the intended sweep without powering anything off:
   ```bash
   journalctl -t nas-ups-guardian -f
   systemctl list-timers nas-ups-guardian.timer
   ```
3. Flip `pve_host_ups_dry_run: false` and re-apply once the dry run looks right.

All knobs (`pve_host_ups_charge_threshold`, `pve_host_ups_shutdown_timeout`, `pve_host_ups_exclude_vmids`, `pve_host_ups_comms_loss_action`, poll cadence) are documented in `defaults/main.yml`. Note `pve_host_ups_exclude_vmids` is empty by design: for an unattended outage you want everything — amp-game included — down gracefully via guest agent rather than NFS-yanked.

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
