# Outputs surfaced from the shared module. After `tofu apply`, copy
# `ipv4` (or look it up via the router if the agent hasn't reported
# yet) into vms/__ROLE__/ansible/inventory.yml — `just inventory __ROLE__`
# automates that.

output "vm_id" {
  description = "The created VM's Proxmox ID."
  value       = module.__ROLE__.vm_id
}

output "ipv4" {
  description = "First non-loopback IPv4 the qemu-guest-agent reports for the VM. May be null on the first plan after create."
  value       = module.__ROLE__.ipv4
}

output "mac" {
  description = "First NIC's MAC address. Pin a DHCP reservation on the router so the VM's IP stays stable across reboots."
  value       = module.__ROLE__.mac
}

output "ansible_inventory_hint" {
  description = "Convenience string for pasting into ansible/inventory.yml after the first apply."
  value = format(
    "__ROLE___servers:\n  hosts:\n    __ROLE__:\n      ansible_host: %s\n      ansible_user: %s\n      ansible_python_interpreter: /usr/bin/python3\n      ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'",
    coalesce(module.__ROLE__.ipv4, "<paste-from-tofu-output-or-router>"),
    var.admin_username,
  )
}
