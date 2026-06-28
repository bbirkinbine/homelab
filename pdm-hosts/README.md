# pdm-hosts — Proxmox Datacenter Manager baseline

Ansible role that configures the Proxmox Datacenter Manager (PDM) host to a known-good baseline. This is **layer 0** for the management tier: it runs against the bare-metal PDM host, not against any VM. PDM is the central pane of glass over the PVE clusters + PBS — it adds those as *remotes* and gives a unified view (overview, cross-cluster migrations, bulk actions). It holds no guest workloads and no datastore.

See [`CLAUDE.md`](CLAUDE.md) for the design spec and [`ansible/roles/pdm-host/SCAFFOLD-NOTES.md`](ansible/roles/pdm-host/SCAFFOLD-NOTES.md) for what was generated, the assumptions baked in, and what to fill into `inventory.yml` before a first apply.

This role is a slim cousin of [`pbs-hosts/`](../pbs-hosts/README.md): same layer-0 pattern (repo swap, packages, time, hosts, ufw, SSH key, opt-in UPS guardian, opt-in config self-backup), minus everything PBS-specific (no NFS datastore, no datastore/jobs/API-token tasks, no high-throughput sysctl tuning — PDM is a lightweight API proxy + web UI, not a chunk store).

The PDM ISO install that produces a "freshly-installed PDM host" — USB media, BIOS, installer click-through, hostname/IP — plus the remote/token ceremony live in [`docs/pdm-install.md`](../docs/pdm-install.md). Do the install first if you're rebuilding from scratch; come back here for the baseline, then return to that doc for adding remotes.

## What the role does

Brings a freshly-installed Proxmox Datacenter Manager host (Debian 13 / trixie base, installed from the PDM ISO) to a configured baseline:

