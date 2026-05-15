// ----------------------------------------------------------------------------
// Proxmox API connection (used by the proxmox-iso source only)
// ----------------------------------------------------------------------------

variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL, e.g. https://nuc12.lan:8006/api2/json"
  default     = ""
}

variable "proxmox_token_id" {
  type        = string
  description = "Proxmox API token ID, e.g. packer@pve!builder"
  sensitive   = true
  default     = ""
}

variable "proxmox_token_secret" {
  type        = string
  description = "Proxmox API token secret (UUID)"
  sensitive   = true
  default     = ""
}

variable "proxmox_skip_tls_verify" {
  type        = bool
  description = "Skip TLS verification on the Proxmox API. Only true for self-signed homelab certs."
  default     = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name to build on, e.g. nuc12 or nuc13"
  default     = ""
}

// ----------------------------------------------------------------------------
// VM template settings — both targets
// ----------------------------------------------------------------------------

variable "vm_id" {
  type        = number
  description = "Target VM ID for the Proxmox template. Per-node post-cluster — see ADR-0006. Windows convention: 9200/9201/9202 for pve12t/pve13m/pve13t (Ubuntu uses 9100/9101/9102). Override via VM_ID in .env.<node>; the 9200 default assumes pve12t."
  default     = 9200
}

variable "vm_name" {
  type    = string
  default = "windows-11-base"
}

variable "vm_cores" {
  type    = number
  default = 4
}

variable "vm_memory" {
  type        = number
  description = "MB of RAM during build. Roles override at clone time."
  default     = 8192
}

variable "vm_disk_size" {
  type        = string
  description = "Boot disk size during build. Roles can grow at clone time."
  default     = "60G"
}

variable "vm_storage_pool" {
  type        = string
  description = "Proxmox storage pool for the VM disk."
  default     = "local-lvm"
}

variable "vm_bridge" {
  type    = string
  default = "vmbr0"
}

variable "vlan_tag" {
  type        = string
  description = "VLAN tag for the build NIC. Empty string means untagged."
  default     = ""
}

// ----------------------------------------------------------------------------
// ISO sources — Windows 11 + VirtIO drivers
// ----------------------------------------------------------------------------

variable "iso_file" {
  type        = string
  description = <<EOT
Existing Windows 11 ISO on a Proxmox storage pool, in 'storage:iso/filename' form.
Used by the proxmox-iso source.
EOT
  default     = "local:iso/Win11_24H2_English_x64.iso"
}

variable "iso_url" {
  type        = string
  description = "URL (file:// or https://) to the Windows 11 multi-edition x64 ISO. Used by the virtualbox-iso source. Get from microsoft.com/software-download/windows11."
  default     = ""
}

variable "iso_checksum" {
  type        = string
  description = "SHA256 checksum of the Windows 11 ISO. Verify before each build — Microsoft re-issues the ISO periodically."
  default     = ""
}

variable "virtio_iso_file" {
  type        = string
  description = "Existing virtio-win.iso on a Proxmox storage pool, in 'storage:iso/filename' form. Used by the proxmox-iso source."
  default     = "local:iso/virtio-win.iso"
}

variable "virtio_iso_path" {
  type        = string
  description = "Local filesystem path to virtio-win.iso on the build host. Used by the virtualbox-iso source (mounted as a second CDROM so the post-install provisioner can run virtio-win-guest-tools.exe)."
  default     = "~/iso/virtio-win.iso"
}

variable "iso_storage_pool" {
  type    = string
  default = "local"
}

// ----------------------------------------------------------------------------
// Build-time admin credentials
//
// Local Administrator account autounattend creates so Packer can WinRM in and
// run provisioners. Wiped/rotated by sysprep at the end of the build.
// ----------------------------------------------------------------------------

variable "build_username" {
  type    = string
  default = "Administrator"
}

variable "build_password" {
  type        = string
  description = "Plaintext password for the build admin. Autounattend.xml has the matching value embedded; if you change one, change both."
  sensitive   = true
  default     = "packer-build-only-Win11!"
}

// ----------------------------------------------------------------------------
// VirtualBox source — output paths (build-vbox.sh local builds)
// ----------------------------------------------------------------------------

variable "vbox_output_dir" {
  type        = string
  description = "Directory where the virtualbox-iso source writes its VM artifacts (.vdi, .ovf, .mf). Relative to the working directory, or absolute."
  default     = "output-vbox"
}
