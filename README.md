# homelab

Infrastructure-as-code for a small Proxmox VE homelab. Builds reproducible,
hardened Ubuntu Server 24.04 LTS VM templates that serve as the universal
parent image for downstream VMs running across one or more Proxmox nodes.

## Repository layout

- `packer/ubuntu-24-04-base/` — Packer template that builds the
  Ubuntu 24.04 base image on a Proxmox node. See
  [its README](packer/ubuntu-24-04-base/README.md) for the full
  build runbook.
- `docs/proxmox-permissions.md` — Runbook for provisioning the dedicated
  Proxmox API user, role, and token used by Packer (least-privilege, per
  node).

## What's in the base image

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

## Getting started

1. Set up the Proxmox API user/token on each node — see
   [docs/proxmox-permissions.md](docs/proxmox-permissions.md).
2. Build the template — see
   [packer/ubuntu-24-04-base/README.md](packer/ubuntu-24-04-base/README.md).

## Acknowledgements

This project was developed with the assistance of AI tools.
