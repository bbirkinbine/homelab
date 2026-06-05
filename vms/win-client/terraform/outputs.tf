# Re-exported from the Windows module. Enough to find the VM and confirm it
# picked up an IP (which also confirms the qemu-guest-agent + virtio NIC came up).

output "vm_id" {
  value       = module.win_client.vm_id
  description = "VMID of the cloned Windows host."
}

output "name" {
  value       = module.win_client.name
  description = "VM name (also the in-guest hostname)."
}

output "ipv4_addresses" {
  value       = module.win_client.ipv4_addresses
  description = "IPv4 addresses reported by the guest agent. Empty until the clone has booted far enough for qemu-ga to report — RDP to the non-loopback address as win_admin_username."
}
