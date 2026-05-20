# Inputs for the monitoring tofu workspace.
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
  default     = "pve13m"
  description = "Proxmox cluster node to create the VM on. Default pve13m (lowest-utilization node at planning time). Cluster-mobile, so live-migrate after deploy if utilization shifts."
}

variable "admin_username" {
  type        = string
  default     = "monitoring-admin"
  description = "First-boot admin user cloud-init creates. Matches the bao-admin / rootca-admin / claw-admin naming convention — Ansible runs against this user via SSH."
}

variable "ssh_public_key" {
  type        = string
  description = "Single-line authorized_key string for admin_username. Typically your workstation's ed25519 pubkey."
}

# --- Storage ------------------------------------------------------------------
# Cluster-mobile defaults: boot disk + cloud-init snippet land on `nas-vms`
# (Asustor NFS, registered cluster-wide per ADR-0004) so the VM can live-
# migrate without re-uploading the snippet from a stale per-node `local`
# store. Override to local-lvm + per-node `local` ONLY if this role is
# hardware-pinned (USB / eGPU passthrough) or has a hard I/O-latency
# requirement (see vms/amp-game for the I/O rationale, vms/rootca for the
# passthrough rationale).

variable "disk_storage" {
  type        = string
  default     = "nas-vms"
  description = "Proxmox storage pool for the boot disk. Defaults to nas-vms (cluster-shared NFS) so the role is cluster-mobile out of the box."
}

variable "snippets_storage" {
  type        = string
  default     = "nas-vms"
  description = "Proxmox storage for the cloud-init snippet (must allow `snippets` content). Defaults to nas-vms so the snippet stays reachable post-live-migration; per-node `local` breaks the migration target. See docs/cluster-bring-up.md step 8."
}
