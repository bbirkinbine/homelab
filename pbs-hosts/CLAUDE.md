# CLAUDE.md — pbs-hosts (layer 0 PBS host bootstrap)

> **Purpose.** Scaffolding spec + persistent context for Claude Code (or any AI tool) implementing the `pbs-host` Ansible role under `pbs-hosts/ansible/roles/pbs-host/`. Read this file fully before generating anything. The folder skeleton already exists; your job is to fill in the role's task/template/handler/var files per this spec, and to verify the result with the acceptance gates at the bottom.

Read the **repo-level** `CLAUDE.md` at the root of this repository first if you haven't — it covers tone, no-emojis style, public-repo hygiene rules, and the secrets-handling philosophy (operator's local credential store, read at invocation time, never embedded). The conventions below extend those, they don't replace them.

Read the sibling `pve-hosts/CLAUDE.md` for context on the layer-0 pattern this role mirrors. Where pbs-host diverges from pve-host, the divergence is called out below.

---

## Why this folder exists, in one paragraph

`pve-hosts/` configures the Proxmox VE hypervisors; `pbs-host` is the parallel role for Proxmox Backup Server. It configures the dedicated bare-metal PBS host whose only job is to receive backups from the PVE cluster. PBS runs on its own hardware rather than as a VM on the cluster — running the backup-of-record on the thing it's backing up is a circular-dependency that defeats the point. The config surface (datastores, API tokens, GC schedules; no bridges, no cluster, no TB fabric) also diverges from PVE enough that bolting it onto `pve-host` would obscure both. Authoritative architecture lives in the design vault under `[[Proxmox Backup Server — Capabilities and Tiered Storage]]`; this role implements it.

---

## Network shape

