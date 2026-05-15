# `modules/proxmox-vm` — shared Proxmox VM provisioner

A thin OpenTofu module that clones a Packer-built template (Ubuntu 24.04
base = per-node VMIDs `9100`/`9101`/`9102`, Windows 11 base = `9200`/`9201`/`9202` — see [ADR-0006](../../docs/decisions/0006-packer-templates-per-node.md)) into a per-role VM
and attaches a cloud-init snippet for first-boot configuration. Every
role under [`vms/`](../../vms/) calls this module from its
`terraform/main.tf`; [`vms/openbao/`](../../vms/openbao/) and
[`vms/rootca/`](../../vms/rootca/) are the canonical reference
implementations.

The module is intentionally minimal: it owns the VM shape (CPU, RAM,
disk, NIC) and the cloud-init plumbing, nothing else. Per-role specifics
(packages, services, configs) belong in each role's `ansible/` tree, not
here.

## Inputs

See [`variables.tf`](variables.tf) for the full surface, descriptions,
and validation rules. Quick reference:

| Variable | Required | Purpose |
| --- | --- | --- |
| `name` | yes | VM name + cloud-init hostname (lowercase, no spaces). |
| `node_name` | yes | Proxmox node to create the VM on. Pairs with `template_id` — same-node by construction when the caller uses the node-keyed map pattern from [ADR-0006](../../docs/decisions/0006-packer-templates-per-node.md). |
| `vm_id` | yes | Stable per-role VM ID. Per [ADR-0008](../../docs/decisions/0008-service-vmid-range.md): services in 8000-8099 (`8030` = openbao, `8031` = rootca), workloads in 100-399 (`110` = amp-game). |
| `template_id` | yes | Source template VMID on `node_name`. Per-node post-cluster — Ubuntu base: 9100/9101/9102 for pve12t/pve13m/pve13t; Windows base: 9200/9201/9202. Callers typically pass the result of a node-keyed lookup; see [ADR-0006](../../docs/decisions/0006-packer-templates-per-node.md) and `local.ubuntu_template_ids` in [`vms/openbao/terraform/main.tf`](../../vms/openbao/terraform/main.tf). |
| `cores` / `memory_mb` / `disk_size_gb` | yes | VM shape. Validated for sanity. |
| `cpu_type` | no | Defaults to `x86-64-v3` (cluster-mobile baseline across Alder/Raptor Lake-P/H). Override to `host` only for hardware-pinned VMs. |
| `disk_storage` | no | Defaults to `local-lvm`. Switch to `nas-vms` when the role is cluster-mobile and the NFS pool is mounted. |
| `snippets_storage` | no | Defaults to `local`. Must have the `snippets` content type enabled — see [`docs/cluster-bring-up.md`](../../docs/cluster-bring-up.md) Step 7. |
| `user_data` | yes | Rendered cloud-init user-data YAML; the module uploads it as a snippet and attaches it via `cicustom`. |
| `network_devices` | no | List of `{bridge, vlan, model, mac_address}` maps. Defaults to one `vmbr0` virtio NIC. |
| `usb_passthrough` | no | List of `{host_port}` maps for USB passthrough by `<bus>-<port>` (required for the Root CA HSM role; pinning by port avoids the identical-VID:PID collision problem). |

## What this module does NOT cover

By design — speculative features bloat the surface and slow validation:

- **GPU / PCIe passthrough.** Will be added when the LLM role ports to
  OpenTofu; doing it speculatively means a `dynamic "hostpci"` block
  plus balloon=0 cross-var preconditions that the current roles don't
  exercise. See [`docs/proxmox-gpu-passthrough.md`](../../docs/proxmox-gpu-passthrough.md)
  for the manual flow that exists today.
- **Storage attachments beyond a single boot disk.** Roles that need a
  second disk add it in their own `terraform/main.tf` against the
  module's `vm_id`.
- **Cluster placement / HA.** Roles pin themselves to a node via
  `node_name`. No HA group plumbing — the lab doesn't run HA.

## When to bump the module

Compatibility-breaking changes (renaming a variable, dropping a default)
should be coordinated with every role that calls the module. The
practical guidance: add new variables with sensible defaults so existing
callers keep working; only break callers when the old shape no longer
makes sense.

## See also

- [`main.tf`](main.tf) — the resource shapes (proxmox_virtual_environment_vm,
  cloud-init snippet upload via `proxmox_virtual_environment_file`).
- [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) — workstation
  setup, provider auth, the `hydrate.sh` flow that resolves
  `terraform.tfvars` from your credential store.
- [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md)
  — Proxmox API user/role/token the module needs.
