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

# --- Storage ------------------------------------------------------------------
# Cluster-mobile defaults: boot disk + cloud-init snippet land on `nas-vms`
# (Asustor NFS, registered cluster-wide per ADR-0004) so the VM can live-
# migrate without re-uploading the snippet from a stale per-node `local`
# store. The committed terraform.tfvars.tpl pins both to the pre-flip values
# (`local-lvm` / `local`) for the openclaw instance that was created on
# node-local storage; drop those pin lines when you want the next apply to
# move the VM to nas-vms. See vms/openclaw/README.md "Storage migration".

variable "disk_storage" {
  type        = string
  default     = "nas-vms"
  description = "Proxmox storage pool for the boot disk. Defaults to nas-vms (cluster-shared NFS) so the role is cluster-mobile out of the box. Override to local-lvm only if I/O latency matters more than mobility (see vms/amp-game)."
}

variable "snippets_storage" {
  type        = string
  default     = "nas-vms"
  description = "Proxmox storage for the cloud-init snippet (must allow `snippets` content). Defaults to nas-vms so the snippet stays reachable post-live-migration; per-node `local` breaks the migration target. See docs/cluster-bring-up.md step 8."
}
