# 0006 — Packer base templates per-node with distinct VMIDs

**Status:** Accepted
**Date:** 2026-05-14

## Context

Pre-cluster, each NUC had an independent VMID namespace, so the Ubuntu Packer template was built on every node at the same VMID (`9100`) — per-role tfvars could carry one constant `template_id = 9100` regardless of target node.

Forming the 3-node cluster ([0004](0004-three-node-proxmox-cluster.md)) made VMIDs cluster-wide unique. The first build of 9100 succeeded on `pve12t`; the second attempt on `pve13t` failed with HTTP 500 from `/api2/json/nodes/{node}/qemu`: `unable to create VM 9100 - VM 9100 already exists on node 'pve12t'`. The "build same VMID everywhere" pattern is structurally impossible post-cluster — Proxmox refuses to let two nodes hold the same VMID simultaneously.

The lab also has cluster-mobile and node-pinned roles ([0004](0004-three-node-proxmox-cluster.md)): openbao is cluster-mobile today; Root CA is `pve12t`-pinned for USB-HSM passthrough; LLM is `pve12t`-pinned for eGPU. Clone performance + node availability both matter.

## Decision

Build the Ubuntu 24.04 base template on **every cluster node**, at **distinct VMIDs**: `9100` on `pve12t`, `9101` on `pve13m`, `9102` on `pve13t` (and `9103` on `pve12t2`, added when the cluster grew to four nodes — the convention extends by +1 per node joined). Each role's terraform looks up the right VMID for its target node via a local map keyed on `proxmox_node`:

```hcl
locals {
  ubuntu_template_ids = {
    pve12t  = 9100
    pve13m  = 9101
    pve13t  = 9102
    pve12t2 = 9103
  }
}

module "this" {
  template_id = local.ubuntu_template_ids[var.proxmox_node]
  # ...
}
```

Windows base templates follow the same shape with VMIDs `9200`/`9201`/`9202` (gap of 100 leaves room for additional Linux variants below 9200).

## Consequences

- **Every clone is same-node.** Read from local-lvm, write to caller-chosen storage on the same node. LVM linked clones are available (sub-second) where same-node, full-copy semantics aren't required.
- **No NFS dependency for templates.** The `nas-vms` shared storage stays for VM disks and snippets ([0004](0004-three-node-proxmox-cluster.md)); template I/O stays on NVMe.
- **Maximum resilience against single-node loss.** Any one node down leaves the other two with their local templates — roles that target a surviving node deploy normally. Only roles targeting the down node are blocked, which is fine because that node is down anyway.
- **Build effort is 3× on every Ubuntu point-release bump.** Acceptable: 24.04 point releases ship roughly twice a year, so this is a ~3× rare-event cost, not a per-deploy cost.
- **The node→VMID map is duplicated in three places.** [`vms/<role>/terraform/main.tf`](../../vms/openbao/terraform/main.tf) (consumed at clone time), [`scripts/preflight.sh`](../../scripts/preflight.sh) (consumed before apply, as a shell `case`), and the [`.env.example`](../../packer/ubuntu-24-04-base/.env.example) header (operator-facing convention). When a node joins or leaves, all three must change. The cost is small (5 lines each) and avoiding it would require either a code-generated lookup or parsing HCL from shell — neither worth it at this scale.
- Per-role tfvars no longer carries `template_vm_id`. The role's own `local.ubuntu_template_ids` is the source of truth; new Linux roles copy openbao's pattern.

## Alternatives considered

- **Per-node templates at the same VMID (e.g., 9100 on all three).** Rejected because Proxmox clusters enforce cluster-wide VMID uniqueness — discovered structurally impossible on 2026-05-14.
- **Single template on shared storage (`nas-vms`).** Most cluster-native option. Rejected because NFS over 1 GbE to the Asustor is ~10× slower than local NVMe for clone I/O, and the NAS becomes a single point of failure for every VM creation. Also negates LVM linked-clone speed entirely.
- **Single template on one node's local-lvm + cross-node clones for the other two.** Rejected primarily on resilience grounds: the chosen "template host" becomes a single point of failure for all VM creation on the cluster. Cross-node clone over TB ring1 is fast enough (~10-20s for 20GB) but doesn't help when the template host itself is offline. Secondarily: forces per-role tfvars to carry a `template_node_name` var separate from the target `proxmox_node`, coupling cluster topology into the call site.
