# pbs-host — scaffold notes

Implementation notes for the `pbs-host` Ansible role, generated against the spec in `pbs-hosts/CLAUDE.md`. Captures what was produced, the assumptions baked in, what Brian still needs to fill in before the first apply, and the validation outcomes.

Layer-0 spec lives in [`pbs-hosts/CLAUDE.md`](../../../CLAUDE.md). The role's user-facing entry point is [`pbs-hosts/README.md`](../../../README.md). Read both first.

---

## Files generated

```text
roles/pbs-host/
├── defaults/main.yml                       # overridable knobs (packages, NFS opts, firewall toggle, prune defaults, schedules)
├── vars/main.yml                           # role-internal constants (proxmox-backup-manager binary path)
├── meta/main.yml                           # Galaxy metadata + collection deps (ansible.posix, community.general)
├── handlers/main.yml                       # reload-systemd / apt-update / restart-chrony / apply-sysctl / reload-ufw
├── tasks/
│   ├── main.yml                            # asserts + ordered import_tasks pipeline
│   ├── repo.yml                            # remove pbs-enterprise.{list,sources} + write deb822 pbs-no-subscription
│   ├── packages.yml                        # baseline package set from defaults (ufw, nfs-common, chrony, jq, etc.)
│   ├── time.yml                            # mask timesyncd, install chrony.conf, start chrony
│   ├── hosts_file.yml                      # render /etc/hosts from pbs_hosts + pve_hosts mirror + NAS
│   ├── tuning.yml                          # 99-pbs-host.conf sysctl drop-in (TCP buffer ceilings + wider ephemeral range)
│   ├── nfs.yml                             # mount Asustor PBS bulk NFS at /mnt/pbs-bulk
│   ├── firewall.yml                        # ufw default-deny + LAN-subnet allow for 22/8007/icmp
│   ├── users.yml                           # operator SSH pubkey for root@<host>
│   ├── pbs_datastore.yml                   # create datastores via proxmox-backup-manager + apply prune policy
│   ├── pbs_users.yml                       # asserts operator-created PVE-ingress user + token, grants DatastoreAdmin ACL
│   └── pbs_jobs.yml                        # per-datastore verify-job + GC schedule
└── templates/etc/
    ├── apt/sources.list.d/pbs-no-subscription.sources.j2
    ├── chrony/chrony.conf.j2
    ├── hosts.j2
    └── sysctl.d/99-pbs-host.conf.j2
```

Outside the role itself, the repo gained:

- `Justfile`: `pbs-hosts-deps`, `pbs-hosts`, `pbs-hosts-check`, `pbs-hosts-one host=<name>` recipes (mirroring the existing `pve-hosts-*` set).
- `.gitignore`: `pbs-hosts/ansible/inventory.yml`, `*.retry`, `.ansible_galaxy` were already present from the scaffold pass.
- `README.md` (root): one-line PBS row added to the tech-stack table.
- `docs/pbs-install.md`: new install runbook (USB media, BIOS, ISO walkthrough, post-install verification) — parallel to `docs/proxmox-install.md`.
- `docs/asustor-nas-setup.md`: extended with the dedicated `/volume1/proxmox-backups` export for the PBS bulk datastore (separate from the existing `proxmox-vms` export used by `pve-hosts`).
- `docs/0-scratch-build-order.md`: added a PBS phase between cluster bring-up and first VM deploy.

---

## Assumptions beyond the spec

These are choices made where `CLAUDE.md` left a gap or the spec offered a sketch rather than a final shape. Each is small enough to revert without disturbing the rest of the role.

