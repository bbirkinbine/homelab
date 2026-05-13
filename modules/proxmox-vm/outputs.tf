# Surface the bits a downstream Ansible inventory or operator typically wants.

output "vm_id" {
  description = "Proxmox VM ID (same as input — surfaced for symmetry)."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "Proxmox VM name."
  value       = proxmox_virtual_environment_vm.this.name
}

// First non-loopback IPv4, if the guest agent has reported one yet.
// May be null on the first plan after create (agent hasn't checked in);
// re-running `tofu refresh` or `tofu output -refresh` once the VM has
// booted typically populates it.
output "ipv4" {
  description = "First non-loopback IPv4 the qemu-guest-agent reports for the VM. May be null until the agent has checked in."
  value       = try(proxmox_virtual_environment_vm.this.ipv4_addresses[1][0], null)
}

output "mac" {
  description = "MAC address of the first network interface. Useful for setting a DHCP reservation on the router."
  value       = try(proxmox_virtual_environment_vm.this.mac_addresses[0], null)
}

output "snippet_file_id" {
  description = "ID of the uploaded cloud-init snippet (datastore:snippets/filename). Useful for debugging."
  value       = proxmox_virtual_environment_file.user_data.id
}
