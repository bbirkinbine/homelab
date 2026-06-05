# Inputs for the win-host spike workspace.
#
# All of these come in through terraform.tfvars (gitignored), which
# scripts/hydrate.sh produces from terraform.tfvars.tpl (committed, with
# kp:// placeholders the script resolves against KeePassXC).

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
  description = "Proxmox cluster node to create the VM on. The Windows base template must exist on this node (per-node VMIDs 9200/9201/9202/9203, ADR-0006). Default pve12t2 (newest node, light load — good for the spike)."
}

# --- Named admin account ------------------------------------------------------
# cloudbase-init's first-boot user-data (PowerShell) creates THIS account and
# adds it to Administrators. The built-in Administrator is left disabled by the
# template's first-boot cleanup (packer-cleanup.ps1) — that cleanup waits for
# cloudbase-init to finish, so this account exists before Administrator is
# locked out. This is the "named admin, Administrator stays disabled" model.

variable "win_admin_username" {
  type        = string
  default     = "labadmin"
  description = "Local admin account cloud-init creates on first boot and adds to Administrators."
}

variable "win_admin_password" {
  type        = string
  sensitive   = true
  description = <<-EOT
    Password for win_admin_username. Sourced from KeePassXC via the kp://
    placeholder in terraform.tfvars.tpl — so you EITHER type a password into
    that KeePassXC entry OR let KeePassXC generate one. Either way the value
    lives in your vault, so it satisfies both "set it manually" and "random
    but we know it". Must meet Windows complexity (>= 8 chars, 3 of 4 of
    upper/lower/digit/symbol) or New-LocalUser rejects it.

    CAVEAT: this value is rendered in cleartext into the cloud-init snippet
    that lands on the snippets datastore (`local` by default for the spike).
    Acceptable for a lab; Phase 2 can revisit (LAPS-style rotation or hashing).
  EOT
}

# --- Sizing -------------------------------------------------------------------

variable "vm_id" {
  type        = number
  default     = 310
  description = "VMID for this Windows host. Workloads range 100-399 per ADR-0008 (services live 8000-8099). 310 is a spike default — change before Phase 2 if it collides; check `qm list` cluster-wide."
}

variable "cores" {
  type        = number
  default     = 4
  description = "vCPU cores. Win11 desktop is comfortable at 4; bump for heavier guests."
}

variable "memory_mb" {
  type        = number
  default     = 8192
  description = "Dedicated RAM (MiB). Win11 wants 8 GiB to feel usable; 4 GiB is the hard floor."
}

variable "disk_size_gb" {
  type        = number
  default     = 64
  description = "Boot disk size (GiB). Win11 base footprint + headroom."
}

variable "cpu_type" {
  type        = string
  default     = "x86-64-v3"
  description = "cluster-mobile baseline per CLAUDE.md (Alder/Raptor Lake-P/H common denominator). Use `host` only for hardware-pinned guests."
}

# --- Storage ------------------------------------------------------------------
# SPIKE default is local-lvm + per-node `local`, MATCHING the template (9203's
# efidisk0/tpmstate0/sata0 all live on local-lvm). This makes the clone a
# same-storage operation — fast, and it isolates "does the Windows clone boot +
# inject an account" from the separate, riskier question of relocating EFI/TPM
# to NFS. Cluster-mobility on nas-vms is a Phase-2 test once boot+login is
# proven; flip both knobs to nas-vms then.

variable "disk_storage" {
  type        = string
  default     = "local-lvm"
  description = "Proxmox storage pool for the boot/EFI/TPM disks. Spike default local-lvm to match the template (no cross-storage relocation on clone). Set to nas-vms for cluster-mobility once boot+login is proven."
}

variable "snippets_storage" {
  type        = string
  default     = "local"
  description = "Proxmox storage for the cloud-init snippets (must allow `snippets` content). Spike default `local` (per-node) since the spike is pinned to pve12t2. Use nas-vms if you later make this cluster-mobile."
}

variable "vm_bridge" {
  type        = string
  default     = "vmbr0"
  description = "Bridge for the VM NIC. The clone uses a virtio NIC (drivers were installed into the template post-build by 10-install-virtio.ps1), unlike the e1000e the template BUILD needed."
}
