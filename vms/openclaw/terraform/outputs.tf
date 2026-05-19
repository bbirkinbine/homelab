# Outputs surfaced from the shared module. After `tofu apply`, run
# `just inventory openclaw` to fold these into ansible/inventory.yml.

output "vm_id" {
  description = "The created VM's Proxmox ID."
  value       = module.openclaw.vm_id
}

output "ipv4" {
  description = "First non-loopback IPv4 the qemu-guest-agent reports for the VM. May be null on the first plan after create."
  value       = module.openclaw.ipv4
}

output "mac" {
  description = "First NIC's MAC address. Use this to pin a DHCP reservation on the router so the gateway URL (http://<ip>:18789) stays stable across reboots — channel webhooks/QR pairings expect a stable host."
  value       = module.openclaw.mac
}

output "ansible_inventory_hint" {
  description = "Convenience string for `scripts/write-inventory.sh openclaw` to paste into ansible/inventory.yml after the first apply."
  value = format(
    "openclaw_servers:\n  hosts:\n    openclaw:\n      ansible_host: %s\n      ansible_user: %s\n      ansible_python_interpreter: /usr/bin/python3\n      ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'",
    coalesce(module.openclaw.ipv4, "<paste-from-tofu-output-or-router>"),
    "claw-admin",
  )
}
