# CLAUDE.md — pdm-hosts (layer 0 PDM host bootstrap)

> **Purpose.** Design spec + persistent context for Claude Code (or any AI tool) working on the `pdm-host` Ansible role under `pdm-hosts/ansible/roles/pdm-host/`. Read this fully before changing the role.

Read the **repo-level** `CLAUDE.md` at the root first if you haven't — tone, no-emojis style, public-repo hygiene, secrets-from-the-operator's-credential-store philosophy. The conventions below extend those.

Read the sibling [`pbs-hosts/CLAUDE.md`](../pbs-hosts/CLAUDE.md) for the layer-0 pattern this role mirrors. `pdm-host` is a **slim cousin** of `pbs-host`: same bootstrap spine, minus everything PBS-specific. Where they diverge is called out below.

---

## Why this folder exists, in one paragraph

`pve-hosts/` configures the hypervisors; `pbs-hosts/` configures the backup target; `pdm-host` is the parallel role for **Proxmox Datacenter Manager** — the central management plane (web UI on 8443) that adds the PVE clusters + PBS as *remotes* and gives a unified overview, cross-cluster migrations, and bulk actions. PDM runs on its own bare-metal mini-PC. It holds **no guest workloads and no datastore**, so its config surface is much smaller than PBS's: no NFS datastore, no datastore/jobs/API-token tasks, no high-throughput sysctl tuning. What remains is the shared layer-0 spine — repo swap, packages, time, `/etc/hosts`, ufw, the operator SSH key — plus the two opt-in extras (UPS guardian, config self-backup).

---

## Host context

One PDM host. Dedicated x86 mini-PC running stock Proxmox Datacenter Manager (Debian 13 / trixie) installed from the PDM ISO.

| Host | Role |
|---|---|
| `pdm01` | Central management plane. Remotes: the PVE cluster + pbs01. |

Network: single LAN port on the same switched LAN as the PVE cluster, PBS, and the NAS. No TB fabric; no bridges; no VLANs at this layer. PDM reaches its remotes (PVE/PBS APIs) and — only when the UPS guardian is enabled — the NAS upsd, all as a **client**. Nothing inbound except SSH (22) and the web UI/API (8443).

Storage: PDM stores its state in `/etc/proxmox-datacenter-manager` (remote list, per-remote API tokens + TLS fingerprints, ACLs, users). No datastore, no NFS mount by default.

---

## What the role MUST do

In roughly this task-file order (wire into `tasks/main.yml` via `ansible.builtin.import_tasks:` — static composition so syntax errors surface during `--syntax-check`):

1. **`repo.yml` — APT repos.** Remove the ISO's `pdm-enterprise.sources` (and a defensive `.list`), which 401 without a subscription. Write deb822 no-subscription sources: Debian base (trixie + updates + security) and PDM no-subscription — `http://download.proxmox.com/debian/pdm`, component `pdm-no-subscription`, suite `{{ pdm_repo_distribution }}` (`trixie`). Ensure `proxmox-archive-keyring` is present (Signed-By). `apt update` via handler only when the sources change, then `flush_handlers` before installs. The four bootstrap tasks + the `Apt update` handler carry `check_mode: false` so `--check` works on a cold host (see the header comment in `repo.yml` for the rationale — same trade-off as `pbs-host`). Reference: https://pdm.proxmox.com/docs/installation.html

2. **`packages.yml` — base packages.** `state: present` (not latest): `chrony`, `ufw`. **No `nfs-common`** in the baseline — PDM mounts nothing by default; `config_backup.yml` pulls `nfs-common` itself when enabled. The role does NOT install the PDM package — that's the ISO's job (mirrors `pbs-host` not installing `proxmox-backup-server`).

3. **`time.yml` — chrony.** Disable + mask `systemd-timesyncd`; template `/etc/chrony/chrony.conf`; enable + start chrony. Same NTP targets as the rest of the lab. PDM is a time *client* only — no `allow` stanza (unlike the PBS template).

4. **`hosts_file.yml` — `/etc/hosts`.** Template: localhost, PDM host(s), the PVE cluster + PBS host(s) (the remotes — resolution only, from the `pve_hosts` / `pbs_hosts` mirror groups), and the NAS (named only for the UPS guardian poll target).

