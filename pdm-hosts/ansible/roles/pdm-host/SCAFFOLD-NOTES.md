# pdm-host — scaffold notes

Implementation notes for the `pdm-host` Ansible role, generated against the spec in `pdm-hosts/CLAUDE.md`. Captures what was produced, the assumptions baked in, deviations from a naive copy of `pbs-host`, and validation outcomes.

Layer-0 spec lives in [`pdm-hosts/CLAUDE.md`](../../../CLAUDE.md). The user-facing entry point is [`pdm-hosts/README.md`](../../../README.md). Read both first.

The role was scaffolded by copying `pbs-hosts/` and trimming, so it inherits the proven layer-0 spine. The notes below focus on what changed, not what carried over verbatim.

---

## Files generated

```text
roles/pdm-host/
├── defaults/main.yml                       # overridable knobs (packages, firewall toggle, UPS + config-backup)
├── meta/main.yml                           # Galaxy metadata + collection deps (ansible.posix, community.general)
├── handlers/main.yml                       # reload-systemd / apt-update / restart-chrony / reload-ufw
├── tasks/
│   ├── main.yml                            # assert pdm_lan_ip + ordered import_tasks pipeline
│   ├── repo.yml                            # remove pdm-enterprise.{list,sources} + write deb822 pdm-no-subscription
│   ├── packages.yml                        # baseline set (chrony, ufw) — NO nfs-common
│   ├── time.yml                            # mask timesyncd, install chrony.conf, start chrony
│   ├── hosts_file.yml                      # render /etc/hosts from pdm + pve + pbs mirrors + NAS
│   ├── firewall.yml                        # ufw default-deny + LAN-subnet allow for 22/8443
│   ├── users.yml                           # operator SSH pubkey for root@<host>
│   ├── ups.yml                             # opt-in UPS guardian (GUARDIAN_MODE=pdm)
│   └── config_backup.yml                   # opt-in config self-backup (mounts NFS itself)
└── templates/etc/
    ├── apt/sources.list.d/pdm-no-subscription.sources.j2
    ├── chrony/chrony.conf.j2
    ├── hosts.j2
    ├── default/nas-ups-guardian.j2
    ├── default/pdm-config-backup.j2
    └── systemd/system/{nas-ups-guardian,pdm-config-backup}.{service,timer}.j2
```

Outside the role itself, the repo gained:

- `scripts/pdm-config-backup.sh` — new PDM-named sibling of `scripts/pbs-config-backup.sh`.
- `scripts/nas-ups-guardian.sh` — gained a `pdm` mode (`drain_pdm()`, `pdm)` case, `PDM_DRAIN_GRACE`, header tier diagram + `GUARDIAN_MODE (pve|pbs|pdm)`). Purely additive; pve/pbs behavior unchanged.
- `Justfile`: `pdm-hosts-deps`, `pdm-hosts`, `pdm-hosts-check`, `pdm-hosts-one host=<name>` recipes (mirroring the `pbs-hosts-*` set).
- `.gitignore`: `pdm-hosts/ansible/inventory.yml` added alongside the pbs/pve entries.

Files deliberately NOT generated (deleted from the copy): `vars/main.yml`, `tasks/{nfs,tuning,pbs_datastore,pbs_users,pbs_jobs}.yml`, `templates/etc/sysctl.d/99-pdm-host.conf.j2`. See "Divergences" below.

---

## Upstream facts verified (not assumed)

Checked against https://pdm.proxmox.com/docs/installation.html rather than memory:

- No-subscription repo: `http://download.proxmox.com/debian/pdm`, suite `trixie`, component `pdm-no-subscription`.
- ISO ships the enterprise repo at `/etc/apt/sources.list.d/pdm-enterprise.sources` (deb822).
- Install package (ISO already did this; role does NOT): `proxmox-datacenter-manager-container-meta`.
- Web UI / API: HTTPS on **8443**.
- API daemons: `proxmox-datacenter-api` and `proxmox-datacenter-privileged-api` (used by `drain_pdm`).
- Config dir: `/etc/proxmox-datacenter-manager`.
- PDM reached 1.0 (docs at 1.1.x) — no longer alpha/beta, so automating it is a safe bet.

---

## Divergences from a naive `pbs-host` copy

Each is a deliberate trim or change, small enough to revert in isolation.