- Switches APT from the enterprise repo (`pdm-enterprise.sources`, which 401s without a subscription) to no-subscription (deb822 format, `http://download.proxmox.com/debian/pdm` / `pdm-no-subscription`).
- Installs the minimum package set the role's own tasks need: `chrony`, `ufw`. Operator debugging tools (`htop`, `iperf3`, `tmux`, etc.) are deliberately not installed — `apt install <foo>` on demand. `nfs-common` is pulled only if you enable config-backup.
- Configures `chrony` against the same NTP targets as the rest of the lab; disables `systemd-timesyncd`.
- Templates `/etc/hosts` with the PDM host(s), the PVE cluster + PBS host(s) it manages (resolution only), and the NAS.
- Drops a baseline `ufw` config (allow SSH + the PDM web UI/API on **8443**) and enables the firewall.
- Installs the operator's SSH public key for `root`.
- Optionally installs a **UPS shutdown guardian** (opt-in) that stops the PDM API daemons and powers the host down on a UPS low-battery event — see [UPS shutdown guardian](#ups-shutdown-guardian-opt-in) below.
- Optionally installs a **PDM config self-backup** (opt-in) — mounts a NAS export and deploys a script + systemd timer that tars `/etc/proxmox-datacenter-manager` to it, so a rebuild can restore the remote list + per-remote API tokens. See [PDM config self-backup](#pdm-config-self-backup-opt-in) below.

## What the role does NOT do

Out of scope, deliberately:

- The PDM ISO install itself (USB prep, partitioning, hostname/IP entry).
- **Adding remotes.** Registering the PVE clusters + PBS as PDM remotes is a web-UI ceremony that consumes a per-remote API token from the operator's credential store — the same shape as the PVE/PBS token conventions in this repo. Manual one-time step (see [Post-baseline manual steps](#post-baseline-manual-steps)); there is deliberately no automation for it.
- TLS certificate management beyond PDM's self-signed default.
- GRUB or kernel parameter edits.
- Reboots.
- `apt upgrade` / `apt dist-upgrade`. Package state is `present`, not `latest`.

## Folder layout

```
pdm-hosts/
├── README.md                          # this file
├── CLAUDE.md                          # design spec
└── ansible/
    ├── site.yml                       # top-level play
    ├── inventory.yml.example          # template inventory (1 host with placeholders)
    ├── requirements.yml               # Galaxy collections
    └── roles/
        └── pdm-host/
            ├── defaults/main.yml
            ├── tasks/
            │   ├── main.yml
            │   ├── repo.yml
            │   ├── packages.yml
            │   ├── time.yml
            │   ├── hosts_file.yml
            │   ├── firewall.yml
            │   ├── users.yml
            │   ├── ups.yml             # opt-in UPS shutdown guardian
            │   └── config_backup.yml   # opt-in config self-backup (mounts NFS)
            ├── handlers/main.yml
            ├── templates/
            └── meta/main.yml
```

## Quick start

1. Copy the inventory template and fill in the `# TODO` markers (LAN IP, NAS IP, SSH pubkey):
   ```bash
   cp pdm-hosts/ansible/inventory.yml.example pdm-hosts/ansible/inventory.yml
   $EDITOR pdm-hosts/ansible/inventory.yml
   ```

2. Install collections (one-time per workstation):
   ```bash
   just pdm-hosts-deps
   ```

3. **Check, apply, re-check.** The role's `tasks/repo.yml` carries `check_mode: false` on the four bootstrap tasks, so `--check` performs the repo swap and refreshes the apt cache before dry-running everything downstream — the first check on a fresh host produces a meaningful diff instead of failing at `Install baseline packages`.
   ```bash
   just pdm-hosts-check    # cold host: real diff for every change downstream of repo.yml
   just pdm-hosts          # apply
   just pdm-hosts-check    # idempotency probe (changed=0 on a healthy host)
   ```

   On a host that's already been bootstrapped, the first `pdm-hosts-check` returns `changed=0` and you skip the middle step.

## Post-baseline manual steps

1. **Add the remotes.** In the PDM web UI (`https://pdm01:8443`, login `root@pam`) add each PVE cluster and PBS host as a remote with a **dedicated, scoped API token** (not the broad `root@pam` token PDM's "Create token" button auto-makes). The full procedure — creating the scoped `pdm@pve` / `pdm@pbs` identities, storing the secret in the password manager, and migrating off an auto-created root token — is in [`docs/pdm-install.md` §5](../docs/pdm-install.md). This is what makes PDM useful; it's manual and one-time.

2. **TLS cert (future).** PDM ships a self-signed cert. Migration to a cert from the offline Root CA is a separate task, shared with the PBS/PVE TLS work.

## UPS shutdown guardian (opt-in)

PDM is the lab's management plane. It holds **no data** and is **not an NFS client**, so — unlike pbs01 or the PVE nodes — it carries no data-path ordering constraint against the NAS on a power event. It only needs to power off cleanly before the NAS hard-cuts at 10%. We send it **first** for a softer reason: a central dashboard is useless mid-outage, and shedding it recovers a sliver of UPS runtime for the hosts that carry the data path.

This role can install the same autonomous guardian the `pve-host` and `pbs-host` roles use, in `pdm` mode. It is **opt-in** because it powers the host off on trigger.

**How it works.** A systemd timer runs `/usr/local/sbin/nas-ups-guardian` every ~20s, reading the UPS over the network with `upsc` (read-only). When the UPS is **on battery** and **`battery.charge` ≤ `pdm_host_ups_charge_threshold`** (default 75%), it stops the PDM API daemons (`proxmox-datacenter-api` + `proxmox-datacenter-privileged-api`), waits `pdm_host_ups_drain_grace` seconds (a short courtesy pause — there's nothing to drain), then powers the host off. On line power every poll is a no-op.

**Ordering across the lab** is a battery-charge gap, not the NUT primary/secondary handshake:

| Tier | Trigger | Action |
|---|---|---|
| pdm01 | ~75% charge | stop PDM API daemons, power off **first** |
| pbs01 | ~70% charge | drain backup/verify/GC, power off |
| PVE nodes | ~60% charge | `qm shutdown` guests, power off |
| NAS | ~10% charge (its LB flag) | powers off last |

pdm01's tier is the only one with no data-path meaning — pbs01 and the PVE nodes lead the NAS because they write to it over NFS; pdm01 leads them only by convention.

**Preconditions.** Both pdm01 **and the LAN switch** carrying this poll must be on the UPS; if the switch drops on mains failure, pdm01 can't read the UPS and nothing triggers.

**Enable it:**

1. Set the target (and optionally the threshold) in `inventory.yml`:
   ```yaml
   pdm_host_manage_ups_guardian: true
   pdm_host_ups_nut_target: "asustor@<nas-ip>"   # verify: upsc asustor@<nas-ip>
   ```
2. **Test first with a dry run** — set `pdm_host_ups_dry_run: true`, apply, then watch the journal during a simulated outage and confirm it logs the intended action without powering off:
   ```bash
   journalctl -t nas-ups-guardian -f
   systemctl list-timers nas-ups-guardian.timer
   ```
3. Flip `pdm_host_ups_dry_run: false` and re-apply once the dry run looks right.

All knobs are documented in `defaults/main.yml`. The guardian script is shared with `pve-host` and `pbs-host` (`scripts/nas-ups-guardian.sh`); the behavior split is the `GUARDIAN_MODE` env var (`pve` | `pbs` | `pdm`).

## PDM config self-backup (opt-in)

PDM ships nothing to back up its own `/etc/proxmox-datacenter-manager` (same stance as PVE and PBS). This role can mount a NAS export and deploy `scripts/pdm-config-backup.sh` plus a systemd timer that tars that directory to the NAS, so a rebuild of `pdm01` has a recent copy to restore from.

**What it buys you on a rebuild** — the config is the list of managed remotes, their per-remote API tokens + TLS fingerprints, the ACLs, and local users. Restoring it skips re-adding every remote by hand and preserves exact ACL/user state. The **DR value is lower than the PBS equivalent**: PDM holds no data, so worst case without this is a reinstall-from-ISO plus a few minutes in the web UI re-adding remotes. This is a convenience, not a safety net — leave it OFF unless PDM has accumulated enough remotes/ACLs/users to be worth the standing NFS mount + export ACL.

**Why it mounts NFS only when enabled** — PDM has no other reason to touch the NAS, so (unlike PBS, which mounts the NAS for its datastore anyway) the NFS mount is folded into this opt-in feature. A default PDM install mounts nothing and pulls no `nfs-common`.

**Why a plain tarball** — the artifact stays openable on a fresh box with nothing running (`tar xzf` from a rescue USB or your laptop). The NAS replicates it to the secondary too.

### Enable it

1. **Add the NAS export ACL.** PDM writes to the PBS backups share by default (a `host-config/` subdir). Add `pdm01`'s LAN IP to that export's ACL on the Asustor (`no_root_squash` + `sync`), or point `pdm_config_backup_nfs_export` at a dedicated export.

2. **Flip the toggle** in `inventory.yml`:
   ```yaml
   pdm_host_manage_config_backup: true
   # pdm_config_backup_nfs_export: "/volume1/proxmox-backups"   # override if needed
   # pdm_config_backup_nfs_mount: "/mnt/pdm-config"
   ```

3. **Test with a dry run first.** Set `pdm_config_backup_dry_run: true`, apply, then trigger the unit once and confirm it logs the intended actions without writing:
   ```bash
   just pdm-hosts
   ssh root@pdm01 systemctl start pdm-config-backup.service
   ssh root@pdm01 journalctl -t pdm-config-backup -n 20
   ```

4. **Flip `pdm_config_backup_dry_run: false` and re-apply.** Confirm a real tarball lands:
   ```bash
   ssh root@pdm01 ls -lh /mnt/pdm-config/host-config/
   ```

The role mounts the export, deploys the script, creates the destination dir (mode `0700` — the tarball carries API tokens), renders `/etc/default/pdm-config-backup`, and installs + enables the timer. The unit's `RequiresMountsFor` pins it to the NAS mount, so a run never silently writes to local disk if the export is down. Retention (`pdm_config_backup_keep_days`, default 30) and the schedule (`pdm_config_backup_schedule`, default `04:30` daily) are documented in `defaults/main.yml`.

### Restore after a rebuild

No key, no PDM, no credentials needed to read the backup — it's a plain tarball. After a fresh PDM install on `pdm01`:

1. **Get the tarball.** It's on the NAS at `host-config/<host>-config-<timestamp>.tar.gz`. Mount the export, `scp` it from another machine, or copy it off the secondary NAS.

2. **Stage it and review** (never extract straight over the live config):
   ```bash
   mkdir /root/restored-config
   tar -xzf <host>-config-<timestamp>.tar.gz -C /root/restored-config
   ls /root/restored-config/proxmox-datacenter-manager
   ```

3. **Stop PDM, copy the config in, restart:**
   ```bash
   systemctl stop proxmox-datacenter-api proxmox-datacenter-privileged-api
   cp -a /root/restored-config/proxmox-datacenter-manager/. /etc/proxmox-datacenter-manager/
   systemctl start proxmox-datacenter-privileged-api proxmox-datacenter-api
   ```
   With the remote definitions + tokens restored, PDM reconnects to its remotes without you re-adding them.

### Security note

The tarball contains the per-remote API tokens PDM uses to reach its remotes, so it's sensitive. It's written mode `0600` into a `0700` directory, and the NAS export is LAN-only and ACL'd to `pdm01`. The job never touches the PDM API, so there are **no** extra credentials persisted on the host for it.

## When to run this role

- **First time on a fresh PDM install.** Brings the host to baseline.
- **After a host reinstall** (disaster recovery). Same flow.
- **When `inventory.yml` changes** (new SSH key, guardian/backup toggles). Re-running is idempotent.

## When NOT to run this role

- Before BIOS prerequisites are in place (UEFI on, Secure Boot off, USB-first boot order).
- With `pdm_host_manage_config_backup: true` before the NAS export ACL allows this host — the mount task will fail.

## Per-host specifics

| Host | Role |
|---|---|
| `pdm01` | Central management plane (remotes: PVE clusters + PBS) |

Hardware: GMKtec NucBox G3 Pro — Intel Core i3-10110U (2C/4T, Comet Lake-U), 16 GB DDR4, 256 GB SATA SSD, 1× 2.5GbE. Same chassis and CPU as `pbs01`; a management plane is undemanding, so the modest spec is deliberate.

## Related

- Sibling layer-0 patterns: [`pbs-hosts/README.md`](../pbs-hosts/README.md), [`pve-hosts/README.md`](../pve-hosts/README.md).
- Ordered UPS shutdown design: vault doc `[[nut-ordered-shutdown-design]]`.
- The vault MOC `[[00-Homelab-MOC]]` is the index over the lab's architecture docs.
