# pbs-hosts — Proxmox Backup Server baseline

Ansible role that configures the dedicated PBS host(s) to a known-good baseline. This is **layer 0** for the backup tier: it runs against the bare-metal PBS hardware, not against any VM. The PVE-side storage registration (`pvesm add pbs ...`) sits on top of this layer.

See [`CLAUDE.md`](CLAUDE.md) for the design spec and [`ansible/roles/pbs-host/SCAFFOLD-NOTES.md`](ansible/roles/pbs-host/SCAFFOLD-NOTES.md) for what was generated, the assumptions baked in, and what to fill into `inventory.yml` before a first apply.

The install-time procedure that produces a "freshly-installed PBS 4.x host" — USB media, BIOS, installer click-through — lives in [`docs/pbs-install.md`](../docs/pbs-install.md). Read that first if you're rebuilding from scratch.

Before the first apply the NAS-side NFS export for the bulk datastore has to exist (separate share from `proxmox-vms`; see [`docs/asustor-nas-setup.md` § 5](../docs/asustor-nas-setup.md#5-export-for-the-pbs-bulk-datastore)) — `nfs.yml` fails otherwise.

## What the role does

Brings a freshly-installed Proxmox Backup Server 4.x host (Debian 13 / trixie base) to a configured baseline:

- Switches APT from the enterprise repo to no-subscription (deb822 format).
- Installs the minimum package set required by downstream tasks in this role: `chrony`, `ufw`, `nfs-common`. Operator debugging tools (`htop`, `iperf3`, `tmux`, `dnsutils`, `tcpdump`, etc.) are deliberately not installed — `apt install <foo>` on demand if needed on a specific host.
- Configures `chrony` against the same NTP targets as the PVE cluster; disables `systemd-timesyncd`.
- Templates `/etc/hosts` with the PBS host(s), the PVE cluster, and the NAS.
- Mounts the Asustor NFS export at `/mnt/pbs-bulk` for the bulk datastore.
- Creates datastores via `proxmox-backup-manager`.
- Asserts the operator-created `pveingress@pbs!cluster` API token exists, and grants it the `DatastoreAdmin` role on each datastore (the role does NOT create the user or token — see Quick start). `DatastoreAdmin` not the narrower `DatastoreBackup` because PVE's `pvesm add pbs` validation requires `Datastore.Audit`; see [`ansible/roles/pbs-host/defaults/main.yml`](ansible/roles/pbs-host/defaults/main.yml) for the full rationale.
- Schedules verify + prune + GC jobs per datastore.
- Drops a baseline `ufw` config and enables the firewall.
- Installs the operator's SSH public key for `root`.
- Tunes sysctl for high-throughput chunk transfers.
- Optionally installs a **UPS shutdown guardian** (opt-in) that drains in-flight backup/verify/GC and powers the host down on a UPS low-battery event, before the NAS cuts power — see [UPS shutdown guardian](#ups-shutdown-guardian-opt-in) below.

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

3. **Manual prereq before first apply — create the PVE-ingress API user + token in the PBS web UI, then store the secret in KeePassXC.** The role asserts both exist and fails loudly with a runbook pointer if not. Convention matches the PVE-side `tofu@pve` / `packer@pve` tokens: operator-created, KeePassXC-stored, never read by the create-time tool.

   **Three names you'll see in this step — they look alike, but each lives in a different namespace. Keep them straight:**

   - **PBS User ID** = `pveingress` (bare, no suffix). With the `@pbs` realm appended, PBS internally identifies it as `pveingress@pbs`. This is what you type in step 3b's User Management → Add → User ID field.
   - **PBS Token Name** = `cluster`. The full PBS auth-id becomes `pveingress@pbs!cluster`. This is what you type in step 3c's API Tokens → Add → Token Name field.
   - **KeePassXC entry title** = `pveingress-cluster`. The hyphenated form is purely a label on your side — PBS doesn't know or care about it. It hyphenates User ID + Token Name only because that's a useful organizational handle for *you*.

   Most common failure mode: typing the hyphenated form (`pveingress-cluster`) into PBS's User Management → User ID field. PBS then has a user named `pveingress-cluster@pbs` instead of `pveingress@pbs`, the role's assert fails with `Required PBS user pveingress@pbs not found`, and you have to delete + recreate the user (which also wipes its tokens).

   a. PBS web UI: `https://pbs01:8007` (login `root@pam` with the install password).
   b. **Configuration → Access Control → User Management → Add**
      - User ID: `pveingress`
      - Realm: `Proxmox Backup authentication server` (`@pbs`)
      - Password / Confirm: PBS 4.x's UI **requires** a password here even for service identities. In KeePassXC, create a new entry first at `Homelab/PBS/pveingress-cluster` and use its dice icon to generate a random 32-char password — that becomes the entry's **Password** field. Paste the same value into both PBS form fields. The PVE cluster authenticates via the *token* (separate code path), so this password is never used at runtime, but you keep it in KP for completeness and future rotation. Leave the user **Enabled** — disabling the parent user also disables its tokens on PBS, so the belt-and-suspenders pattern from other systems doesn't apply here.
      - Email: leave blank.
   c. **Configuration → Access Control → API Tokens → Add**
      - User: `pveingress@pbs`
      - Token Name: `cluster`
      - Privilege Separation: **keep checked**. The role grants the configured role on both the parent user and the token — PBS 4.x privsep is intersection-based (token effective perms = user ∩ token), so a token-only grant gives zero effective perms. Granting both keeps a token-scoped ACL entry that can be revoked separately from the user.
   d. PBS shows the secret value ONCE in a modal. Open the existing KeePassXC entry `Homelab/PBS/pveingress-cluster` (created in step 3b) and paste the **full token string** `pveingress@pbs!cluster=<secret>` into its **Notes** field — matching the `tofu@pve!apply=<secret>` format documented in [`docs/opentofu-setup.md` § 3](../docs/opentofu-setup.md#3-keepassxc--hydrate). You construct the full string yourself by concatenating the auth-id (User + `!` + Token Name from the form you just filled) with `=` and the secret PBS displays.

      Two fields end up on the same entry:

      - `Homelab/PBS/pveingress-cluster` →
        - **Password** field: the random PBS UI password from step 3b. Kept for completeness/rotation; never read at runtime.
        - **Notes** field: the full `pveingress@pbs!cluster=<secret>` string. Same format the openbao/rootca flow uses for `Homelab/Tofu/proxmox-api-token` (Password field there, since that entry has no UI-password to coexist with). For PBS the value lives in Notes because the entry's Password is already claimed by the UI password.

   No password-quality choice for the secret: PBS generated it server-side (≈32 random bytes), same as Proxmox API tokens. The KP entry will be consumed by the future PVE-side `pvesm add pbs ...` play via [scripts/hydrate.sh](../scripts/hydrate.sh) using `kp://Homelab/PBS/pveingress-cluster#Notes`; that play splits the `<tokenid>=<secret>` at `=` to feed `pvesm`'s `--username` and `--password` flags. The `pbs-host` role itself never reads the secret — only the auth-id, which is non-secret.

4. **Check, apply, re-check.** The role's `tasks/repo.yml` carries `check_mode: false` on the four bootstrap tasks, so `--check` actually performs the repo swap and refreshes the apt cache before dry-running everything downstream. That means the first check on a fresh host produces a meaningful diff for every change the role would make, instead of failing at `Install baseline packages`.
   ```bash
   just pbs-hosts-check    # cold host: real diff for every change downstream of repo.yml
   just pbs-hosts          # apply
   just pbs-hosts-check    # idempotency probe (changed=0 on a healthy host)
   ```

   On a host that's already been bootstrapped, the first `pbs-hosts-check` returns `changed=0` and you skip the middle step. If step 3 wasn't completed, the play fails at the user/token assert with a clear pointer back to it.

5. **Next — register PBS as a PVE storage target.** The role bootstrapped `pbs01`'s host config + datastore, but the PVE cluster doesn't know about it yet. Return to [`docs/0-scratch-build-order.md` step 7f](../docs/0-scratch-build-order.md#phase-25--backup-target-pbs) for the full `pvesm add pbs ...` runbook (manual, one-time per cluster — there's no automation for it, deliberately). Until that's done, PVE backup jobs can't target this PBS host.

## Post-baseline manual steps

1. **PVE-side storage registration.** See [`docs/0-scratch-build-order.md` step 7f](../docs/0-scratch-build-order.md#phase-25--backup-target-pbs) for the canonical `pvesm add pbs ...` invocation + where to source the token secret and cert fingerprint. Stored in `/etc/pve/storage.cfg`, pmxcfs-replicated — scope to one node. (Web-UI equivalent: Datacenter → Storage → Add → Proxmox Backup Server.)

2. **Schedule a PVE backup job.** Datacenter → Backup → Add. Pick VMs, set retention, optionally encrypt with a key from OpenBao.

3. **TLS cert migration (future).** PBS ships a self-signed cert; PVE pins it by fingerprint. Migration to a cert from the offline Root CA (`[[CardLogix as Offline Root CA]]`) is a separate task.

## UPS shutdown guardian (opt-in)

`pbs01` is the **highest-value NFS client** on the lab's UPS. Its datastore (the `proxmox-backups` export) is the disaster-recovery tier, and PBS runs long, NFS-heavy operations — garbage collection and verify rewrite/read the chunk-store index independent of any PVE VM. If the Asustor NAS (the NUT primary, on the UPS's USB) auto-powers-off at its low-battery flag while a GC is mid-write, it can corrupt the datastore — the one store you'd recover *from*. So on a power event pbs01 must shut down cleanly, and **first**.

This role can install the same autonomous guardian the `pve-host` role uses, in `pbs` mode. It is **opt-in** because it powers the host off on trigger.

**How it works.** A systemd timer runs `/usr/local/sbin/nas-ups-guardian` every ~20s, reading the UPS over the network with `upsc` (read-only; no upsd user provisioning on the NAS). When the UPS is **on battery** and **`battery.charge` ≤ `pbs_host_ups_charge_threshold`** (default 70%), it stops `proxmox-backup-proxy` to halt new work, waits `pbs_host_ups_drain_grace` seconds for in-flight chunk writes to settle, then powers the host off. The subsequent orderly stop aborts any still-running task and unmounts NFS cleanly while the NAS is still up. PBS is crash-consistent and GC/verify are resumable, so the guardian does **not** wait for a long task to finish — aborting it is safe and preserves battery margin. On line power every poll is a no-op.

**Ordering across the lab** is a battery-charge gap, not the NUT primary/secondary handshake (the Asustor upsd does not wait for network clients):

| Tier | Trigger | Action |
|---|---|---|
| pbs01 | ~70% charge | drain backup/verify/GC, power off **first** |
| PVE nodes | ~60% charge | `qm shutdown` guests, power off |
| NAS | ~10% charge (its LB flag) | powers off last |

pbs01 triggers above the PVE 60% on purpose: it is the priority asset and a winding-down GC/verify gets runway to settle before the battery gets tight. Backups run daily with a 30-day retention window, so an early exit costs nothing — an aborted task resumes on the next run.

**Preconditions.** Both pbs01 **and the LAN switch** carrying this poll must be on the UPS; if the switch drops on mains failure, pbs01 can't read the UPS and nothing triggers.

**Enable it:**

1. Set the target and (optionally) the threshold in `inventory.yml`:
   ```yaml
   pbs_host_manage_ups_guardian: true
   pbs_host_ups_nut_target: "asustor@<nas-ip>"   # verify: upsc asustor@<nas-ip>
   ```
2. **Test first with a dry run** — set `pbs_host_ups_dry_run: true`, apply, then watch the journal during a simulated outage and confirm it logs the intended drain without powering off:
   ```bash
   journalctl -t nas-ups-guardian -f
   systemctl list-timers nas-ups-guardian.timer
   ```
3. Flip `pbs_host_ups_dry_run: false` and re-apply once the dry run looks right.

All knobs (`pbs_host_ups_charge_threshold`, `pbs_host_ups_drain_grace`, `pbs_host_ups_comms_loss_action`, poll cadence) are documented in `defaults/main.yml`. The guardian script is shared with `pve-host` (`scripts/nas-ups-guardian.sh`); the PBS-vs-PVE behavior split is the `GUARDIAN_MODE` env var.

## When to run this role

- **First time on a fresh PBS install.** Brings the host to baseline.
- **After a host reinstall** (disaster recovery). Same flow.
- **When `inventory.yml` changes** (new datastore, new SSH key). Re-running is idempotent.

## When NOT to run this role

- Before BIOS prerequisites are in place (UEFI on, Secure Boot off, USB-first boot order). See [`docs/pbs-install.md`](../docs/pbs-install.md).
- Before the NAS-side NFS export exists — `nfs.yml` will fail with no useful diagnostic.

## Per-host specifics

| Host | Role |
|---|---|
| `pbs01` | Primary backup target for the PVE cluster |

Hardware specs: [`docs/pbs-install.md` § Per-host specifics](../docs/pbs-install.md#per-host-specifics). Selection rationale: vault doc `[[Proxmox Backup Server — Capabilities and Tiered Storage]]` § "PBS host hardware".

## Related

- Authoritative PBS architecture + tiering: `[[Proxmox Backup Server — Capabilities and Tiered Storage]]` in the Obsidian vault.
- NAS setup: `[[NAS Offsite Backup Strategy]]` in the vault.
- Cluster + NFS architecture: `[[VM Mobility — 3-Node Cluster on 2.5GbE]]`.
- Hardware specifics: `[[Homelab Inventory]]`.
- Sibling layer-0 pattern: [`pve-hosts/README.md`](../pve-hosts/README.md).
- The vault MOC `[[00-Homelab-MOC]]` is the index over all of these.
