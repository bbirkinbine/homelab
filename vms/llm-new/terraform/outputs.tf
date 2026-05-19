# Outputs surfaced from the shared module. After `tofu apply`, copy
# `ipv4` (or look it up via the router if the agent hasn't reported
# yet) into vms/llm/ansible/inventory.yml — `just inventory llm`
# automates that.

output "vm_id" {
  description = "The created VM's Proxmox ID."
  value       = module.llm.vm_id
}

output "ipv4" {
  description = "First non-loopback IPv4 the qemu-guest-agent reports for the VM. May be null on the first plan after create."
  value       = module.llm.ipv4
}

output "mac" {
  description = "First NIC's MAC address. Pin a DHCP reservation on the router so the VM's IP stays stable across reboots."
  value       = module.llm.mac
}

output "ansible_inventory_hint" {
  description = "Convenience string for pasting into ansible/inventory.yml after the first apply."
  value = format(
    "llm_servers:\n  hosts:\n    llm:\n      ansible_host: %s\n      ansible_user: %s\n      ansible_python_interpreter: /usr/bin/python3\n      ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'",
    coalesce(module.llm.ipv4, "<paste-from-tofu-output-or-router>"),
    var.admin_username,
  )
}
