# Outputs surfaced from the shared module. After `tofu apply`, run
# `just inventory nemoclaw` to fold these into ansible/inventory.yml.

output "vm_id" {
  description = "The created VM's Proxmox ID."
  value       = module.nemoclaw.vm_id
}

output "ipv4" {
  description = "First non-loopback IPv4 the qemu-guest-agent reports for the VM. May be null on the first plan after create."
  value       = module.nemoclaw.ipv4
}

output "mac" {
  description = "First NIC's MAC address. Use this to pin a DHCP reservation so any channel webhooks registered post-onboard stay valid across reboots."
  value       = module.nemoclaw.mac
}

output "ansible_inventory_hint" {
  description = "Convenience string for `scripts/write-inventory.sh nemoclaw` to paste into ansible/inventory.yml after the first apply."
  value = format(
    "nemoclaw_servers:\n  hosts:\n    nemoclaw:\n      ansible_host: %s\n      ansible_user: %s\n      ansible_python_interpreter: /usr/bin/python3\n      ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'",
    coalesce(module.nemoclaw.ipv4, "<paste-from-tofu-output-or-router>"),
    "nemo-admin",
  )
}
