# Inputs for the llm tofu workspace.
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
  description = "Proxmox cluster node to create the VM on. HARDCODED to pve12t — the RTX 3090 is physically attached via Thunderbolt to pve12t's enclosure, and the eGPU PCI mapping is pinned to that node. Changing this without moving the eGPU breaks the hostpci_devices passthrough at boot."
}

variable "admin_username" {
  type        = string
  default     = "llm-admin"
  description = "First-boot admin user cloud-init creates. Matches the bao-admin / rootca-admin / claw-admin convention — Ansible runs against this user via SSH."
}

variable "ssh_public_key" {
  type        = string
  description = "Single-line authorized_key string for admin_username. Typically your workstation's ed25519 pubkey."
}

# --- Storage ------------------------------------------------------------------
# Hardware-pinned overrides of the cluster-mobile nas-vms default. llm is
# pve12t-pinned via the eGPU passthrough, so node-local storage is fine and
# the dedicated nuc12-fast pool (LVM-thin on pve12t's SATA SSD) keeps the
# model cache off the NVMe local-lvm. Both knobs surface as variables for
# planned-move scenarios (e.g. testing on a different node without the GPU).

variable "disk_storage" {
  type        = string
  default     = "nuc12-fast"
  description = "Proxmox storage pool for the boot disk. Defaults to nuc12-fast — LVM-thin on pve12t's dedicated 1TB SATA SSD (VG nuc12fast_vg), physically separate from the NVMe-backed `pve` VG so the NVMe stays full-size as local-lvm. Models cache lives on this pool because (a) 300 GiB is comfortable on a 1TB SSD, (b) keeps the NVMe local-lvm free for cluster-mobile VMs, (c) the eGPU pins this VM to pve12t anyway. See CLAUDE.md 'Storage exceptions that stay node-pinned'."
}

variable "snippets_storage" {
  type        = string
  default     = "local"
  description = "Proxmox storage for the cloud-init snippet (must allow `snippets` content type). Default per-node `local` because the VM is pve12t-pinned (eGPU passthrough) and never live-migrates. The snippet itself is identity-only (hostname / admin user / SSH pubkey) and not sensitive."
}

# --- eGPU passthrough --------------------------------------------------------

variable "gpu_pci_mapping" {
  type        = string
  default     = "rtx-3090"
  description = "Name of the Proxmox cluster-wide PCI resource mapping for the RTX 3090. Operator must create the mapping once before `tofu apply` (it lives in /etc/pve/, NOT this role's tofu state). UI: Datacenter -> Resource Mappings -> PCI -> Add; the GPU's PCI address and its companion HDMI-audio function both go in the mapping. CLI form: `pvesh create /cluster/mapping/pci --id rtx-3090 --map 'node=pve12t,path=0000:3c:00.0,iommugroup=14' --map 'node=pve12t,path=0000:3c:00.1,iommugroup=14'`. Changing the GPU's physical PCI address (Thunderbolt enclosure swap, port change) means updating the MAPPING, not this variable."
}

# --- VM sizing ---------------------------------------------------------------
# Defaults match the legacy .env's recommended tier. Bump per workload —
# bigger models need more RAM headroom; CPU-fallback inference needs more cores.

variable "vm_cores" {
  type        = number
  default     = 6
  description = "vCPU cores. 6 covers GPU-bound inference (CPU is mostly tokenization + HTTP) on the i7-1260P (4P+8E, 12c/16t) while leaving headroom for the host. Bump to 8-10 for CPU-fallback inference on larger models."
}

variable "vm_memory_mb" {
  type        = number
  default     = 32768
  description = "RAM in MB. 32 GiB lets you mmap any model the 3090 can run (24 GB VRAM ceiling) plus headroom for OS, Docker, optional vector DB. Drop to 16 GiB if the host needs RAM elsewhere; bump if running CPU-fallback for >70B models."
}

variable "vm_disk_size_gb" {
  type        = number
  default     = 300
  description = "Boot-disk size in GB. 300 GiB covers OS + Docker + Ollama + a healthy hoard of quants (30B Q4 ~18 GB, 70B Q4 ~40 GB, plus development copies). Bump to 500+ if you're keeping every quant you download; the nuc12-fast pool is 1 TB so there's room."
}
