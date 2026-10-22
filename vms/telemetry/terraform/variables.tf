# Inputs for the telemetry tofu workspace.
#
// All of these come in through terraform.tfvars (gitignored), which
// scripts/hydrate.sh produces from terraform.tfvars.tpl (committed,
// with kp:// placeholders the script resolves against KeePassXC).

variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint URL, e.g. https://pve12t:8006/. Trailing slash is OK."
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Full API token in `user@realm!tokenid=secret-uuid` form. See docs/proxmox-tofu-permissions.md."
}

variable "proxmox_node" {
  type        = string
  default     = "pve12t2"
  description = "Proxmox cluster node to create the VM on. Default pve12t2. telemetry is node-pinned (boot disk on that node's local-lvm), so this is where the VM lives, not just where it starts; changing it on a live VM means a disk move, not a migration. The local.ubuntu_template_ids map in main.tf picks the matching per-node template VMID."
}

variable "admin_username" {
  type        = string
  default     = "telemetry-admin"
  description = "First-boot admin user cloud-init creates. Matches the bao-admin / rootca-admin / claw-admin naming convention — Ansible runs against this user via SSH."
}

variable "nic_mac_address" {
  type        = string
  default     = null
  description = "MAC address pinned on the VM's NIC, so the router's DHCP reservation (and the IP) survives NIC recreation. Kept out of the public repo: set it in the gitignored terraform/nic.auto.tfvars (OpenTofu loads *.auto.tfvars automatically, and scripts/hydrate.sh never rewrites it). null lets bpg/proxmox generate one, which is what the first apply does; capture it afterwards with `ssh <node> \"qm config <vmid> | awk -F'=|,' '/^net0:/ {print $2}'\"`."

  validation {
    condition     = var.nic_mac_address == null || can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", var.nic_mac_address))
    error_message = "nic_mac_address must be null or a colon-separated MAC such as BC:24:11:00:00:00."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "Single-line authorized_key string for admin_username. Typically your workstation's ed25519 pubkey."
}

# --- Storage ------------------------------------------------------------------
# This role OVERRIDES the cluster-mobile default (nas-vms): the boot disk
# lands on the target node's NVMe-backed local-lvm and the cloud-init
# snippet on that node's `local` store. Trade-off: the VM is node-pinned
# (no live migration without a `qm move-disk` to shared storage first) in
# exchange for local-NVMe I/O and no dependency on the NAS being up. Same
# override shape as vms/amp-game.

variable "disk_storage" {
  type        = string
  default     = "local-lvm"
  description = "Proxmox storage pool for the boot disk. This role OVERRIDES the cluster-mobile default of nas-vms: local-lvm (the per-node LVM-thin pool on the node's NVMe) keeps telemetry's disk I/O on local NVMe and removes the NAS as a runtime dependency. The VM is therefore node-pinned to proxmox_node. Exposed so a planned move to shared storage can flip it without editing the role definition (changing it recreates the disk; use `qm move-disk` for an in-place move)."
}

variable "snippets_storage" {
  type        = string
  default     = "local"
  description = "Proxmox storage for the cloud-init snippet (must allow `snippets` content type). Default `local` (per-node) is fine because telemetry is node-pinned to its `disk_storage` host, so there is no live-migration target to keep the snippet reachable from. Flip to nas-vms together with disk_storage if the role ever becomes cluster-mobile."
}