Single 2.5GbE LAN port; no dedicated PBS↔NAS backup network. A second NIC (USB 2.5GbE + direct cable to the Asustor's spare 2.5GbE port, point-to-point /30 with MTU 9000) was evaluated 2026-05-16 and **deferred** — on `pbs01`'s i3-10110U (2C/4T Comet Lake-U) the chunk-ingest pipeline (SHA-256 hash → dedupe lookup → AES encrypt → NFS write) saturates CPU before the single 2.5GbE link does. Sustained ingest tops out around 100–200 MB/s after dedupe versus 312 MB/s theoretical on 2.5GbE; a second NIC parallelizes a stage that isn't saturated. Dedupe further shrinks the PBS↔NAS leg once the warm chunk pool is built, so the link-sharing concern is largely first-backup-only.

If the backup window ever overruns, the levers ranked by effect-per-dollar are:

1. **Enable the local fast datastore** (`pbs_local_fast_datastore_enabled: true` plus a second entry in `pbs_datastores` pointing at the local fast drive). Hot retention writes hit local NVMe (~3 GB/s) instead of NFS (~200 MB/s with cache). Caveat: `pbs01` ships with a 512 GB SATA SSD (~500 MB/s), only marginally faster than NFS-with-cache for sequential writes — to realize the lever's full value, swap the stock drive for an NVMe before enabling. Cheap one-time hardware change; software-only enablement after.
2. **PVE-side backup-job parallelism** (`max-workers` on the backup job) plus an incremental-nightly + full-weekly schedule shape. Saturates CPU instead of leaving cores idle.
3. **The L33 escape hatch:** iSCSI + local ZFS-with-special-vdev. Significant; defer until measured GC overrun.
4. **Re-evaluate the dedicated backup network** only after a PBS hardware refresh to a ≥4-core current-gen CPU, or if the workload shifts to large low-dedupe payloads (LLM model dumps, video archives).

Order of operations: instrument the first backup with `mpstat -P ALL 5` + `nfsiostat` + `journalctl -u proxmox-backup-proxy`, identify the limiter, then pick the lever — don't upgrade speculatively.

---

## Host context

One PBS host. Dedicated x86 mini-PC running stock Proxmox Backup Server 4.x from ISO.

| Host | Hardware | Role |
|---|---|---|
| `pbs01` | GMKtec G3 Pro Mini PC — Intel Core i3-10110U (2C/4T, Comet Lake-U), 16 GB DDR4, 512 GB SATA SSD (stock), 1× 2.5GbE | Primary backup target. Receives PVE-cluster backups. |

Network: single 2.5GbE LAN port (vlan-untagged) on the same switched LAN as the Asustor and the PVE cluster. No TB fabric; no bridges; no VLANs at this layer.

Storage:

- **Bulk datastore (default, required):** NFS mount from the Asustor's RAID6 + NVMe-R/W-cache volume. PBS's metadata-heavy workload (GC, verify) is helped by the NAS-side R/W cache; expected datastore size in the low-double-digit TB range. NFS path stays under `/mnt/pbs-bulk`.
- **Fast datastore (optional, off by default):** local fast block storage on the PBS host. Use case is a hot-retention window with sub-second restore startup. The stock G3 Pro ships with a 512 GB SATA SSD; meaningful gain over the NFS-with-cache bulk store requires swapping it for an NVMe first. Either way, the carve-out is a small directory (≤200 GB) alongside the OS install. Gated by `pbs_local_fast_datastore_enabled` in inventory.

NFS-backed datastores are slower than local for metadata-heavy operations (GC, verify); the NAS-side R/W cache mitigates the worst of it at the lab's expected scale (single- to low-double-digit TB). Escape hatch if GC ever spills past the backup window: move the volume to iSCSI + local ZFS-with-special-vdev. Out of scope for this role.

---

## What the role MUST do

The role brings a freshly-installed PBS 4.x host to a baseline ready for normal backup-target use. Specifically, in roughly this task-file order:

1. **`repo.yml` — APT repos.** Replace the enterprise sources with the no-subscription set, deb822 format. Two stanzas: Debian base (trixie + trixie-updates + security) and Proxmox PBS no-subscription. The PBS no-sub repo URL is `http://download.proxmox.com/debian/pbs` (note `/pbs`, not `/pve`); component is `pbs-no-subscription`. Remove both the legacy `.list` and the deb822 `.sources` enterprise files if either is present (the PBS installer ships the deb822 form). `apt update` only when the source file changes (via handler), then `flush_handlers` before downstream installs.

2. **`packages.yml` — base packages.** Install (state: present, not latest) the minimum set required by downstream tasks in this play: `chrony` (consumed by `time.yml`), `ufw` (consumed by `firewall.yml` + handler), `nfs-common` (consumed by `nfs.yml`). Pull the list from `defaults/main.yml` so it's overridable per host. Operator debugging tools (`htop`, `iperf3`, `tmux`, `dnsutils`, `tcpdump`, etc.) are deliberately NOT installed — `apt install <foo>` on demand if needed. `vim` is also omitted (Debian's `vim-tiny` covers the occasional config edit). `jq` is intentionally absent — JSON parsing in `pbs_datastore.yml` / `pbs_users.yml` / `pbs_jobs.yml` uses Ansible's `from_json` filter, not the `jq` binary. Note: `ufw` replaces `pve-firewall` — PBS does not ship `pve-firewall` and there's no cluster-side cluster.fw to write into pmxcfs.

3. **`time.yml` — chrony / NTP.** Disable + mask `systemd-timesyncd`. Template `/etc/chrony/chrony.conf` from `chrony.conf.j2`. Enable + start chrony. Restart on config change. Same pattern as `pve-host`, same NTP targets (consistency across the lab).

4. **`hosts_file.yml` — `/etc/hosts`.** Template the file: localhost stanza, PBS host(s) from inventory, each PVE cluster member from a sibling group (so PBS resolves PVE hostnames without DNS), and the NAS.

5. **`tuning.yml` — sysctl tuning.** Template `/etc/sysctl.d/99-pbs-host.conf` with TCP buffer ceilings for high-throughput chunk transfers. Conservative defaults; override-friendly via host vars. Apply via `sysctl --system` handler.

