# Outputs surfaced from the shared module. After `tofu apply`, copy
# `ipv4` (or look it up via the router if the agent hasn't reported
# yet) into vms/openbao/ansible/inventory.yml.

output "vm_id" {
  description = "The created VM's Proxmox ID."
  value       = module.openbao.vm_id
}

output "ipv4" {
  description = "First non-loopback IPv4 the qemu-guest-agent reports for the VM. May be null on the first plan after create."
  value       = module.openbao.ipv4
}

output "mac" {
  description = "First NIC's MAC address. Use this to pin a DHCP reservation on the router so the OpenBao API URL stays stable across reboots."
  value       = module.openbao.mac
}

output "ansible_inventory_hint" {
  description = "Convenience string for pasting into ansible/inventory.yml after the first apply."
  // See amp-game's outputs.tf for the ansible_ssh_common_args rationale.
  value = format(
    "openbao_servers:\n  hosts:\n    openbao:\n      ansible_host: %s\n      ansible_user: %s\n      ansible_python_interpreter: /usr/bin/python3\n      ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'",
    coalesce(module.openbao.ipv4, "<paste-from-tofu-output-or-router>"),
    "bao-admin",
  )
}
