# 0004 — 3-node Proxmox cluster with TB ring1 + NFS shared storage

**Status:** Accepted
**Date:** 2026-05-13

## Context

The lab ran for several months with three NUCs as independent Proxmox hosts — per-node Packer tokens, per-node template builds, no migration path. Three motivations to cluster:

1. **VM mobility.** Migrating cluster-mobile VMs (OpenBao, future amp-game) between hosts without rebuild during maintenance.
2. **Single pane of glass.** One Web UI for cluster state, one ACL surface for API users (Packer, Tofu).
3. **Shared storage.** The Asustor AS6706T can serve `nas-vms` over NFS, making the migration target trivially available.

## Decision

Form a 3-node Proxmox VE cluster (`homelab`) with corosync ring0 on the 2.5GbE LAN and ring1 on a Thunderbolt 4 mesh between the nodes. Migration traffic over the TB fabric (10GbE-class). Cluster firewall enabled. `nas-vms` NFS export registered as cluster-wide storage. CPU type default for cluster-mobile VMs: `x86-64-v3` (common baseline across Alder/Raptor Lake-P/H on these NUCs); `host` only on hardware-pinned VMs (eGPU, USB-HSM passthrough).

## Consequences

- `/etc/pve/user.cfg`, `/etc/pve/storage.cfg`, `/etc/pve/firewall/cluster.fw` now replicate cluster-wide via pmxcfs. `pveum`, `pvesm`, and firewall edits run once on any node.
- TB mesh requires line topology `pve12t ── pve13m ── pve13t`; `pve13m` is the transit node with `ip_forwarding_enabled: true`.
- Storage exceptions remain node-pinned: `nuc12-fast` (LVM-thin on `pve12t`'s 2.5" SATA SSD, for LLM models cache), per-node ISO library.
- Cluster formation (`pvecm create` / `pvecm add`) stays manual — fencing risk too high to automate; runbook lives at `docs/cluster-bring-up.md`.
- Documented operationally in `pve-hosts/` (host baseline Ansible role) + `docs/cluster-bring-up.md`.

## Alternatives considered

- **Stay independent** — simplest, but no migration path means a host outage = service outage until rebuild.
- **2-node cluster** — quorum is fragile; needs a QDevice or external witness. Three nodes is the minimum for natural quorum.
- **ZFS replication instead of NFS shared storage** — rejected. ZFS is off the table for this lab (ext4-on-LVM on hosts, btrfs on NAS, LUKS-on-ext4 inside the Root CA per [0003](0003-root-ca-encryption-in-vm.md)). ZFS-on-Linux memory overhead + ARC sizing on small NUCs is more than it's worth at this scale.
- **Ceph** — way over-tooled for 3 nodes; would dominate the lab's complexity budget.
