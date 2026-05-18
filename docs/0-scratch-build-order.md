<!-- markdownlint-disable MD029 -->
<!-- MD029 disabled file-wide: the 19 steps below are continuously numbered
     across Phase 1-4 headings on purpose, so cross-references like "depends
     on step 14" are unambiguous. Restart-at-1-per-heading would break
     that. -->

# Scratch build order — fresh cluster from bare metal

Read top-to-bottom if you're standing up the homelab from scratch (or rebuilding the whole cluster). Each step points at the authoritative doc — this file is an **index**, not a runbook duplicate. Skip ahead if you're only doing a partial rebuild (single-node reinstall, inventory tweak, etc.); the "Partial rebuilds" section near the bottom calls out the common shortcuts.

The full sequence is five phases:

- **Phase 1 — Substrate** (per-node, before clustering): NAS, BIOS, install, role baseline.
- **Phase 2 — Cluster bring-up**: `pvecm`, cluster-wide policy + storage.
- **Phase 2.5 — Backup target**: PBS host install + baseline + PVE-side storage registration. Sequenced before IaC enablement so VMs created in Phase 4 have a backup target from day one.
- **Phase 3 — IaC enablement**: API users, workstation, base templates.
- **Phase 4 — Per-role deploys**: VMs, eGPU passthrough when needed.

Optional hardening (mail, non-root admin) lives at the end — not blockers for any role.

---

## Phase 1 — Substrate

