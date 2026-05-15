# 0007 — Thunderbolt fabric topology: line, not full mesh

**Status:** Accepted
**Date:** 2026-05-11

## Context

The 3-node Proxmox cluster ([0004](0004-three-node-proxmox-cluster.md)) uses Thunderbolt 4 between nodes for corosync ring1 + live-migration traffic; ring0 stays on the 2.5GbE LAN. The TB physical topology was still open at the time the cluster decision landed.

Each NUC has 2× TB4 ports, but one port on `pve12t` is occupied by the Razer Core X enclosure for the eGPU/RTX 3090 (pinned to `pve12t` for the LLM role). That leaves `pve12t` with one free TB port; `pve13m` and `pve13t` have both ports free. Topology must work within "5 free TB ports across the cluster, not 6."

Shared storage is NFS-on-Asustor ([0004](0004-three-node-proxmox-cluster.md)), not Ceph. The TB fabric carries bursty migration traffic, not sustained replication.

## Decision

Line topology with `pve13m` as the transit node: `pve12t ── pve13m ── pve13t`. Two TB4 cables (~$40 total). `pve13m` enables `ip_forwarding` so `pve12t`↔`pve13t` traffic transits through it (2 hops, ~half the direct-link bandwidth). Per-node TB loopback `/32` addresses on the `10.10.10.0/24` subnet are advertised so every node-to-node pair has a stable IP regardless of which physical link carries the packet — see `pve-hosts/ansible/roles/pve-host/tasks/thunderbolt.yml` for the implementation.

## Consequences

- **`pve13m` is a SPOF for the TB fabric.** Losing `pve13m` drops ring1 cluster-wide; ring0 on 2.5GbE keeps the cluster quorate and operational, just slower for migration. Acceptable because the failure mode is "degraded, not down."
- **`pve12t`↔`pve13t` bandwidth is halved.** Transit through `pve13m` means one TB link carries both legs. Acceptable because migration is bursty, not sustained — no Ceph replication, no continuous `pvesr` load.
- **eGPU/RTX 3090 stays in place.** No enclosure swap, no PCIe-passthrough reconfiguration on the LLM role.
- **Cluster-bring-up gains a `ring1` step** ([cluster-bring-up.md step 4](../cluster-bring-up.md)) that's manual + quorum-aware. Restart corosync one node at a time; never two simultaneously (fencing risk).
- **Reversible** but with hardware cost. Switching to full mesh later requires either (a) moving the eGPU off `pve12t` (frees its second TB port for a third cable) or (b) swapping the Razer Core X for a daisy-chain-capable enclosure ($310–460). Neither is justified at current load.

## Alternatives considered

- **Pair-only (`pve13m`↔`pve13t`, ~$20).** One cable, leaves `pve12t` off the TB fabric entirely. Rejected: loses half the cluster's TB benefit (no fast migration for any VM moving on/off `pve12t`) for trivial cable savings.
- **Full mesh via enclosure swap on `pve12t` ($310–460).** Replace Razer Core X with a daisy-chain-capable TB enclosure (Chroma/Sonnet), freeing both `pve12t` TB ports for cluster wiring. Rejected: hardware spend is disproportionate to the gain when Ceph is off the table — full mesh's main payoff is sustained replication bandwidth, which this lab will never run.
- **Full mesh by moving the eGPU to a dedicated PC ($60 cables + cost of GPU host).** Frees both TB ports on `pve12t` for cluster wiring. Excellent option *if* the LLM workload is being rebuilt onto separate hardware anyway. Rejected for now because the LLM role is fine on `pve12t` and rebuilding it just to free TB ports would be tail-wagging-dog.
- **2.5GbE-only (no TB ring1).** Simplest. Rejected: ~10× slower live migration (15s vs 2min for a 32 GB VM on TB direct), and no second corosync ring for redundancy. $40 in cables + an afternoon of setup is the right level of investment for the gain.
- **Future migration to full mesh** (if Ceph ever re-enters scope, or eGPU moves off-cluster) — would supersede this ADR via a new ADR-NNNN selecting sub-option C or D above, not by editing this one.