6. **`nfs.yml` — NFS mount(s).** Ensure `/mnt/pbs-bulk` exists. Use `ansible.posix.mount` to manage the fstab entry with `vers=4.2`, `_netdev`, `noatime`, and mount it. The export served from the Asustor is a different share than the one used by `pve-host` (PVE VM disks vs PBS chunk store — different IO profiles, separate exports, separate ACLs).

7. **`firewall.yml` — ufw baseline.** Default deny inbound, default allow outbound. Allow from the LAN subnet: SSH (22), PBS web UI + API (8007). ICMP echo is accepted globally via Debian's stock `/etc/ufw/before.rules` — no `ufw:` rule needed (and the module's `proto:` enum doesn't include `icmp`). Enable ufw at the end. PBS is an NFS *client* (no inbound rule needed). 8007 stays LAN-wide because the UI is also a workstation surface; if that ever tightens, surface a `pbs_api_admin_src` var rather than hard-coding PVE IPs.

8. **`users.yml` — SSH keys.** `ansible.posix.authorized_key` to install `admin_ssh_pubkey` for `root`. No-op if the key is empty.

9. **`pbs_datastore.yml` — create datastores.** Idempotently ensure each datastore in `pbs_datastores` exists, using `proxmox-backup-manager datastore` CLI calls (PBS's REST API is more involved to authenticate against from inside the host than the CLI, which uses local-Unix-socket creds). The task should:
    - For each datastore, check existence with `proxmox-backup-manager datastore list --output-format json | jq`.
    - If missing, create with `proxmox-backup-manager datastore create <name> <path>`.
    - If `prune_keep_*` policy is set in inventory, apply with `proxmox-backup-manager datastore update <name> --prune-...`.
    - `changed_when` based on output state, not just success.

10. **`pbs_users.yml` — assert API user + token, grant ACL.** The role does **not** create the `pveingress@pbs` user or the `cluster` token. Convention in this repo (matching the PVE-side `tofu@pve!apply` and `packer@pve!builder` patterns) is that any secret PBS generates server-side is created by the operator via the PBS web UI and stashed in KeePassXC under `Homelab/PBS/pveingress-cluster` (Password field for the UI password, Notes for the `<authid>=<secret>` token string). The role queries `user list` + `user list-tokens`, asserts both exist (with a fail-msg pointing at the manual runbook in the task header), then grants the `pbs_pve_ingress_role` (default `DatastoreAdmin`) on each datastore's namespace to **both the user and the token** via two `acl update --auth-id` calls (one for `<user>`, one for `<user>!<token>`). The role itself never sees the cleartext secret — only the auth-id, which is non-secret. Granting on both is required because PBS 4.x privilege separation is intersection-based — a token's effective perms are `(user perms) ∩ (token perms)`, so a token-only grant evaluates to zero effective perms and `pvesm add pbs` then fails with the misleading "Cannot find datastore 'bulk'" error. Role choice: `DatastoreAdmin` not `DatastoreBackup` — PVE's `pvesm add pbs` storage-registration handshake requires `Datastore.Audit`, which `DatastoreBackup` in PBS 4.x does not include. See `defaults/main.yml` for the full rationale.

11. **`pbs_jobs.yml` — schedules.** For each datastore, create:
    - A verification job (`verify-<ds>`, default: weekly, all snapshots, outdated-after 7 days).
    - A prune job (`prune-<ds>`, default: weekly, retention from `pbs_datastores[*].prune_keep_*` or the role defaults). PBS 4.x moved prune from per-datastore policy to its own job type — `datastore update --keep-*` is rejected with "datastore prune settings have been replaced by prune jobs". `pbs_datastore.yml` therefore creates the datastore *without* retention flags, and this file owns the retention via the separate `prune-job` object.
    - A GC schedule on the datastore object (still a datastore field in PBS 4.x, NOT a separate job type at the time of writing — set via `datastore update --gc-schedule`).
    Use `proxmox-backup-manager <job-type>` CLI; same idempotency pattern as datastores (list → diff → create/update).

12. **`ups.yml` — UPS shutdown guardian (opt-in, default OFF).** Gated on `pbs_host_manage_ups_guardian` (default false) via the `import_tasks` `when:` (placed right after `nfs.yml`). Installs `nut-client`, deploys the shared `scripts/nas-ups-guardian.sh` to `/usr/local/sbin/nas-ups-guardian`, renders `/etc/default/nas-ups-guardian` (`GUARDIAN_MODE=pbs` + NUT target + thresholds), and installs + enables a systemd timer→oneshot that polls the UPS with `upsc` every ~20s. On battery AND `battery.charge ≤ pbs_host_ups_charge_threshold` (default **70** — pbs01 is the highest-value NFS client, so it leads the shutdown ahead of the PVE nodes' 60%), it stops `proxmox-backup-proxy`, waits `pbs_host_ups_drain_grace` for in-flight chunk writes to settle, then powers off — leaving the NAS (10% cutoff) to go last. PBS is crash-consistent and GC/verify resumable, so the guardian does NOT wait for a long task; aborting via the orderly poweroff is safe. Ordering is a charge gap, NOT the NUT handshake (the Asustor upsd does not wait for network clients). **Applying the role must never power off the host** — the guardian acts only on a real power event. Mirror of the `pve-host` role's `ups.yml`. See `pbs-hosts/README.md` and the vault doc `[[nut-ordered-shutdown-design]]`. Reload/restart tasks are `when: <unit> is changed` to keep a healthy re-run at `changed=0`.

Wire all of these into `tasks/main.yml` in order via `ansible.builtin.import_tasks:` (static composition so syntax errors surface during `--syntax-check`).

---

## What the role MUST NOT do

These are deliberately out of scope. Each has install-time, hardware, or operator-state risk that breaks declarative automation:

- **The PBS ISO install itself.** USB prep, partitioning, hostname/IP entry. Manual one-time step, documented in `docs/pbs-install.md`.
- **PVE-side storage registration.** Adding PBS as a backup target on the PVE cluster touches `/etc/pve/storage.cfg`, which is pmxcfs-replicated cluster-wide; doing it from the PBS host's role is the wrong scope. Manual one-time `pvesh create /storage` from any cluster member, documented in the cluster bring-up runbook.
- **TLS cert replacement.** PBS ships a self-signed cert. The eventual migration to a cert chained off the offline Root CA on the CardLogix HSM pair is a future task with its own runbook. Don't touch `/etc/proxmox-backup/proxy.pem` from this role.
- **Datastore filesystem creation.** The NFS mount is managed (step 6); local-fast datastore filesystems are assumed pre-existing — the role validates the path exists and is writable but doesn't `mkfs`.
- **API token creation + secret handling.** The role does not create the `pveingress@pbs` user or the `cluster` token, and never sees the cleartext secret. Convention (matching the PVE-side `tofu@pve` / `packer@pve` tokens): operator creates them via the PBS web UI before first apply. The KeePassXC entry `Homelab/PBS/pveingress-cluster` carries two fields — **Password** holds the random PBS UI password (PBS 4.x's form requires one even for service identities; kept for completeness, never read at runtime), and **Notes** holds the full token string `pveingress@pbs!cluster=<secret>` (same `<tokenid>=<secret>` format `Homelab/Tofu/proxmox-api-token` uses, just relocated to Notes because Password is claimed by the UI password). The role asserts both user + token exist on PBS and grants the configured role on both the user and the token (intersection-semantics; see step 10 above) using only the non-secret auth-ids. The KeePassXC entry's Notes field is consumed later by the future PVE-side hydrate-driven play that registers PBS as a `pvesm` storage target (via `kp://Homelab/PBS/pveingress-cluster#Notes`; that play splits at `=` for `pvesm`'s separate `--username` / `--password`). NEVER add a task that creates the user, generates the token, surfaces the cleartext secret, or writes it to disk anywhere — managed host or workstation. If the manual prereq isn't met, the assert fails with a runbook pointer.
- **`apt upgrade` / `apt dist-upgrade`.** Package state is `present`, not `latest`. Upgrades are a separate operator decision.
- **Reboots.** Surface "Manual reboot recommended" if a kernel module change calls for one; don't trigger.
- **GRUB or kernel parameter edits.**
- **Anything `pveum`, `pvecm`, `pvesh`, or `pve-*`.** Those are PVE binaries; PBS uses `proxmox-backup-manager`. If you find yourself reaching for a PVE binary in this role, you're in the wrong file.

---

## Folder skeleton

The structure under `pbs-hosts/ansible/roles/pbs-host/` is created with the scaffolding pass. Final layout you should produce:

```
pbs-hosts/ansible/roles/pbs-host/
├── defaults/
│   └── main.yml                         # overridable defaults
├── vars/
│   └── main.yml                         # role-internal constants
├── tasks/
│   ├── main.yml                         # import_tasks in order
│   ├── repo.yml
│   ├── packages.yml
│   ├── time.yml
│   ├── hosts_file.yml
│   ├── tuning.yml
│   ├── nfs.yml
│   ├── firewall.yml
│   ├── users.yml
│   ├── pbs_datastore.yml
│   ├── pbs_users.yml
│   └── pbs_jobs.yml
├── handlers/
│   └── main.yml                         # restart chrony, sysctl, apt-update, ufw-reload
├── templates/
│   └── etc/
│       ├── apt/
│       │   └── sources.list.d/
│       │       └── pbs-no-subscription.sources.j2
│       ├── chrony/
│       │   └── chrony.conf.j2
│       ├── hosts.j2
│       └── sysctl.d/
│           └── 99-pbs-host.conf.j2
├── files/
│   └── (empty)
└── meta/
    └── main.yml                         # galaxy_info: minimal
```

Mirror `/etc/` substructure inside `templates/` so the relationship between template file and target path is obvious. Same convention as `pve-hosts/ansible/roles/pve-host/`.

---

## Inventory schema (see `inventory.yml.example`)

The template inventory is at `pbs-hosts/ansible/inventory.yml.example`. It defines:

- One host (`pbs01`) in the `pbs_hosts` group.
- A `pve_hosts` group (mirror of `pve-hosts/ansible/inventory.yml`'s structure) so the `/etc/hosts` template can resolve PVE node names. Do not run the play against `pve_hosts` — that's `pve-host`'s job. The mirror is for resolution only.
- Per-host vars: `pbs_lan_ip`, `pbs_datastores` (list of dicts with `name`, `path`, `prune_keep_*`), `pbs_local_fast_datastore_enabled` (bool).
- Group-level vars: `pbs_lan_subnet`, `nas_*`, `pbs_repo_distribution` (fixed: `trixie`), `chrony_servers`, `admin_ssh_pubkey`.

---

## Template guidance

### `templates/etc/apt/sources.list.d/pbs-no-subscription.sources.j2`

deb822 format, three stanzas: Debian base, Debian security, PBS no-subscription. The PBS repo URL differs from PVE:

```
Types: deb
URIs: http://deb.debian.org/debian
Suites: {{ pbs_repo_distribution }} {{ pbs_repo_distribution }}-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: {{ pbs_repo_distribution }}-security
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: {{ pbs_repo_distribution }}
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

### `templates/etc/chrony/chrony.conf.j2`

Identical structure to `pve-host`'s template (same NTP sources, same drift/makestep/rtcsync stanzas). The only divergence: `allow` line restricts to the LAN subnet so the PBS host can serve time to its own VMs (rare; PBS doesn't run guest workloads, but cheap).

### `templates/etc/hosts.j2`

Localhost stanza, PBS host(s) from `groups['pbs_hosts']`, PVE cluster members from `groups['pve_hosts']` (for resolution; no TB loopback aliases since PBS isn't on the TB fabric), and the NAS.

### `templates/etc/sysctl.d/99-pbs-host.conf.j2`

TCP buffer ceilings for high-throughput chunk transfers over 2.5GbE. Conservative — kernel autotunes within the ceilings:

```
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
# Increase the local port range so parallel ingest streams from the PVE
# cluster don't run out of ephemeral ports during the nightly backup burst.
net.ipv4.ip_local_port_range = 10000 65535
```

---

## Idempotency, safety, style — non-negotiable

1. **Every task must be idempotent.** Re-running on a healthy host must report `changed=0`.
2. **No reboots.** Surface; don't trigger.
3. **Fail loudly on missing required vars.** Use `ansible.builtin.assert` early in `tasks/main.yml` to validate `pbs_lan_ip` and at least one datastore in `pbs_datastores`. Empty `admin_ssh_pubkey` is allowed (warn, don't fail).
4. **API token secrets never get persisted to disk.** Print to operator once; trust them to paste into KeePassXC.
5. **`proxmox-backup-manager` CLI for all PBS configuration.** Don't invent a REST-API wrapper. The CLI uses local-Unix-socket creds — works from inside the host with no extra auth plumbing.
6. **FQCN everywhere.** `ansible.builtin.copy`, `ansible.posix.mount`, `community.general.ufw`, etc. — never bare module names.
7. **Header comments on every file.** Match the `pve-host` role style — what the file does, when it runs, the idempotency story, any quirks.
8. **No emojis. Avoid the words "genuinely", "straightforward", "actually".** Repo convention.
9. **Comments cite vault docs in `[[bracketed-name]]` form.** Same as the existing repo style.

---

## First-contact workflow on a fresh PBS host

The role's `tasks/repo.yml` carries `check_mode: false` on its four bootstrap tasks (enterprise-repo removal × 2, no-subscription sources write, keyring presence) and the same annotation on the `Apt update` handler in `handlers/main.yml`. This means `--check` *actually performs the repo swap and refreshes the apt cache* on first contact, then dry-runs everything downstream against a real cache. Without the annotations, the first `--check` on a fresh host would fail at `Install baseline packages` because the cache is still pointed at the (401-ing) enterprise repo. See the header comment in `tasks/repo.yml` for the full rationale and the trade-off being accepted.

The intended operator flow on a fresh host is:

1. **`just pbs-hosts-check`** — first contact. Performs the repo swap (mutating but desired: enterprise → no-subscription), refreshes the apt cache, then shows the full diff for every other change the role would make. Review the diff.
2. **`just pbs-hosts`** — real apply. `repo.yml` is mostly no-ops on this run (step 1 already wrote the sources); everything downstream gets applied.
3. **`just pbs-hosts-check`** again — idempotency probe. Should report `changed=0` on a healthy host; non-zero indicates a non-idempotent task to investigate.

On already-bootstrapped hosts, step 1 produces a clean diff (or `changed=0`) and you skip step 2.

The trade-off this design accepts: `--check` is not purely side-effect-free for the repo swap. The four bootstrap tasks mutate either the *desired end state* (no-subscription sources written, enterprise sources removed) or *trivially recoverable* state (apt cache, regenerated on the next `apt update`). The mutations `--check` actually protects against — package installs, firewall rule changes, NFS mounts, datastore creation, API user/token writes — all still simulate normally. The leak is intentional and isolated; without it, `--check` against a fresh host is structurally impossible (you'd be dry-running against a broken cache).

---

## Acceptance gates — before claiming done

Gates 1–2 validate the role locally (no real host required). Gate 3 is the only one that touches real hardware and doubles as the operator's first-bootstrap step (see "First-contact workflow" above).

A `--check --diff --connection=local` dry-run against `inventory.yml.example` would be a useful third local gate, but it doesn't work on macOS: the `ansible.builtin.apt` module requires `python3-apt` on the connection target to run in check mode, and `python3-apt` does not exist on macOS. Since the workstation is macOS, local dry-run is not a practical gate for an apt-using role. We rely on syntax-check + lint for local validation and the real-host apply for end-to-end verification.

```bash
# 1. Syntax check. Ansible's YAML inventory plugin requires a .yml/.yaml
#    suffix to auto-attach, so the example needs a temporary copy first
#    (otherwise Ansible falls back to the ini plugin, fails to parse,
#    and the syntax check matches no hosts — a toothless exit-0).
cd pbs-hosts/ansible
cp inventory.yml.example /tmp/pbs-inventory.yml
ansible-playbook -i /tmp/pbs-inventory.yml site.yml --syntax-check
rm /tmp/pbs-inventory.yml

# 2. Lint (production profile)
ansible-lint pbs-hosts/ansible/roles/pbs-host/

# 3. First-apply against real hardware. Prereq: copy the example to a real
#    inventory and fill in the placeholders.
#      cp inventory.yml.example inventory.yml
#      # edit inventory.yml: real LAN IPs, NAS IP, admin_ssh_pubkey, etc.
#    Then log every task that reports `changed` on a second run — that
#    flags non-idempotent tasks.
ansible-playbook -i inventory.yml site.yml | tee /tmp/pbs-apply-1.log
ansible-playbook -i inventory.yml site.yml | tee /tmp/pbs-apply-2.log
grep 'changed=' /tmp/pbs-apply-2.log  # should be changed=0
```

Verify against the example inventory that `pbs01` renders:

- `/etc/apt/sources.list.d/pbs-no-subscription.sources` with the three stanzas including `pbs-no-subscription` (NOT `pve-no-subscription`).
- `/etc/hosts` with the PBS host(s), all three PVE cluster members, and the NAS.
- `/etc/sysctl.d/99-pbs-host.conf` rendered with the LAN-tuned buffers.
- `ufw status` shows: deny incoming default, allow outgoing default, allow 22 from LAN subnet, allow 8007 from LAN subnet. ICMP echo is accepted by Debian's stock `/etc/ufw/before.rules` and does NOT appear in `ufw status`.
- `/mnt/pbs-bulk` mounted to the NAS export with `vers=4.2,_netdev,noatime`.
- `proxmox-backup-manager datastore list` shows the bulk datastore.
- `proxmox-backup-manager user list` shows `pveingress@pbs`; `proxmox-backup-manager user list-tokens pveingress@pbs` shows `cluster`.

If any of these don't match, fix the role and re-verify before signing off.

---

## Things to leave for the operator

- Real LAN subnet + IPs in `inventory.yml` (post-scaffold copy of `.example`).
- Real NAS IP, hostname, and PBS-dedicated NFS export path. Confirm the export ACL allows the PBS host's LAN IP with `no_root_squash` + `sync`.
- The operator's SSH pubkey for `admin_ssh_pubkey`.
- BIOS settings: UEFI on, Secure Boot off, USB-first boot order. Document as a manual prereq in `docs/pbs-install.md`.
- The PBS API token secret printed at first apply — paste into KeePassXC under `pbs01 / pveingress@pbs!cluster`. Used by the PVE-side storage registration runbook.

---

## Justfile + .gitignore integration

The four `pbs-hosts*` recipes (`pbs-hosts-deps`, `pbs-hosts`, `pbs-hosts-check`, `pbs-hosts-one host`) are present in the repo-root `Justfile` alongside the `pve-hosts*` set. The `pbs-hosts/ansible/inventory.yml`, `*.retry`, and `.ansible_galaxy` entries are in `.gitignore`. Verify they're present before re-adding.

---

## Implementation record

[`ansible/roles/pbs-host/SCAFFOLD-NOTES.md`](ansible/roles/pbs-host/SCAFFOLD-NOTES.md) records what was generated, assumptions made beyond this spec, deviations + rationale, and the acceptance-gate output. Read it alongside this file when changing the role — this CLAUDE.md is the spec; SCAFFOLD-NOTES.md is what was actually built.

---

## Design vault (operator-only)

The authoritative architecture lives in the project's private design vault under `[[Proxmox Backup Server — Capabilities and Tiered Storage]]`. The four-way comparison of tiering options, the dedicated-vs-VM decision rationale, and the future TLS-from-Root-CA plan all live there. If something in this CLAUDE.md is ambiguous and the rationale matters, ask the maintainer for vault access rather than guessing.
