# homelab

Infrastructure-as-code for a small Proxmox VE homelab. Builds reproducible,
hardened VM templates (Ubuntu Server 24.04 LTS, Windows 11 Pro x64) that
serve as the universal parent images for downstream VMs running across one
or more Proxmox nodes.

> ## Status
>
> Published as a personal-lab reference, not an actively maintained product.
> Issues and PRs are welcome but won't get fast turnaround. The
> [`docs/`](docs/) tree — especially
> [docs/0-scratch-build-order.md](docs/0-scratch-build-order.md), the phased
> walkthrough that drives bare metal → quorate cluster → IaC enablement →
> per-role deploys — and the per-component runbooks under
> [`packer/*/README.md`](packer/) and [`vms/*/README.md`](vms/) are the parts
> most likely to be useful to others.
>
> **This repo is in-flight.** The lab is being built out role-by-role;
> expect the shape of [`vms/`](vms/), the
> [`modules/proxmox-vm`](modules/proxmox-vm/) input surface, the
> [`pve-host`](pve-hosts/) Ansible role, and the docs to shift as new
> requirements surface. Anything called out as "validated" or "shipping" in
> a per-component README has been exercised end-to-end on real hardware;
> the rest is subject to change without notice. Pin a specific commit if
> you depend on a snapshot.

## Hardware

### Proxmox nodes

| Node | Model | CPU | RAM | Notable peripherals |
| --- | --- | --- | --- | --- |
| `pve12t` | Intel NUC 12 Tall | i7-1260P (12th gen, 4P+8E / 16T) | 64 GiB | Thunderbolt eGPU enclosure with NVIDIA RTX 3090 (24 GB VRAM) — see [docs/proxmox-gpu-passthrough.md](docs/proxmox-gpu-passthrough.md) |
| `pve13m` | Intel NUC 13 Pro Mini | i7-1360P (13th gen, 4P+8E / 16T) | 64 GiB | — |
| `pve13t` | ASUS NUC 13 Pro Tall | i7-13620H (13th gen, 6P+4E / 16T) | 64 GiB | — |

The three nodes are being brought up as a 3-node Proxmox cluster
(corosync over the 2.5GbE LAN, with a Thunderbolt line-topology overlay
for live-migration traffic). Until cluster join (`pvecm create` /
`pvecm add`) lands, each node still gets its own API user/token setup;
once clustered, users and tokens replicate cluster-wide via pmxcfs.
Templates remain per-node — Packer writes to local storage on the node
it builds against. VMs on cluster-shared NFS storage (`nas-vms` from the
Asustor) can live-migrate between nodes; roles pinned to specific
hardware (eGPU on `pve12t`, USB-HSM for the offline Root CA on `pve12t`)
stay node-local.

### Build hosts (non-Proxmox)

| Host | Role |
| --- | --- |
| `t480` | ThinkPad T480 running Ubuntu — local VirtualBox build host for the Windows 11 `virtualbox-iso` Packer target (see [packer/windows-11-base/README.md](packer/windows-11-base/README.md)). Produces a VMDK that converts to qcow2 for libvirt / virt-manager. Not a Proxmox node. |

## Repository layout

- `packer/ubuntu-24-04-base/` — Packer template that builds the
  Ubuntu 24.04 base image on a Proxmox node. See
  [its README](packer/ubuntu-24-04-base/README.md) for the full
  build runbook.
- `packer/windows-11-base/` — Packer template that builds a hardened
  Windows 11 Pro x64 image. Two targets: `proxmox-iso` (template VM
  9101 on a Proxmox node) and `virtualbox-iso` (local VBox build on the
  T480; outputs VMDK that converts to qcow2 for virt-manager / libvirt).
  See [its README](packer/windows-11-base/README.md).
- `modules/proxmox-vm/` — Shared OpenTofu module that clones a Packer
  template into a per-role VM with a cloud-init drive. Called from
  each role's `terraform/` workspace.
- `vms/` — Per-role VM definitions. New roles use OpenTofu +
  Ansible (`terraform/` + `ansible/` + `cloud-init/`); see
  [`vms/openbao/`](vms/openbao/README.md) as the canonical example.
  Some older roles still ship a shell `deploy.sh` and will migrate
  in subsequent passes.
- `pve-hosts/` — Layer-0 Ansible role (`pve-host`) that brings a
  freshly-installed Proxmox VE 9.x host to baseline (repos, packages,
  chrony, `/etc/hosts`, network + Thunderbolt overlay, NFS mount,
  pve-firewall baseline, SSH keys). Stops short of the manual
  cluster-join ceremony. See [pve-hosts/README.md](pve-hosts/README.md).
- `scripts/` — Cross-cutting tooling: `preflight.sh` (ssh / Proxmox /
  template / snippets checks) and `hydrate.sh` (renders
  `terraform.tfvars` from KeePassXC).
- `Justfile` — Recipes that wrap the OpenTofu + Ansible flow per
  role (`just plan openbao`, `just apply openbao`, etc.).
