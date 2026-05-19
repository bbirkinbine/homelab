# Inputs for the offline Root CA tofu workspace.
#
// `enable_network` is the lifecycle switch for the air-gap model:
//   * Bootstrap: true (one NIC on vmbr0; tofu apply; just ansible rootca
//     installs the smartcard + sc-hsm-embedded stack over SSH).
//   * Post-bootstrap: flip to false in terraform.tfvars and tofu apply
//     again. The NIC is removed declaratively. From here on the VM
//     is reachable only via Proxmox noVNC console — every ceremony
//     happens at the console. See vms/rootca/README.md for the full
//     sequence.

variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint URL, e.g. https://pve12t:8006/. Trailing slash is OK."
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Full API token in `user@realm!tokenid=secret-uuid` form. Same `tofu@pve!apply` token as openbao — see docs/proxmox-tofu-permissions.md."
}

variable "proxmox_node" {
  type        = string
  default     = "pve12t"
  description = "Proxmox cluster node to create the VM on. HSM-A is physically plugged into pve12t's labeled jack (bus-port 1-2 per the legacy openbao setup)."
}

variable "admin_username" {
  type        = string
  default     = "rootca-admin"
  description = "Bootstrap admin user cloud-init creates. Used for the one-shot Ansible run over SSH. After NIC removal, this user only exists as a noVNC-console login (sudo still works)."
}

variable "ssh_public_key" {
  type        = string
  description = "Single-line authorized_key string for admin_username. Only matters during the bootstrap phase before NIC removal."
}

variable "enable_network" {
  type        = bool
  default     = true
  description = "Bootstrap-phase NIC toggle. Leave true during initial provisioning + Ansible bootstrap. Flip to false (then tofu apply again) after verifying the HSM stack works, to make the VM air-gapped. Re-bootstrapping the tooling later means flipping back to true, applying, running Ansible, then flipping back to false."
}

variable "disk_storage" {
  type        = string
  default     = "local-lvm"
  description = "Proxmox storage pool backing the VM's disk. This role OVERRIDES the cluster-mobile default of nas-vms (used by openbao / openclaw / nemoclaw) because the Root CA is hardware-pinned to pve12t for HSM USB passthrough and never live-migrates — node-local is fine. Encryption is handled INSIDE the guest (see vms/rootca/README.md § 'How the air-gap is enforced'); the Ansible role carves a LUKS partition on the second half of this disk and mounts it at /var/lib/rootca-encrypted. (Pre-2026-05-11 this was an encrypted Directory pool named `rootca-encrypted` on a host-side LUKS partition; the host-side LUKS approach was dropped in favor of in-VM encryption for stronger isolation.)"
}

variable "snippets_storage" {
  type        = string
  default     = "local"
  description = "Proxmox storage pool for the cloud-init snippet (must allow `snippets` content type). This role OVERRIDES the cluster-mobile default of nas-vms with per-node `local` because the VM never live-migrates (HSM passthrough pins it to pve12t). The snippet itself is identity-only (hostname / admin user / SSH pubkey) and not sensitive."
}

variable "disk_size_gb" {
  type        = number
  default     = 40
  description = "Disk size for the Root CA VM. ~8 GiB for the standard Packer 9100 base; the rest holds the LUKS partition the Ansible role carves at /var/lib/rootca-encrypted. Bumped from 32 GiB on 2026-05-11 with the host-side → in-VM LUKS move so the encrypted partition has room without spilling the cleartext OS."
}

variable "hsm_usb_host_port" {
  type        = string
  default     = "1-2"
  description = "Physical bus-port of the labeled HSM-A jack on `proxmox_node`. Pinning by port (NOT by VID:PID) is required because the CardLogix HSM pair enumerates identically — see legacy/README.md."
}

variable "hsm_usb3" {
  type        = bool
  default     = false
  description = "Set true ONLY if the host's HSM-A jack is on a USB 3 (xHCI) controller and the default EHCI passthrough fails to enumerate the device. For the labeled bus-1 jack on pve12t, leave false."
}
