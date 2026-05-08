# homelab

Infrastructure-as-code for a small Proxmox VE homelab. Builds reproducible,
hardened VM templates (Ubuntu Server 24.04 LTS, Windows 11 Pro x64) that
serve as the universal parent images for downstream VMs running across one
or more Proxmox nodes.

## Hardware

### Proxmox nodes

| Node | Model | CPU | RAM | Notable peripherals |
| --- | --- | --- | --- | --- |
| `pve12t` | Intel NUC 12 Tall | i7-1260P (12th gen, 4P+8E / 16T) | 64 GiB | Thunderbolt eGPU enclosure with NVIDIA RTX 3090 (24 GB VRAM) — see [docs/proxmox-gpu-passthrough.md](docs/proxmox-gpu-passthrough.md) |
| `pve13m` | Intel NUC 13 Pro Mini | i7-1360P (13th gen, 4P+8E / 16T) | 64 GiB | — |
| `pve13t` | ASUS NUC 13 Pro Tall | i7-13620H (13th gen, 6P+4E / 16T) | 64 GiB | — |

Each node is independent (not clustered): per-node Proxmox user/token
setup, per-node template builds. Tooling in this repo treats nodes as
interchangeable apart from peripherals — the GPU-bearing roles obviously
only deploy to nodes that have a GPU.

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
- `vms/` — Per-role VM definitions cloned from the base template
  (cloud-init + a `deploy.sh` per role).
- `docs/proxmox-permissions.md` — Runbook for provisioning the dedicated
  Proxmox API user, role, and token used by Packer (least-privilege, per
  node).
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

1. Set up the Proxmox API user/token on each node — see
   [docs/proxmox-permissions.md](docs/proxmox-permissions.md).
2. Build the Ubuntu base template — see
   [packer/ubuntu-24-04-base/README.md](packer/ubuntu-24-04-base/README.md).
3. (Optional) Build the Windows base template — see
   [packer/windows-11-base/README.md](packer/windows-11-base/README.md).

## Acknowledgements

This project was developed with the assistance of AI tools.
