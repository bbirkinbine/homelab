# Inputs to the shared Windows Proxmox-VM module.
#
// This module is the Windows counterpart to modules/proxmox-vm/ (Linux). The
// input surface deliberately mirrors that module so the two feel consistent at
// the call site; the Windows-specific hardware (q35 + OVMF + TPM 2.0, SATA boot
// disk, virtio NIC, configdrive2 JSON meta-data on ide3) is baked INTO the
// module rather than exposed as knobs, because those are fixed requirements of
// cloning the Windows 11 base template — see main.tf and the module README for
// the why behind each.
//
// What this module intentionally does NOT take (vs the Linux module): no
// usb_passthrough / hostpci_devices yet (no Windows passthrough role exists);
// add them here if/when a GPU- or device-passthrough Windows VM lands.

variable "name" {
  type        = string
  description = "Proxmox VM name AND the hostname cloudbase-init sets inside the guest (via the JSON meta-data). Lowercase, no spaces; cloudbase-init truncates hostnames to 15 chars (NetBIOS)."
}

variable "node_name" {
  type        = string
  description = "Proxmox cluster node to create the VM on. Must match the node where the Windows template lives (templates are per-node, ADR-0006)."
}

variable "vm_id" {
  type        = number
  description = "Unique VM ID. Workloads live in 100-399 per ADR-0008 (a Windows client is a workload)."
}

variable "template_id" {
  type        = number
  description = "Source Windows-base template VM ID on node_name. Per-node (ADR-0006): 9200/9201/9202/9203 for pve12t/pve13m/pve13t/pve12t2. Callers pass a node-keyed map lookup."
}

variable "cores" {
  type        = number
  default     = 4
  description = "vCPU cores. Win11 desktop is comfortable at 4."
}

variable "memory_mb" {
  type        = number
  default     = 8192
  description = "RAM in MB. Win11 wants 8 GiB to feel usable; 4 GiB is the hard floor."
}

variable "balloon_mb" {
  type        = number
  default     = 0
  description = "Ballooning floor in MB. 0 disables the balloon (floating == dedicated). The virtio balloon driver ships in the template; ballooning is off by default (one fewer variable), raise this for tolerant workloads."
}

variable "disk_size_gb" {
  type        = number
  default     = 64
  description = "Boot-disk size in GB. The Windows base ships at 60 GB; this resizes the SATA disk on clone. Note Windows will not auto-extend the C: partition into the extra space."
}

variable "disk_storage" {
  type        = string
  default     = "local-lvm"
  description = "Proxmox storage pool for the boot disk AND the EFI + TPM state disks. Defaults to local-lvm (matches the template, so the clone is a same-storage op). Use nas-vms for a cluster-mobile host once you have verified NFS handles the EFI/TPM disks."
}

variable "snippets_storage" {
  type        = string
  default     = "local"
  description = "Proxmox storage for the cloud-init snippets (must allow `snippets` content). Defaults to `local` (per-node). Use nas-vms if the host is cluster-mobile so the snippet survives live-migration."
}

variable "cpu_type" {
  type        = string
  default     = "x86-64-v3"
  description = "QEMU CPU model. x86-64-v3 is the lab's cluster-mobile baseline across the NUC CPU generations. Use `host` only for hardware-pinned Windows VMs."
}

variable "vga_type" {
  type        = string
  default     = "std"
  description = "Display type. `std` (framebuffer) for Windows — unlike the Linux module's serial0, Windows has no serial console wired and needs a framebuffer for the Proxmox noVNC console."
}

variable "user_data" {
  type        = string
  description = "Rendered cloud-init user-data — for Windows this is a #ps1_sysnative PowerShell script (produced by templatefile() in the caller) that cloudbase-init's UserDataPlugin runs on first boot to create the admin account. Becomes the VM's user_data_file_id after upload."
}

variable "tags" {
  type        = list(string)
  default     = []
  description = "Proxmox tags applied to the VM."
}

variable "started" {
  type        = bool
  default     = true
  description = "Whether to start the VM after create."
}

variable "on_boot" {
  type        = bool
  default     = true
  description = "Auto-start the VM when the Proxmox host boots."
}

# --- network devices ---------------------------------------------------------

// Default = one virtio NIC on vmbr0. The CLONE uses virtio safely because the
// virtio driver suite was installed into the template post-build (the template
// BUILD itself needed e1000e, since Win11 24H2 WinPE ships no netkvm — see
// packer/windows-11-base). Pass [] to remove the NIC (air-gapped).
variable "network_devices" {
  description = "List of NICs to attach. Default = one virtio NIC on vmbr0."
  type = list(object({
    bridge      = string
    model       = optional(string, "virtio")
    firewall    = optional(bool, false)
    mac_address = optional(string)
    vlan_id     = optional(number)
  }))
  default = [{ bridge = "vmbr0" }]
}