- **Dropped the datastore spine** (`nfs.yml`, `pbs_datastore.yml`, `pbs_users.yml`, `pbs_jobs.yml`). PDM has no datastore, no service-ingress token, no scheduled jobs.
- **Dropped `tuning.yml` + the sysctl drop-in.** Deleted rather than gated off (repo convention: delete dead scaffolding). PDM is an API proxy + web UI, not a chunk store — the PBS TCP-buffer ceilings + widened ephemeral range have no rationale here.
- **Dropped `vars/main.yml`.** `pbs-host` parked the `proxmox-backup-manager` path there; `pdm-host` calls no PDM CLI, so there are no role-internal constants.
- **`packages.yml` drops `nfs-common`** from the baseline. PDM mounts nothing by default; `config_backup.yml` installs `nfs-common` only when that opt-in is enabled.
- **Firewall: 8443** (PDM web UI/API), not 8007.
- **`config_backup.yml` mounts its own NFS export.** This is the biggest structural change. PBS's config-backup piggybacked on the datastore's standing NFS mount; PDM has none, so the mount (plus `nfs-common` install + dest dir) is folded into the config-backup task and gated by the same `pdm_host_manage_config_backup` toggle. A default install mounts nothing.

---

## Assumptions beyond the spec

- **UPS tier = 75%, above pbs01's 70%.** PDM is not an NFS client, so it has no data-path ordering constraint — its tier is cosmetic. Set above the data-path tiers on the logic that a management plane is the cheapest thing to lose and shedding it recovers a sliver of runtime. This adds a row above pbs01 in the shared script's tier diagram; the design-vault doc `[[nut-ordered-shutdown-design]]` should be updated to match (operator action — the public repo doesn't edit the vault).
- **`drain_pdm()` stops both API daemons** (`proxmox-datacenter-api` + `proxmox-datacenter-privileged-api`) with a short 10s grace. There's nothing to drain (no data), so this is a courtesy clean stop, not a real quiesce. `systemctl poweroff` would stop them anyway; the explicit stop just makes shutdown deterministic and logs intent.
- **config-backup destination reuses the PBS backups export** (`/volume1/proxmox-backups`) with a `host-config/` subdir by default. The NAS export ACL must add `pdm01`'s LAN IP (operator step, documented in README). Override `pdm_config_backup_nfs_export` for a dedicated export if you'd rather keep PDM and PBS artifacts on separate ACLs.
- **config-backup left OFF by default and recommended to stay OFF** until PDM accumulates enough remotes/ACLs/users to justify the standing NFS mount + export ACL. PDM holds no data; worst-case recovery without it is reinstall-from-ISO + re-add a few remotes.
- **`pdm-config-backup.sh` duplicates `pbs-config-backup.sh`** rather than generalizing both into one shared script. Chosen to avoid touching the shipped + armed `pbs-config-backup` path (regression risk to the live backup tier) while the user validates this branch. A clean follow-up is a single `scripts/proxmox-config-backup.sh` with generic env-var names (`CONFIG_SOURCE`, `CONFIG_DEST_DIR`, …) consumed by both roles — surfaced to the operator, not done unprompted.
- **`hosts.j2` resolves both PVE and PBS** (the remotes PDM manages), via `pve_hosts` + `pbs_hosts` mirror groups in the inventory. The NAS is named only so the guardian's poll target reads cleanly — PDM has no NAS storage relationship.

---

## Cross-cutting touchpoints NOT auto-applied

These live outside this role and need separate action:

- **Monitoring.** pdm01 is a new physical host not yet scraped by the monitoring stack. Adding a node_exporter + a Prometheus target + a physical-hosts dashboard entry mirrors how the PVE nodes + pbs01 are wired. Not done here. The `sensors_kernel_modules` comment placeholder in the inventory is for that role's consumption (defaults to `[coretemp]`; run `sensors-detect` on pdm01 to find any fan-tach module).
- **Design vault** `[[nut-ordered-shutdown-design]]` — add the pdm01 75% tier above pbs01.
- **`docs/0-scratch-build-order.md`** — a PDM phase could be added after the PBS phase if PDM becomes part of the canonical rebuild order. Left out pending the operator's call (PDM is a convenience layer, not a dependency of any other tier).

---

## Validation outcomes

- `bash -n scripts/pdm-config-backup.sh scripts/nas-ups-guardian.sh` — clean.
- `shellcheck` on both — clean.
- `ansible-playbook --syntax-check` against the example inventory — see the branch's apply notes.
- `ansible-lint` (production profile) — see the branch's apply notes.
- Real-host apply against pdm01 is the operator's gate. Prereq before first apply: the operator's SSH key must be on `root@pdm01` (the ISO install doesn't have it yet) — `ssh-copy-id` once, or paste it, then `just pdm-hosts`.
