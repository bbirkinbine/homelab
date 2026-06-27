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
  default     = "pve12t"
  description = "Proxmox cluster node to create the VM on. Default pve12t (lowest-utilization node at planning time). Cluster-mobile, so live-migrate after deploy if utilization shifts."
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
# monitoring is the I/O-latency exception to the cluster-mobile default:
# the boot disk lives on `local-lvm` (NVMe) because Prometheus' TSDB is
# fsync-heavy (frequent small writes + periodic compaction) and degrades
# on NFS write-latency — same justification class as amp-game (see
# vms/amp-game for the game-server I/O rationale, vms/rootca for the
# passthrough rationale). That node-pins the VM.
#
# The cloud-init snippet deliberately STAYS on shared `nas-vms`: it is a
# ~5 KB identity YAML read only when Proxmox regenerates the ide2 drive
# (the running VM boots from that local-lvm drive, not from NFS), so its
# location is I/O-neutral. Relocating it on a live VM is also not worth
# it: `user_data_file_id` is ForceNew in bpg, so moving the snippet to
# `local` would rebuild the whole VM (blocked by prevent_destroy). A
# from-scratch rebuild would land it on `local` for free.

variable "disk_storage" {
  type        = string
  default     = "local-lvm"
  description = "Proxmox storage pool for the boot disk. OVERRIDES the cluster-mobile nas-vms default (used by openbao / openclaw / nemoclaw): local-lvm (NVMe) suits Prometheus' fsync-heavy TSDB, which degrades on NFS write-latency. Node-pins this role despite the cluster-mobile role shape. Exposed (and shown commented in terraform.tfvars.example) so a planned node move can flip it back without editing the role definition."
}

variable "snippets_storage" {
  type        = string
  default     = "nas-vms"
  description = "Proxmox storage for the cloud-init snippet (must allow `snippets` content). Stays on shared nas-vms even though disk_storage node-pins this role: the snippet is a ~5 KB identity YAML read only on ide2-drive regen (I/O-neutral), and relocating it on a live VM would change the ForceNew user_data_file_id and rebuild the VM (see the Storage comment block above). docs/cluster-bring-up.md step 8."
}
