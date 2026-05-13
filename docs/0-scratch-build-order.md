<!-- markdownlint-disable MD029 -->
<!-- MD029 disabled file-wide: the 19 steps below are continuously numbered
     across Phase 1-4 headings on purpose, so cross-references like "depends
     on step 14" are unambiguous. Restart-at-1-per-heading would break
     that. -->

# Scratch build order — fresh cluster from bare metal

Read top-to-bottom if you're standing up the homelab from scratch (or rebuilding the whole cluster). Each step points at the authoritative doc — this file is an **index**, not a runbook duplicate. Skip ahead if you're only doing a partial rebuild (single-node reinstall, inventory tweak, etc.); the "Partial rebuilds" section near the bottom calls out the common shortcuts.

The full sequence is four phases:

- **Phase 1 — Substrate** (per-node, before clustering): NAS, BIOS, install, role baseline.
- **Phase 2 — Cluster bring-up**: `pvecm`, cluster-wide policy + storage.
- **Phase 3 — IaC enablement**: API users, workstation, base templates.
- **Phase 4 — Per-role deploys**: VMs, eGPU passthrough when needed.

Optional hardening (mail, non-root admin) lives at the end — not blockers for any role.

---

## Phase 1 — Substrate

Per-node prep. Steps 1 + 2 can run in parallel (NAS-side prep doesn't depend on the NUC installs).

1. **NAS NFS export ready** — [docs/asustor-nas-setup.md](asustor-nas-setup.md). Enable NFS server on the Asustor, create the shared folder (`/volume1/proxmox-vms`), set export ACLs (subnet `192.168.1.0/24`, sync, no-root-squash or matched UID). Must land before `pve-host`'s `nfs.yml` task runs.

2. **Bare-metal PVE 9.x install on each NUC** — [docs/proxmox-install.md](proxmox-install.md). USB media, BIOS prereqs (IOMMU on, Secure Boot off), installer click-through, per-node root password from KeePassXC, filesystem layout. On `pve12t` only: post-install creation of the `nuc12-fast` LVM-thin pool on a dedicated 2.5" SATA SSD (1 TB in this lab; see [docs/proxmox-install.md § 2](proxmox-install.md) for the `pvcreate` → `vgcreate nuc12fast_vg` → `lvcreate -T` → `pvesm add` sequence, plus the fallback if the node has no second drive). Repeat the install for `pve12t`, `pve13m`, `pve13t`. Outputs three PVE 9.x hosts reachable on the LAN.

3. **TB4 cables** — physical wiring per the vault doc `[[Thunderbolt Mesh Networking — 3-Node Cluster Option]]`. Line topology: `pve12t ── pve13m ── pve13t`. Plug after the installs are done. Everything else TB is role-managed.

4. **Fill in `inventory.yml`** — [pve-hosts/ansible/inventory.yml.example](../pve-hosts/ansible/inventory.yml.example) → `inventory.yml`. Replace TODOs: LAN IPs, NAS IP, your SSH pubkey. Verify `pve_lan_iface` per host (`ip link` on each — PVE 9.x typically renames to `nic0`).

5. **Apply the `pve-host` baseline** — [pve-hosts/README.md](../pve-hosts/README.md). From the workstation: `just pve-hosts-deps` (collections, one-time), `just pve-hosts-check` (dry-run), `just pve-hosts` (apply). Installs `bolt`, enrolls TB peers, discovers TB pci_paths, templates `/etc/network/interfaces`, mounts NFS, drops firewall baseline, installs operator SSH key.

6. **`ifreload -a` from each host's console** (not over SSH — TB interface name changes can drop the connection). Verify with `ip addr show`, `ip route show`, and a TB ping (`ping 10.10.0.1` from `pve12t` to `pve13m`).

---

## Phase 2 — Cluster bring-up

7. **Cluster join (`pvecm create` + `pvecm add` + corosync ring1 over TB)** — full runbook in [docs/cluster-bring-up.md](cluster-bring-up.md). Quorum-aware; never automated. Covers the prerequisite checks, `pvecm create homelab --link0 <pve12t-ip>` on the creator, two `pvecm add` invocations on the joiners (with the empty-`/etc/pve/qemu-server` requirement), the corosync.conf edit for ring1 over the TB loopback subnet, verification, and recovery from common failures. Architecture rationale is in the vault: `Projects/Homelab/VM Mobility — 3-Node Cluster on 2.5GbE.md`.

8. **Cluster-wide `pve-firewall` enable.** The `pve-host` role staged the cluster.fw rules with `enable: 0` so the firewall is inert pre-cluster (avoiding the asymmetric-state hazard where the delegate filters but peers don't). Now that pmxcfs replicates the file cluster-wide, turn it on: Datacenter → Firewall → Options → Enable (UI writes `enable: 1` to cluster.fw), or `sed -i 's/^enable: 0/enable: 1/' /etc/pve/firewall/cluster.fw` on any node. Verify SSH still works to every node before walking away.

9. **Enable `snippets` content type on `local`** — `pvesm set local --content snippets,iso,vztmpl,backup,images,rootdir`. Required before any `tofu apply` — without it, the `bpg/proxmox` provider's snippet upload silently no-ops. One-time, cluster-wide (replicates via pmxcfs).

10. **Register the NAS NFS as cluster storage `nas-vms` (with `snippets` in `--content`).** Via UI (Datacenter → Storage → Add → NFS, tick Disk image + VZDump backup + Snippets) or `pvesm add nfs nas-vms --server <nas-ip> --export /volume1/proxmox-vms --content images,backup,snippets --options vers=4.2`. The role mounted the share at the filesystem level (`/mnt/nas-vms`); Proxmox's storage layer still needs to be told about it. Including `snippets` here keeps cluster-mobile VMs' cloud-init snippets reachable post-live-migration. If you used the UI and forgot the Snippets tick, fix with `pvesm set nas-vms --content snippets,images,backup`.

---

## Phase 3 — IaC enablement

11. **Create the Packer API user + token** — [docs/proxmox-permissions.md](proxmox-permissions.md). User `packer@pve`, role `packer-build`, token `builder`. Store secret in KeePassXC. One-time, cluster-wide.

12. **Create the OpenTofu API user + token** — [docs/proxmox-tofu-permissions.md](proxmox-tofu-permissions.md). User `tofu@pve`, role `tofu-provision` (Packer's role minus `VM.Config.CDROM` and `VM.Console`), token. Store in KeePassXC.

13. **Workstation setup** — [docs/opentofu-setup.md](opentofu-setup.md). Install `opentofu`, configure the `hydrate.sh` flow to read tokens from KeePassXC at apply time.

14. **Build the Ubuntu 24.04 base template** — [packer/ubuntu-24-04-base/README.md](../packer/ubuntu-24-04-base/README.md). Produces template VM 9100 on whichever PVE node you target. Required for every Linux role downstream.

15. **(Optional) Build the Windows 11 base template** — [packer/windows-11-base/README.md](../packer/windows-11-base/README.md). Two targets — `proxmox-iso` (template VM 9101 on a PVE node) and `virtualbox-iso` (T480-only; outputs qcow2 for libvirt). Required only if you'll deploy Windows roles.

---

## Phase 4 — Per-role deploys

16. **Read the role-class chooser + 7-step VM flow first** — [docs/deploying-vms.md](deploying-vms.md). Orients you on which existing role to copy from for a new role, and walks the repeatable apply loop.

17. **First role: OpenBao** (or whichever you want first) — [vms/openbao/README.md](../vms/openbao/README.md). Canonical example of the current OpenTofu + Ansible + cloud-init shape; copy this as the template for new roles.

18. **eGPU passthrough plumbing on `pve12t`** — [docs/proxmox-gpu-passthrough.md](proxmox-gpu-passthrough.md). One-time, only when you're ready to host the LLM VM. Requires reboots + GRUB edits; deferred until needed.

19. **LLM VM** — [vms/llm/README.md](../vms/llm/README.md). Depends on step 18 being complete on `pve12t`.

---

## Optional hardening / ops

Neither of these blocks any role. Captured here so the manual-step inventory is complete.

- **Outbound mail destination** (postfix satellite mode for SMART warnings + cron output + backup-job failure notices) — see [pve-hosts/README.md § Optional follow-ups](../pve-hosts/README.md#optional-follow-ups).
- **Non-root `pveum` admin user for the web UI** — same section.

---

## Partial rebuilds

Common shortcuts when you don't need the whole sequence:

- **Single-node reinstall** (DR or hardware swap): repeat steps 2, 4 (just that host's entries), 5, 6 against the one node. Then `pvecm add` to rejoin. Don't re-run `pvecm create`.
- **Inventory change only** (new SSH key, added DNS entry, NAS-IP rotation): re-run step 5. The role is idempotent on healthy nodes.
- **NAS export reconfigured** (path change, ACL tweak): re-run step 1, then update `inventory.yml`'s `nas_*` vars, re-run step 5. If the storage path changed, also update Proxmox's storage def from step 10.
- **New role on existing cluster**: skip Phase 1-2. Start at step 17.
- **Token rotation**: re-run step 12 or 13 with `--privsep 0 --comment <date>`; update KeePassXC.

---

## Vault references

Authoritative design docs (read for context; don't modify them from this repo):

- `Projects/Homelab/00-Homelab-MOC.md` — index over the whole homelab folder.
- `Projects/Homelab/Thunderbolt Mesh Networking — 3-Node Cluster Option.md` — TB line topology decision + bring-up runbook. Authoritative on TB IPs, link plan, `ip_forward` placement.
- `Projects/Homelab/VM Mobility — 3-Node Cluster on 2.5GbE.md` — cluster + NFS architecture.
- `Projects/Homelab/Homelab Inventory.md` — hardware specifics.