- **`pbs_host_firewall_enabled` defaults to `true`** per spec, but ufw enables in `firewall.yml` *after* the allow rules are added, so SSH stays reachable during the first apply. If `pbs_lan_subnet` is wrong in inventory, the subsequent SSH session WILL drop on the next reconnect — the operator-side rollback is `ufw disable` from local console.
- **8007 stays LAN-wide, not PVE-cluster-only.** The CLAUDE.md spec originally had a contradictory pair of bullets ("allow LAN" vs "PVE-only"). Resolved to LAN-wide because the PBS web UI is a humans-from-workstation surface as well as a PVE backup target — restricting to PVE cluster IPs would force tunneling for UI access without meaningfully shrinking the attack surface (LAN is the trust boundary anyway). If the posture ever tightens, add a `pbs_api_admin_src` var rather than hard-coding PVE IPs.
- **`loop_var: tcp_port`** in `firewall.yml`, not `port`. The community.general.ufw module has its own `port:` keyword; using `port` as the loop_var shadows the module's keyword via Jinja resolution order — works today by coincidence but is brittle. Renaming to `tcp_port` is the canonical fix.
- **Token secrets read from PBS via `--output-format json` then jq-extracted from `.value`.** PBS's `proxmox-backup-manager user generate-token --output-format json` returns `{"value": "<secret>", "tokenid": "<user>!<name>"}`. We extract `.value` once at create time and print to the operator with `no_log: true` on the create task plus an explicit unmask in the "surface secret" debug. If PBS upstream ever changes the JSON shape, the play fails noisily at `(stdout | from_json).value` — that's the right failure mode (loud, immediate).
- **`verify-job create` uses positional ID (not `--id`).** PBS's CLI for verify-job takes the ID as `command verify-job create <ID> [options]`. The original draft had `--id verify-<datastore>` which is wrong shape.
- **`--ignore-verified` is passed as a bare boolean flag** (not `--ignore-verified true`). PBS treats presence as true, absence as false. The "true"-as-explicit-value form is harmless but verbose.
- **GC schedule lives on the datastore object** (`datastore update --gc-schedule`), not as a separate job type. PBS 4.x consolidated GC scheduling onto the datastore in a previous release. Verify jobs are still their own object type with their own CLI surface.
- **Schedule strings stay in the systemd-shortcut form** (`"sat 02:00"`, `"sun 02:00"`). PBS accepts both shortcuts and the canonical OnCalendar form (`"Sat *-*-* 02:00:00"`); shortcuts read better in inventory and `verify-job list` echoes them back as the operator wrote them.
- **`pbs_datastore.yml` chowns the on-disk path to `backup:backup`** before invoking `proxmox-backup-manager datastore create`. PBS expects the daemon user to own the chunk store. The NAS-side NFS export MUST be configured with `no_root_squash` for the chown to succeed (the alternative — squashing root and mapping the backup uid through — is brittle). Documented in `docs/asustor-nas-setup.md`.
- **`pbs_users.yml` grants the role on BOTH the parent user AND the token.** Original scaffold granted on the token only, on the assumption that PBS privilege separation behaves the way PVE's does — token has its own independent permissions. PBS 4.x privsep is actually intersection-based: token effective perms = `(user perms) ∩ (token perms)`. A token-only grant evaluates to zero effective perms, and `pvesm add pbs` then fails with the misleading `Cannot find datastore '<name>', check permissions and existence!` error (the datastore exists, the token's grant exists — but the audit-gated list endpoint can't see it because the intersection is empty). Discovered 2026-05-18 debugging the first `pvesm add pbs pbs01-bulk` against pbs01; `proxmox-backup-manager user permissions 'pveingress@pbs!cluster' --path /datastore/bulk` returned `{}` until the parent user got the same grant. Role now grants both auth-ids and the stale-grant reconcile logic handles both. Role default was `DatastoreBackup` at scaffold time, changed to `DatastoreAdmin` after first-bootstrap testing — PVE's `pvesm add pbs` validation requires `Datastore.Audit` which `DatastoreBackup` doesn't include. See `defaults/main.yml` and the `tasks/pbs_users.yml` header comment for the full rationale.
- **Dedicated PBS↔NAS backup network (USB 2.5GbE + jumbo) deferred 2026-05-16.** Evaluated as a throughput-shortcut lever and skipped — `pbs01`'s i3-10110U (2C/4T Comet Lake-U) saturates CPU on the chunk-ingest pipeline (SHA-256 hash + dedupe lookup + AES encrypt + NFS write) at ~100–200 MB/s, well below the single 2.5GbE link's 312 MB/s ceiling. Dedupe further shrinks the PBS↔NAS leg once the warm chunk pool is built, so the link-sharing concern is largely first-backup-only. Adding a second NIC parallelizes a stage that isn't saturated, and a USB NIC adds a failure mode in the backup hot path. Authoritative record + the four real levers (local fast datastore, PVE-side parallelism, iSCSI+ZFS escape hatch, hardware-refresh re-eval) live in [`pbs-hosts/CLAUDE.md` § "Network shape"](../../../CLAUDE.md). Re-evaluate after measuring the first backup with `mpstat -P ALL` + `nfsiostat` + `journalctl -u proxmox-backup-proxy`.
- **`Restart proxmox-backup-proxy` handler was removed.** The original draft defined it but no task notified it. Repo convention (root CLAUDE.md) is to not design for hypothetical future requirements. The `Reload ufw` handler stays as a target for a future hand-written `before.rules` template, which is a plausible near-term need.
- **Sync feature (pbs_sync.yml + `pbs_sync_*` vars) removed.** Earlier drafts included scaffolding for a future FL→IL push-sync to a second PBS host (`pbs02`). With no second host on the roadmap, the scaffolding was deferred-via-deletion rather than carried as dead code with self-flagged "verify against PBS 4.x" TODOs. When/if a second host arrives, sync gets re-introduced against running hardware where the CLI flags can actually be tested.

---

## What Brian needs to fill in before the first run

Mirrors `pbs-hosts/CLAUDE.md` § "Things to leave for the operator" — restated here so this file is self-contained when the time comes.

1. **`pbs-hosts/ansible/inventory.yml`.** Copy `inventory.yml.example` and replace every `# TODO` marker:
   - `pbs_lan_subnet` — real LAN subnet (currently `192.0.2.0/24` placeholder).
   - `nas_ip` + `nas_hostname` — Asustor's actual IP and hostname.
   - `nas_pbs_nfs_export` — confirm the path matches what you create in the Asustor ADM UI under `/volume1/...`.
   - `admin_ssh_pubkey` — paste your operator SSH pubkey.
   - `pbs01` block: `ansible_host` + `pbs_lan_ip` — real LAN IP.
   - `pve_hosts` mirror group: every PVE node's `pve_lan_ip` (keep synchronized with `pve-hosts/ansible/inventory.yml`).
