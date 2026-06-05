# Inputs for the amp-game role's tofu workspace.
#
// All of these come in through terraform.tfvars (gitignored), which
// scripts/hydrate.sh produces from terraform.tfvars.tpl (committed,
// with kp:// placeholders the script resolves against KeePassXC).

variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint URL, e.g. https://pve12t:8006/. Trailing slash is OK. Pointing at any cluster node is fine — pmxcfs replicates user.cfg so the token works against all nodes."
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Full API token in `user@realm!tokenid=secret-uuid` form, e.g. `tofu@pve!apply=...`. See docs/proxmox-tofu-permissions.md."
}

variable "proxmox_node" {
  type        = string
  default     = "pve13t"
  description = "Proxmox cluster node to create the VM on. Default pve13t (newest hardware, no GPU). The local.ubuntu_template_ids map in main.tf picks the right per-node template VMID automatically (pve12t=9100, pve13m=9101, pve13t=9102, pve12t2=9103)."
}

variable "admin_username" {
  type        = string
  default     = "amp-admin"
  description = "First-boot admin user cloud-init creates. Ansible runs against this user via SSH. Matches the openbao/rootca convention of <role>-admin."
}

variable "ssh_public_key" {
  type        = string
  description = "Single-line authorized_key string for admin_username. Typically your workstation's ed25519 pubkey."
}

# --- VM sizing ----------------------------------------------------------------
# Defaults match the legacy deploy.sh's defaults. Bump per game served:
#   * Minecraft vanilla:    defaults are fine.
#   * Minecraft modpacks:   24-32 GiB RAM, 6-8 cores.
#   * Steam games (ARK/Rust/7DTD): 16+ GiB RAM, 6+ cores.
#   * Multiple game instances: scale linearly per concurrent server.

variable "vm_cores" {
  type        = number
  default     = 4
  description = "vCPU cores. 4 covers Minecraft + AMP overhead; bump for modded packs or Steam-game hosts."
}

variable "vm_memory_mb" {
  type        = number
  default     = 12288
  description = "RAM in MB. 12 GiB covers a 6-8 GiB JVM heap + AMP + system. Bump for modded packs (24-32 GiB) or multiple instances."
}

variable "vm_disk_size_gb" {
  type        = number
  default     = 100
  description = "Boot-disk size in GB. 100 GiB covers AMP install + game installs + world growth + AMP backups. Bump to 200+ for pure Steam-game hosts (game files balloon)."
}

variable "disk_storage" {
  type        = string
  default     = "local-lvm"
  description = "Proxmox storage pool for the boot disk. This role OVERRIDES the cluster-mobile default of nas-vms (used by openbao / openclaw / nemoclaw): local-lvm (NVMe) is the right call for game-server I/O latency — Brian explicitly rejected nas-vms (NFS) for this workload because world saves and player joins are I/O-sensitive. amp-game is therefore node-pinned despite being on the new role shape. The variable is exposed (and shown commented in terraform.tfvars.example) so a planned node move or temporary re-host can flip it without editing the role definition."
}

variable "snippets_storage" {
  type        = string
  default     = "local"
  description = "Proxmox storage for the cloud-init snippet (must allow `snippets` content type). Default `local` (per-node) is fine because amp-game is node-pinned to its `disk_storage` host — no live-migration to worry about. Exposed (and shown commented in terraform.tfvars.example) for symmetry with the cluster-mobile roles and to make a planned node move trivial to configure."
}
