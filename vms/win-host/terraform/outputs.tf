# Spike outputs — enough to find the VM and confirm it picked up an IP
# (which also confirms the qemu-guest-agent + virtio NIC came up, i.e. the
# post-clone driver story works).

output "vm_id" {
  value       = proxmox_virtual_environment_vm.this.vm_id
  description = "VMID of the cloned Windows host."
}

output "name" {
  value       = proxmox_virtual_environment_vm.this.name
  description = "VM name."
}

output "ipv4_addresses" {
  value       = proxmox_virtual_environment_vm.this.ipv4_addresses
  description = "IPv4 addresses reported by the guest agent. Empty until the clone has booted far enough for qemu-ga to report — RDP to the non-loopback address as win_admin_username."
}
