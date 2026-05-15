# Inputs to the shared Proxmox-VM module.
#
// Scope notes:
//   * No hostpci / GPU passthrough variable yet — will be added when the
//     LLM role ports to OpenTofu. Adding it speculatively here would
//     mean a `dynamic "hostpci"` block paired with cross-variable
//     preconditions for balloon=0, none of which the openbao role
//     exercises.
//   * No USB passthrough variable yet — the Root CA VM (the only role
//     that will need it post-2026-05-10) is not in scope for this
//     module yet. When it lands, decide between (a) extending this
//     module with an optional `usb {}` list or (b) a sibling
//     proxmox-vm-with-usb module. The shape of HSM passthrough is
//     fiddly enough (host=<bus>-<port> pin, usb3 toggle) that a
//     separate module may be cleaner.
//   * Defaults match the homelab's conventions: q35 machine type
//     (modern PCIe), serial0 vga (because the base template wires up
//     ttyS0 for `qm terminal`), local-lvm + local for storage names
//     (what the pve12t / pve13 nodes ship with).

variable "name" {
  type        = string
  description = "Proxmox VM name and the hostname cloud-init will set inside the guest. Lowercase, no spaces."
}

variable "node_name" {
  type        = string
  description = "Proxmox cluster node to create the VM on (e.g. pve12t, pve13). Must match the node where the template VM lives."
}

variable "vm_id" {
  type        = number
  description = "Unique VM ID on the target node. Pick something stable per-role (e.g. 130 for openbao) so DHCP reservations and Proxmox URLs stay predictable."
}

variable "template_id" {
  type        = number
  description = "Source template VM ID on `node_name`. Templates are per-node (cluster VMIDs are unique), so callers typically pass the result of a node-keyed map lookup — see ADR-0006 and the openbao role's `local.ubuntu_template_ids` pattern. Ubuntu base: 9100 on pve12t, 9101 on pve13m, 9102 on pve13t. Windows base: 9200/9201/9202 (gap of 100 to leave room for the Ubuntu series)."
}

variable "cores" {
  type        = number
  default     = 2
  description = "vCPU cores. 2 is a fine default for small services; bump for compute-heavy roles."
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "RAM in MB (Proxmox's native unit, matches what `qm set --memory` takes)."
}

variable "balloon_mb" {
  type        = number
  default     = 0
  description = "Floating/ballooning minimum, in MB. 0 disables the balloon entirely — recommended for mlock-using services (OpenBao) and required for PCIe passthrough."
}

variable "disk_size_gb" {
  type        = number
  default     = 32
  description = "Boot-disk size in GB (integer). The Packer base ships at ~10 GB; this resizes scsi0 on clone."
}

variable "disk_storage" {
  type        = string
  default     = "local-lvm"
  description = "Proxmox storage pool for the boot disk. Must allow `images` content. Defaults to local-lvm (what the NUCs ship with)."
}

variable "machine" {
  type        = string
  default     = "q35"
  description = "QEMU machine type. q35 is the modern default and matches the rest of the homelab; i440fx is the older alternative."
}

variable "cpu_type" {
  type        = string
  default     = "x86-64-v3"
  description = "QEMU CPU model. x86-64-v3 is the common baseline across the lab's three NUC CPU generations (Alder Lake-P / Raptor Lake-P / Raptor Lake-H) and is the right choice for any VM that might live-migrate across the planned corosync cluster — see the vault's `VM Mobility — 3-Node Cluster on 2.5GbE.md`. Use `host` only for hardware-pinned VMs (eGPU passthrough on the LLM role; USB passthrough on the Root CA role)."
}

variable "vga_type" {
  type        = string
  default     = "serial0"
  description = "Display type. serial0 routes the console to ttyS0 so `qm terminal <id>` works (matches the Packer base's grub+console wiring). Use `std` for a framebuffer when you need noVNC for debugging."
}

variable "snippets_storage" {
  type        = string
  default     = "local"
  description = "Proxmox storage pool the cloud-init snippet uploads to. Must allow `snippets` content type — set in Datacenter -> Storage -> <name> -> Edit -> Content."
}

variable "user_data" {
  type        = string
  description = "Rendered cloud-init user-data YAML (string, typically produced by templatefile() in the caller). Becomes the VM's `user_data_file_id` after upload."
}

variable "tags" {
  type        = list(string)
  default     = []
  description = "Proxmox tags applied to the VM. Useful for cluster-aware filtering and the GUI's tag column."
}

variable "started" {
  type        = bool
  default     = true
  description = "Whether to start the VM after create. Set false for the (future) offline Root CA VM — that one boots manually for ceremonies only."
}

variable "on_boot" {
  type        = bool
  default     = true
  description = "Auto-start the VM when the Proxmox host boots. Default true for service VMs; set false for ceremony-only VMs."
}

# --- network devices ---------------------------------------------------------

// Default = one NIC on vmbr0, matching what the Packer base ships with.
// Pass `[]` to remove the NIC entirely (air-gapped roles — Root CA).
// bpg/proxmox's behavior with zero network_device blocks is "remove the NIC
// from configuration" per the upstream doc note: "Remove the network_device
// block from your configuration instead of setting enabled = false."
variable "network_devices" {
  description = "List of NICs to attach. Default = one virtio NIC on vmbr0. Pass [] for an air-gapped VM (Root CA after one-shot Ansible bootstrap)."
  type = list(object({
    bridge      = string
    model       = optional(string, "virtio")
    firewall    = optional(bool, false)
    mac_address = optional(string)
    vlan_id     = optional(number)
  }))
  default = [{ bridge = "vmbr0" }]
}

# --- USB passthrough ---------------------------------------------------------

// Pin USB devices by physical bus-port (e.g. "3-3"), NEVER by VID:PID.
// The CardLogix HSM pair enumerates IDENTICALLY (vendor 04e6, product 5826)
// so VID:PID passthrough is ambiguous — see
// `vms/openbao/legacy/README.md` and the vault's "CardLogix HSM Receipt
// Validation and VM Setup" for the labeled-jack discipline this enforces.
variable "usb_passthrough" {
  description = "Optional USB passthrough pinned to a host bus-port (e.g. host=\"1-2\"). null = no passthrough. usb3=true forces the slot's controller to xHCI (set when the jack is on a USB 3 controller and the default EHCI fails to enumerate)."
  type = object({
    host = string
    usb3 = optional(bool, false)
  })
  default = null
}
