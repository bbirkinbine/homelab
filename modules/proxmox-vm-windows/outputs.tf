# Mirrors modules/proxmox-vm/outputs.tf so Windows and Linux roles expose the
# same surface to their callers (inventory scripts, role outputs.tf).

output "vm_id" {
  value       = proxmox_virtual_environment_vm.this.vm_id
  description = "VMID of the created Windows VM."
}

output "name" {
  value       = proxmox_virtual_environment_vm.this.name
  description = "VM name (also the in-guest hostname)."
}

output "ipv4_addresses" {
  value       = proxmox_virtual_environment_vm.this.ipv4_addresses
  description = "IPv4 addresses reported by the qemu-guest-agent. Empty until the clone has booted far enough for the agent to report; the address can re-lease across cloudbase-init's hostname-change reboot, so re-query if it looks stale."
}