5. **`firewall.yml` — ufw.** Default deny inbound / allow outbound. Allow from `pdm_lan_subnet`: SSH (22), PDM web UI + API (**8443**, HTTPS). ICMP echo via Debian's stock `before.rules` (no `ufw:` rule). Enable ufw last. `loop_var: tcp_port` (not `port` — shadows the module keyword).

6. **`users.yml` — SSH key.** `ansible.posix.authorized_key` installs `admin_ssh_pubkey` for `root`. No-op if empty.

7. **`ups.yml` — UPS shutdown guardian (opt-in, default OFF).** Gated on `pdm_host_manage_ups_guardian` via the `import_tasks` `when:`. Installs `nut-client`, deploys the shared `scripts/nas-ups-guardian.sh`, renders `/etc/default/nas-ups-guardian` (`GUARDIAN_MODE=pdm` + NUT target + thresholds), installs + enables a systemd timer→oneshot polling `upsc` every ~20s. On battery AND `battery.charge ≤ pdm_host_ups_charge_threshold` (default **75** — above pbs01's 70% and the PVE nodes' 60%) it stops the PDM API daemons (`proxmox-datacenter-api` + `proxmox-datacenter-privileged-api`), waits a short `pdm_host_ups_drain_grace`, then powers off. **PDM carries no data-path ordering constraint** (it's not an NFS client) — it goes first only because a management plane is useless mid-outage and shedding it recovers a little runtime. Applying the role must NEVER power off the host. Mirror of the `pbs-host` `ups.yml`; reload/restart tasks are `when: <unit> is changed`.

8. **`config_backup.yml` — config self-backup (opt-in, default OFF), last.** Gated on `pdm_host_manage_config_backup`. **Unlike PBS, PDM has no standing NFS mount**, so this task folds in: `apt install nfs-common` → `ansible.posix.mount` the NAS export → ensure the `0700` dest dir → deploy the shared `scripts/pdm-config-backup.sh` → render `/etc/default/pdm-config-backup` → install + enable a systemd timer→oneshot that tars `/etc/proxmox-datacenter-manager` to a timestamped `.tar.gz` on the NAS and ages out old ones. A default install (toggle OFF) mounts nothing. The tarball carries per-remote API tokens, so `0600` in a `0700` dir; the unit's `RequiresMountsFor` + a `findmnt` guard in the script refuse to write to local disk if the mount is down. Plain tarball (not a backup-client snapshot) so it's openable on a fresh box. Applying the role must NEVER trigger an out-of-schedule backup.

---

## What the role MUST NOT do

- **The PDM ISO install itself** (USB prep, partitioning, hostname/IP).
- **Adding remotes.** Registering the PVE clusters + PBS as PDM remotes is a web-UI ceremony consuming per-remote API tokens from the operator's credential store. Manual, one-time, no automation — same stance as the PVE/PBS token conventions. Never add a task that creates a remote, generates/surfaces a token, or writes one to disk.
- **Installing the PDM package.** The ISO ships it. (If a future apt-on-Debian variant is needed, that's `proxmox-datacenter-manager-container-meta` — but this role targets ISO installs.)
- **TLS cert replacement.** PDM ships self-signed; the Root-CA migration is a separate future task shared with PVE/PBS.
- **High-throughput sysctl tuning.** PDM is an API proxy + web UI, not a chunk store — the PBS TCP-buffer tuning has no rationale here. (This is why there's no `tuning.yml` / `99-pdm-host.conf`.)
- **`apt upgrade` / `dist-upgrade`.** `present`, not `latest`.
- **Reboots. GRUB/kernel edits. Anything `pveum`/`pvecm`/`pvesh`/`proxmox-backup-manager`** — wrong host.

---

## Divergences from `pbs-host` (the parts that are NOT a rename)

If you came here expecting a 1:1 copy of `pbs-host`, these are the real differences:

- **No `nfs.yml`, no `pbs_datastore.yml` / `pbs_users.yml` / `pbs_jobs.yml`.** PDM has no datastore, no service-ingress token, no scheduled jobs.
- **No `tuning.yml` / sysctl drop-in.** Deleted, not gated off (repo convention: delete dead scaffolding). PDM is a lightweight management plane.
- **No `vars/main.yml`.** `pbs-host` kept the `proxmox-backup-manager` binary path there; `pdm-host` calls no PDM CLI, so there are no role-internal constants.
- **Firewall port is 8443**, not 8007.
- **config-backup mounts NFS itself** (folded into `config_backup.yml`, gated by the same toggle), because PDM has no datastore mount to piggyback on. PBS's config-backup just wrote to the already-present datastore mount.
- **config-backup DR value is lower.** PDM holds no data; the tarball saves you re-adding remotes by hand, nothing more. Recommend leaving it OFF until PDM's config is worth the standing NFS mount + export ACL.
- **UPS guardian tier is 75% and carries no data-path meaning.** `drain_pdm()` in the shared script just stops the API daemons. pbs01/PVE lead the NAS because they write to it; pdm01 leads them only by convention.

---

## Shared scripts touched

- **`scripts/nas-ups-guardian.sh`** gained a `pdm` mode: a `drain_pdm()` that stops the PDM API daemons + a short grace, a `pdm)` case branch, a `PDM_DRAIN_GRACE` default, and the tier diagram + `GUARDIAN_MODE (pve|pbs|pdm)` doc updated. Purely additive — pve/pbs behavior unchanged.
- **`scripts/pdm-config-backup.sh`** is new — a PDM-named sibling of `scripts/pbs-config-backup.sh` (config dir `/etc/proxmox-datacenter-manager`, `PDM_CONFIG_*` env vars, token-bearing rather than authkey-bearing). The two scripts are near-identical; they were kept separate to avoid touching the shipped+armed `pbs-config-backup` path. A future cleanup could generalize both into one `proxmox-config-backup.sh` with generic env-var names — see SCAFFOLD-NOTES.

---

## Idempotency, safety, style — non-negotiable

1. Every task idempotent — a healthy re-run is `changed=0`.
2. No reboots. Surface, don't trigger.
3. Fail loudly on missing required vars (`pdm_lan_ip`); empty `admin_ssh_pubkey` is allowed (warn).
4. FQCN everywhere.
5. Header comments on every file — what it does, when it runs, idempotency story, quirks.
6. No emojis. Avoid "genuinely", "straightforward", "actually".
7. Comments cite vault docs in `[[bracketed-name]]` form.

---

## Acceptance gates — before claiming done

Local gates (no real host). The real-host apply is the operator's, who validates reproducibility himself.

```bash
# 1. Syntax check (Ansible's YAML inventory plugin needs a .yml suffix).
cd pdm-hosts/ansible
cp inventory.yml.example /tmp/pdm-inventory.yml
ansible-playbook -i /tmp/pdm-inventory.yml site.yml --syntax-check
rm /tmp/pdm-inventory.yml

# 2. Lint
ansible-lint pdm-hosts/ansible/roles/pdm-host/

# 3. Shell helpers
bash -n scripts/pdm-config-backup.sh scripts/nas-ups-guardian.sh
shellcheck scripts/pdm-config-backup.sh scripts/nas-ups-guardian.sh
```

(`just check-roles` does not apply here — it scopes `vms/*/terraform/`, and the layer-0 host roles are Ansible-only, same as `pve-hosts` / `pbs-hosts`.)

Local `--check --connection=local` is not a practical gate on macOS (the apt module needs `python3-apt`, which doesn't exist on macOS) — same limitation as `pbs-host`.

---

## Implementation record

[`ansible/roles/pdm-host/SCAFFOLD-NOTES.md`](ansible/roles/pdm-host/SCAFFOLD-NOTES.md) records what was generated, assumptions, deviations + rationale, and validation outcomes. This CLAUDE.md is the spec; SCAFFOLD-NOTES is what was built.

---

## Design vault (operator-only)

Ordered-shutdown rationale: `[[nut-ordered-shutdown-design]]`. PDM's place in the management-plane architecture lives in the private design vault — ask the maintainer if a decision is ambiguous rather than guessing.