- `docs/deploying-vms.md` — **Start here** for VM deploys. Orients you
  among the role-classes, points at the relevant runbooks, and includes
  the from-scratch checklist for adding a new role.
- `docs/proxmox-permissions.md` — API user/role/token for Packer.
- `docs/proxmox-tofu-permissions.md` — API user/role/token for
  OpenTofu (sibling of the Packer doc; smaller role).
- `docs/opentofu-setup.md` — Workstation setup, hydrate flow, state
  management.
- `docs/proxmox-gpu-passthrough.md` — Host-side runbook for binding an
  NVIDIA GPU (including Thunderbolt eGPUs) to `vfio-pci` so a VM can
  take it over. Prerequisite for [`vms/llm/`](vms/llm/).

## What's in the Ubuntu base image

The Packer build produces a Proxmox template (default VM ID `9100`, name
`ubuntu-24-04-base`) with:

- Current Ubuntu 24.04 LTS install via autoinstall (subiquity), fully
  upgraded at build time.
- Hardening: UFW (allow 22 only), auditd, no snap, Ubuntu Pro apt-news
  disabled, motd-news off.
- Network-quiet by default: auto-update timers masked, cloud-init
  datasources locked to the ones Proxmox actually provides (NoCloud +
  ConfigDrive), no background package fetchers.
- A cloud-init drive for clone-time configuration (hostname, SSH keys, IP).
- A self-destructing first-boot `packer-cleanup.service` that removes the
  build user and then deletes itself.

Per-VM software (k3s, container runtimes, databases, application stacks,
etc.) is layered on top per role — the base image stays generic and
minimal so any downstream VM can clone from it.

## What's in the Windows base image

The Packer build produces either a Proxmox template (default VM ID `9101`,
name `windows-11-base`) or a VirtualBox VMDK + OVF + NVRAM under
`output-vbox/` that converts to qcow2 via `qemu-img convert`, depending on
the selected target. Both share the same provisioner pipeline and end at
the same sysprep'd state:

- Windows 11 Pro x64 install via Autounattend.xml (UEFI + TPM 2.0).
- VirtIO drivers + QEMU guest agent installed during build.
- Hardening: Windows Firewall on (default-deny inbound, RDP/SSH/WinRM/ICMP
  allowed), telemetry minimum, Cortana off, OneDrive removed, LLMNR off,
  SMBv1 disabled, basic audit policy enabled.
- cloudbase-init pre-installed for clone-time configuration (hostname,
  network, admin password, SSH keys), reading Proxmox's cloud-init drive
  or a libvirt NoCloud seed ISO.
- Sysprep'd and shut down — boots into OOBE-mini → cloudbase-init on the
  first boot of every clone.

## Getting started

**Standing up the lab from scratch?** Read [docs/0-scratch-build-order.md](docs/0-scratch-build-order.md)
top-to-bottom — it's the master index that walks the four phases (substrate
→ cluster bring-up → IaC enablement → per-role deploys) and points at the
authoritative doc for each step.

If you're rebuilding a node (or the whole cluster) from bare metal,
work through layer 0 first, then come back to step 1 below:

- **(In parallel)** [docs/asustor-nas-setup.md](docs/asustor-nas-setup.md) —
  NAS-side NFS export. Can run while the NUC is installing.
- [docs/proxmox-install.md](docs/proxmox-install.md) — USB media, BIOS
  prereqs, installer click-through, per-node carve-outs.
- [pve-hosts/README.md](pve-hosts/README.md) — Ansible baseline against
  the freshly-installed host (repos, packages, chrony, network +
  Thunderbolt overlay, NFS mount, firewall, SSH).
- Cluster join (manual `pvecm create` / `pvecm add`) — quorum-aware,
  never automated; see [pve-hosts/README.md](pve-hosts/README.md#post-baseline-manual-steps).

Once a node is at PVE baseline + cluster-joined, the IaC quickstart is:

1. Set up the Proxmox API users/tokens on each node — see
   [docs/proxmox-permissions.md](docs/proxmox-permissions.md) for
   Packer and [docs/proxmox-tofu-permissions.md](docs/proxmox-tofu-permissions.md)
   for OpenTofu.
2. Build the Ubuntu base template — see
   [packer/ubuntu-24-04-base/README.md](packer/ubuntu-24-04-base/README.md).
3. (Optional) Build the Windows base template — see
   [packer/windows-11-base/README.md](packer/windows-11-base/README.md).
4. Provision a per-role VM via OpenTofu + Ansible — start with
   [docs/deploying-vms.md](docs/deploying-vms.md) for orientation
   (which role-class to copy, the repeatable 7-step flow, the
   from-scratch checklist for new roles), then drill into the
   relevant per-role README ([vms/openbao/](vms/openbao/README.md) or
   [vms/rootca/](vms/rootca/README.md)).

## Acknowledgements

This project was developed with the assistance of AI tools.
