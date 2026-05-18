# Inputs for the openclaw role's tofu workspace.
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
  description = "Full API token in `user@realm!tokenid=secret-uuid` form, e.g. `tofu@pve!apply=...`. See docs/proxmox-tofu-permissions.md."
}

variable "proxmox_node" {
  type        = string
  default     = "pve12t"
  description = "Proxmox cluster node to create the VM on. Default pve12t; switch to pve13m / pve13t if you want the daemon co-located with other workloads on those nodes. Cluster-mobile after deploy."
}

variable "admin_username" {
  type        = string
  default     = "claw-admin"
  description = "First-boot admin user cloud-init creates. Matches the bao-admin / rootca-admin naming convention — Ansible runs against this user via SSH."
}

variable "ssh_public_key" {
  type        = string
  description = "Single-line authorized_key string for admin_username. Typically your workstation's ed25519 pubkey."
}