Per-node prep. Steps 1 + 2 can run in parallel (NAS-side prep doesn't depend on the NUC installs).

1. **NAS NFS export ready** — [docs/asustor-nas-setup.md](asustor-nas-setup.md). Enable NFS server on the Asustor, create the shared folder (`/volume1/proxmox-vms`), set export ACLs (subnet matching `pve_lan_subnet` from inventory, sync, no-root-squash or matched UID). Must land before `pve-host`'s `nfs.yml` task runs.

2. **Bare-metal PVE 9.x install on each NUC** — [docs/proxmox-install.md](proxmox-install.md). USB media, BIOS prereqs (IOMMU on, Secure Boot off), installer click-through, per-node root password from KeePassXC, filesystem layout. On `pve12t` only: post-install creation of the `nuc12-fast` LVM-thin pool on a dedicated 2.5" SATA SSD (1 TB in this lab; see [docs/proxmox-install.md § 2](proxmox-install.md) for the `pvcreate` → `vgcreate nuc12fast_vg` → `lvcreate -T` → `pvesm add` sequence, plus the fallback if the node has no second drive). Repeat the install for `pve12t`, `pve13m`, `pve13t`. Outputs three PVE 9.x hosts reachable on the LAN.

3. **TB4 cables** — physical wiring per the vault doc `[[Thunderbolt Mesh Networking — 3-Node Cluster Option]]`. Line topology: `pve12t ── pve13m ── pve13t`. Plug after the installs are done. Everything else TB is role-managed.

4. **Fill in `inventory.yml`** — [pve-hosts/ansible/inventory.yml.example](../pve-hosts/ansible/inventory.yml.example) → `inventory.yml`. Replace TODOs: LAN IPs, NAS IP, your SSH pubkey. Verify `pve_lan_iface` per host (`ip link` on each — PVE 9.x typically renames to `nic0`).

5. **Apply the `pve-host` baseline** — [pve-hosts/README.md](../pve-hosts/README.md). From the workstation: `just pve-hosts-deps` (collections, one-time), `just pve-hosts-check` (dry-run), `just pve-hosts` (apply). Installs `bolt`, enrolls TB peers, discovers TB pci_paths, templates `/etc/network/interfaces`, mounts NFS, drops firewall baseline, installs operator SSH key.

6. **`ifreload -a` from each host's console** (not over SSH — TB interface name changes can drop the connection). Verify with `ip addr show`, `ip route show`, and a TB ping (`ping 10.10.0.1` from `pve12t` to `pve13m`).

---

## Phase 2 — Cluster bring-up

**This entire phase has a dedicated runbook: [docs/cluster-bring-up.md](cluster-bring-up.md).** Don't try to execute Phase 2 from this index — drop into the runbook and follow it end-to-end. It covers the prerequisite checks, `pvecm create` on the creator, the two `pvecm add` invocations on the joiners, corosync ring1 over the TB fabric, migration-network setting, cluster-firewall enablement, `snippets` content type on `local`, NFS storage registration as `nas-vms`, verification at each step, and recovery from common failures.

7. **Cluster bring-up + post-formation storage/policy** — follow [docs/cluster-bring-up.md](cluster-bring-up.md). Quorum-aware; never automated. Architecture rationale in the vault: `Projects/Homelab/VM Mobility — 3-Node Cluster on 2.5GbE.md`.

---

## Phase 2.5 — Backup target (PBS)

Stand up the Proxmox Backup Server host between cluster bring-up and IaC enablement so the first VMs in Phase 4 can be backed up immediately. PBS lives on dedicated hardware (not as a VM on the cluster) per the circular-dependency reasoning in the vault doc `Projects/Homelab/Proxmox Backup Server — Capabilities and Tiered Storage.md`.

7a. **NAS-side PBS export ready** — [docs/asustor-nas-setup.md § Export for the PBS bulk datastore](asustor-nas-setup.md#export-for-the-pbs-bulk-datastore). Create the second NFS export (`/volume1/proxmox-backups`), distinct from `proxmox-vms`, with `no_root_squash` + `sync` restricted to the PBS host's `/32`. Can run in parallel with step 7b.

7b. **Bare-metal PBS 4.x install on `pbs01`** — [docs/pbs-install.md](pbs-install.md). USB media, BIOS prereqs (UEFI, Secure Boot off), installer click-through, per-host root password from KeePassXC, hostname `pbs01.local`. Single 2.5GbE port; no TB. Outputs one PBS 4.x host reachable on the LAN.

7c. **Fill in PBS `inventory.yml`** — [pbs-hosts/ansible/inventory.yml.example](../pbs-hosts/ansible/inventory.yml.example) → `inventory.yml`. Replace TODOs: LAN IP, NAS IP, your SSH pubkey, datastore name. Keep the `pve_hosts` mirror block synchronized with the PVE-side inventory's LAN IPs.

7d. **PBS UI prereq — create the `pveingress` user + `cluster` API token, store the secret in KeePassXC.** Operator-managed (PBS generates the secret on creation; same convention as `tofu@pve` / `packer@pve`). The full walkthrough — including the three-names disambiguation (User ID `pveingress` vs Token Name `cluster` vs KP entry title `pveingress-cluster`) and the field layout (KP `Password` field for the random UI password, `Notes` field for `pveingress@pbs!cluster=<secret>`) — lives in [pbs-hosts/README.md](../pbs-hosts/README.md) "Quick start" step 3. Done before step 7e; step 7e's asserts fail loudly without it.

7e. **Apply the `pbs-host` baseline** — [pbs-hosts/README.md](../pbs-hosts/README.md). From the workstation: `just pbs-hosts-deps` (collections, one-time), `just pbs-hosts-check` (dry-run), `just pbs-hosts` (apply). Configures APT, packages, chrony, NFS mount, ufw, datastore creation, verify + prune + GC schedules. Asserts the `pveingress@pbs!cluster` token from step 7d exists and grants it `DatastoreAdmin` on each datastore (the role never reads the cleartext secret — only the auth-id). `DatastoreAdmin` is used rather than `DatastoreBackup` because PVE's storage-registration handshake in step 7f needs `Datastore.Audit`, which `DatastoreBackup` doesn't include — see `pbs-hosts/ansible/roles/pbs-host/defaults/main.yml` for the rationale.

7f. **Register PBS as a PVE storage target — manual, one-time per cluster.** Deliberately unautomated: one `pvesm add pbs ...` call lands the storage entry in `/etc/pve/storage.cfg`, pmxcfs replicates it to every node, and it stays for the life of the cluster.

   > **Run this from any PVE cluster node — NOT from `pbs01`.** `pvesm` is a Proxmox VE command (not PBS) and the storage entry has to land in `/etc/pve/storage.cfg`, which only exists on the PVE cluster's pmxcfs. Running it on `pbs01` would fail with command-not-found, and even if you reached for the PBS CLI you'd be editing the wrong system. Pick any one of `pve12t`, `pve13m`, `pve13t`; pmxcfs replicates the result to all three.

   ```bash
   pvesm add pbs pbs01-bulk \
     --server <pbs01_ip> \
     --datastore bulk \
     --username 'pveingress@pbs!cluster' \
     --password '<token-secret>' \
     --fingerprint '<pbs-cert-sha256-fingerprint>'
   ```

   Single-quote `--username` (and `--password`) — the `!` in the auth-id is bash/zsh history-expansion in interactive shells, and double quotes do *not* suppress it. Single quotes pass it literally.

   `<token-secret>` comes from KeePassXC `Homelab/PBS/pveingress-cluster`'s Notes field — the stored value has shape `pveingress@pbs!cluster=<secret>`, paste only the portion *after* `=` into `--password`. `<pbs-cert-sha256-fingerprint>` comes from the PBS web UI's certificate (browser lock icon → "View certificate" → SHA-256 fingerprint), or on pbs01 via `openssl x509 -in /etc/proxmox-backup/proxy.pem -fingerprint -sha256 -noout`. Verify in the PVE web UI → Datacenter → Storage: `pbs01-bulk` should appear with type PBS, available on every node.

---

## Phase 3 — IaC enablement

8. **Create the Packer API user + token** — [docs/proxmox-permissions.md](proxmox-permissions.md). User `packer@pve`, role `packer-build`, token `builder`. Store secret in KeePassXC. One-time, cluster-wide.

9. **Create the OpenTofu API user + token** — [docs/proxmox-tofu-permissions.md](proxmox-tofu-permissions.md). User `tofu@pve`, role `tofu-provision` (Packer's role minus `VM.Config.CDROM` and `VM.Console`), token. Store in KeePassXC.

10. **Workstation setup** — [docs/opentofu-setup.md](opentofu-setup.md). Install `opentofu`, configure the `hydrate.sh` flow to read tokens from KeePassXC at apply time.

11. **Build the Ubuntu 24.04 base template on every cluster node, with distinct VMIDs** — [packer/ubuntu-24-04-base/README.md](../packer/ubuntu-24-04-base/README.md). Required for every Linux role downstream. See [ADR-0006](decisions/0006-packer-templates-per-node.md) for why per-node templates with distinct VMIDs (rather than one shared template on NFS, or one template + cross-node clone).

    **Per-node VMID convention** (matches [`local.ubuntu_template_ids`](../vms/openbao/terraform/main.tf) in every Linux role and the case statement in [`scripts/preflight.sh`](../scripts/preflight.sh)):

    | Node | Ubuntu base VMID | Windows base VMID (future) |
    | --- | --- | --- |
    | `pve12t` | 9100 | 9200 |
    | `pve13m` | 9101 | 9201 |
    | `pve13t` | 9102 | 9202 |

    VMIDs are cluster-wide unique post-cluster — building the same VMID on two nodes fails with HTTP 500 ("VM 9100 already exists"). The Windows series skips up by 100 to leave room for additional Linux variants.

    **Env files (one per host).** The wrapper sources `.env.<node>`. Token + secret are cluster-replicated via `/etc/pve/user.cfg`, so the per-host deltas are `PROXMOX_URL`, `PROXMOX_NODE`, and `VM_ID`:

    ```bash
    cd packer/ubuntu-24-04-base
    cp .env.example .env.pve12t && $EDITOR .env.pve12t   # fill PROXMOX_TOKEN_* once
    sed -e 's/pve12t/pve13m/g' -e 's/^VM_ID="9100"/VM_ID="9101"/' \
        .env.pve12t > .env.pve13m
    sed -e 's/pve12t/pve13t/g' -e 's/^VM_ID="9100"/VM_ID="9102"/' \
        .env.pve12t > .env.pve13t
    chmod 600 .env.pve12t .env.pve13m .env.pve13t
    ```

    Files are gitignored; `chmod 600` because they hold the token secret.

    **Build (one invocation per host):**

    ```bash
    ./build-pve.sh pve12t       # VM 9100 on pve12t
    ./build-pve.sh pve13m       # VM 9101 on pve13m
    ./build-pve.sh pve13t       # VM 9102 on pve13t
    ```

    Each run takes ~20–30 min on an NUC12.

    **Role coupling.** Linux roles look up the right VMID via a local map keyed on `proxmox_node` — see `local.ubuntu_template_ids` in [vms/openbao/terraform/main.tf](../vms/openbao/terraform/main.tf). Copy that block (or its evolving form) into every new Linux role so the lookup stays consistent.

    **Auth note:** Packer uses the Proxmox API over HTTPS only — the token in `.env.<node>` (from step 8) is sufficient. The workstation→PVE SSH setup from step 10 §2 is OpenTofu-specific (`bpg/proxmox` uploads cloud-init snippets over SSH) and is not a prerequisite for this step.

12. **(Optional) Build the Windows 11 base template** — [packer/windows-11-base/README.md](../packer/windows-11-base/README.md). Two targets — `proxmox-iso` (per-node Windows base; VMIDs `9200`/`9201`/`9202` for `pve12t`/`pve13m`/`pve13t`, same per-node-distinct-VMID rule as step 11 — see [ADR-0006](decisions/0006-packer-templates-per-node.md)) and `virtualbox-iso` (T480-only; outputs qcow2 for libvirt). Required only if you'll deploy Windows roles.

    `packer/windows-11-base/` defaults to `VM_ID=9200` (pve12t); bump per node when fanning out the env files (`9201` for pve13m, `9202` for pve13t) — same pattern as the Ubuntu series. Future Windows roles will need their own `local.windows_template_ids` map in role tfvars (analogous to the Ubuntu one in [`vms/openbao/terraform/main.tf`](../vms/openbao/terraform/main.tf)).

---

## Phase 4 — Per-role deploys

13. **Read the role-class chooser + 7-step VM flow first** — [docs/deploying-vms.md](deploying-vms.md). Orients you on which existing role to copy from for a new role, and walks the repeatable apply loop.

14. **First role: OpenBao** (or whichever you want first) — [vms/openbao/README.md](../vms/openbao/README.md). Canonical example of the current OpenTofu + Ansible + cloud-init shape; copy this as the template for new roles. Before `tofu apply`, run `scripts/preflight.sh openbao` — it looks up the per-node template VMID from its case statement and verifies it exists on the node the role's tfvars targets. If step 11 wasn't run for that node, this is where it surfaces.

15. **eGPU passthrough plumbing on `pve12t`** — [docs/proxmox-gpu-passthrough.md](proxmox-gpu-passthrough.md). One-time, only when you're ready to host the LLM VM. Requires reboots + GRUB edits; deferred until needed.

16. **LLM VM** — [vms/llm/README.md](../vms/llm/README.md). Depends on step 15 being complete on `pve12t`.

---

## Optional hardening / ops

Neither of these blocks any role. Captured here so the manual-step inventory is complete.

- **Outbound mail destination** (postfix satellite mode for SMART warnings + cron output + backup-job failure notices) — see [pve-hosts/README.md § Optional follow-ups](../pve-hosts/README.md#optional-follow-ups).
- **Non-root `pveum` admin user for the web UI** — same section.

---

## Partial rebuilds

Common shortcuts when you don't need the whole sequence:

- **Single-node reinstall** (DR or hardware swap): repeat steps 2, 4 (just that host's entries), 5, 6 against the one node. Then `pvecm add` to rejoin per `docs/cluster-bring-up.md`. Don't re-run `pvecm create`. Re-run step 11 (and step 12 if you use Windows roles) against the rebuilt node so its local `local-lvm` regains the 9100/9101 templates at the cluster-standard VMIDs.
- **PBS host reinstall** (DR or hardware swap): repeat steps 7a-7d for the rebuilt host. The API token from 7e is *not* recoverable — delete the stale token on the PVE side, regenerate via the role on first apply, and re-paste into KeePassXC. The on-NFS chunk store survives the OS reinstall; `proxmox-backup-manager datastore create` is idempotent and will re-attach to existing on-disk content.
- **Inventory change only** (new SSH key, added DNS entry, NAS-IP rotation): re-run step 5. The role is idempotent on healthy nodes.
- **NAS export reconfigured** (path change, ACL tweak): re-run step 1, then update `inventory.yml`'s `nas_*` vars, re-run step 5. If the storage path changed, also update Proxmox's NFS storage def (`docs/cluster-bring-up.md` Step 8).
- **New role on existing cluster**: skip Phase 1-2. Start at step 14.
- **Token rotation**: re-run step 8 or 9 with `--privsep 0 --comment <date>`; update KeePassXC.

---

## Vault references

Authoritative design docs (read for context; don't modify them from this repo):

- `Projects/Homelab/00-Homelab-MOC.md` — index over the whole homelab folder.
- `Projects/Homelab/Thunderbolt Mesh Networking — 3-Node Cluster Option.md` — TB line topology decision + bring-up runbook. Authoritative on TB IPs, link plan, `ip_forward` placement.
- `Projects/Homelab/VM Mobility — 3-Node Cluster on 2.5GbE.md` — cluster + NFS architecture.
- `Projects/Homelab/Homelab Inventory.md` — hardware specifics.