2. **Asustor NFS export.** Create `/volume1/proxmox-backups` (or equivalent) in ADM with: NFS v4 enabled, `no_root_squash`, `sync`, ACL limited to the PBS host's LAN IP. See `docs/asustor-nas-setup.md` § "Export for the PBS bulk datastore".
3. **BIOS prereqs on the GMKtec G3 Pro.** UEFI on, Secure Boot off, USB-first boot order. Documented in `docs/pbs-install.md` § "BIOS / UEFI prerequisites".
4. **PBS 4.x ISO install.** USB media + ISO + click-through. Documented in `docs/pbs-install.md`. The role assumes a freshly-installed PBS host; it doesn't `apt install proxmox-backup-server`.
5. **Capture the API token secret at first apply.** Output of `tasks/pbs_users.yml` surfaces the token once. Paste into KeePassXC under `pbs01 / pveingress@pbs!cluster`. Needed by the PVE-side storage-registration step (see `docs/cluster-bring-up.md`).

---

## Deviations from the spec

Each deviation has a one-paragraph rationale.

### Verify-job ID is positional, not `--id`-prefixed

CLAUDE.md sketched the command as `verify-job create --id verify-{{ ds.name }} --store {{ ds.name }} ...`. Actual PBS 4.x CLI is `verify-job create <ID> --store <STORE> ...`. Wrong-shape draft would have failed on first invocation.

### `--ignore-verified` as bare flag

Minor — PBS accepts both `--ignore-verified` and `--ignore-verified true`. Bare flag is the more idiomatic form. Either would work.

### `Restart proxmox-backup-proxy` handler removed

CLAUDE.md didn't require it; the draft included it speculatively. Repo convention is to not design for hypothetical futures. Will reinstate when (and only when) the in-VM TLS-cert task ships.

### `pbs_host_firewall_enabled` default stays `true`

Spec said default-on. Acceptable on a freshly-installed host where the operator is local (KVM or serial). If applying remotely against a host you reach only via SSH, set `pbs_host_firewall_enabled: false` for the first apply, verify `ufw status` shows the allow-LAN rules, then re-run with default to flip on.

---

## Acceptance gates — outcomes

Run from repo root (or `pbs-hosts/ansible/`). All four are pre-hardware checks — they validate the role's shape against the example inventory; the "second run reports `changed=0`" gate from the spec only fires once `pbs01` is online.

```bash
# 1. Syntax check (against the example inventory).
cd pbs-hosts/ansible
cp inventory.yml.example inventory.yml.tmp
ansible-playbook -i inventory.yml.tmp site.yml --syntax-check
rm inventory.yml.tmp

# 2. Lint (production profile).
ansible-lint pbs-hosts/ansible/roles/pbs-host/

# 3. Template render dry-run (connection errors expected — we want template + task graph errors only).
ansible-playbook -i inventory.yml.tmp site.yml --check --diff --connection=local || true

# 4. First-apply against real hardware: on the second run, every task should report changed=0.
ansible-playbook -i inventory.yml site.yml | tee /tmp/pbs-apply-1.log
ansible-playbook -i inventory.yml site.yml | tee /tmp/pbs-apply-2.log
grep 'changed=' /tmp/pbs-apply-2.log
```

Acceptance results from the pre-hardware pass (recorded 2026-05-16):

- **Gate 1 — syntax-check:** `playbook: site.yml ... exit=0`. Inventory placeholders parse cleanly into host vars; the `assert` block + every `import_tasks` resolve without error.
- **Gate 2 — ansible-lint (production profile):** `Passed: 0 failure(s), 0 warning(s)`. Two findings from the first lint pass were addressed:
  - `community.general.ufw` does not accept `proto: icmp` (module enum is AH/ANY/ESP/IPv6/TCP/UDP/GRE/IGMP/VRRP). Debian's stock `/etc/ufw/before.rules` already accepts ICMP echo-request on INPUT before the user-rule chain, so the explicit rule was removed with a comment explaining the path forward (templated `before.rules`) if LAN-scoped restriction is ever needed.
  - `no-handler` lint on the "Surface freshly-created token secret to operator" debug task. Annotated `# noqa: no-handler` with a comment explaining that the operator must see the cleartext secret inline — handlers fire at end-of-play, which could hide the message in scroll-back.
- **Gate 3 — template render dry-run:** deferred. Requires either a reachable PBS host or a molecule scenario; running it now against `--connection=local` produces a noisy log of "host is not localhost" errors that don't validate template logic.
- **Gate 4 — first-apply + second-apply idempotency:** fires when `pbs01` is online and the role can be applied against real hardware.

---

## Design vault

The authoritative PBS architecture lives in the project's private Obsidian vault under `[[Proxmox Backup Server — Capabilities and Tiered Storage]]`. Tiering decisions, dedicated-vs-VM rationale, and the future TLS-from-Root-CA plan all live there.
