// ----------------------------------------------------------------------------
// Proxmox API connection
// ----------------------------------------------------------------------------

variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL, e.g. https://nuc12.lan:8006/api2/json"
}

variable "proxmox_token_id" {
  type        = string
  description = "Proxmox API token ID, e.g. packer@pve!builder"
  sensitive   = true
}

variable "proxmox_token_secret" {
  type        = string
  description = "Proxmox API token secret (UUID)"
  sensitive   = true
}

variable "proxmox_skip_tls_verify" {
  type        = bool
  description = "Skip TLS verification on the Proxmox API. Only true for self-signed homelab certs."
  default     = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name to build on, e.g. nuc12 or nuc13"
}

// ----------------------------------------------------------------------------
// VM template settings
// ----------------------------------------------------------------------------

variable "vm_id" {
  type        = number
  description = "Target VM ID for the resulting template. Must not collide with existing VMs."
  default     = 9100
}

variable "vm_name" {
  type        = string
  description = "Name of the resulting Proxmox template."
  default     = "ubuntu-24-04-base"
}

variable "vm_cores" {
  type    = number
  default = 2
}

variable "vm_memory" {
  type        = number
  description = "MB of RAM during build. Roles override at clone time."
  default     = 2048
}

variable "vm_disk_size" {
  type        = string
  description = "Boot disk size, e.g. '20G'. Roles can grow this at clone time."
  default     = "20G"
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
// ISO source
// ----------------------------------------------------------------------------

variable "iso_file" {
  type        = string
  description = <<EOT
Existing ISO on a Proxmox storage pool, in 'storage:iso/filename' form.
e.g. 'local:iso/ubuntu-24.04.1-live-server-amd64.iso'.
Set to empty string if you want Packer/Proxmox to download via iso_url instead.
EOT
  default     = "local:iso/ubuntu-24.04.1-live-server-amd64.iso"
}

variable "iso_url" {
  type        = string
  description = "URL to download the Ubuntu live-server ISO. Used only if iso_file is empty."
  default     = "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-amd64.iso"
}

variable "iso_checksum" {
  type        = string
  description = <<EOT
SHA256 checksum of the live-server ISO. Used only if iso_file is empty.
Verify against the SHA256SUMS file at https://releases.ubuntu.com/24.04/
before each build — the value here may go stale across point releases.
EOT
  default     = "sha256:e240e4b801f7bb68c20d1356b60968ad0c33a41d00d828e74ceb3364a0317be9"
}

variable "iso_storage_pool" {
  type        = string
  description = "Proxmox storage pool to upload the ISO into when downloading via iso_url."
  default     = "local"
}

// ----------------------------------------------------------------------------
// Build-time SSH credentials
//
// These are the *temporary* credentials autoinstall creates so Packer can
// SSH in and run provisioners. They are wiped during cleanup — the resulting
// template has no usable login until cloud-init injects keys at first boot.
// ----------------------------------------------------------------------------

variable "build_username" {
  type    = string
  default = "packer"
}

variable "build_password" {
  type        = string
  description = "Plaintext password for the build user. Used by Packer for SSH; matches the hash in http/user-data."
  sensitive   = true
  default     = "packer-build-only"
}
