# Outputs surfaced from the shared module. After `tofu apply`, copy
# `ipv4` (or look it up via the router if the agent hasn't reported
# yet) into vms/amp-game/ansible/inventory.yml.

output "vm_id" {
  description = "The created VM's Proxmox ID."
  value       = module.amp_game.vm_id
}

output "ipv4" {
  description = "First non-loopback IPv4 the qemu-guest-agent reports for the VM. May be null on the first plan after create."
  value       = module.amp_game.ipv4
}

output "mac" {
  description = "First NIC's MAC address. Use this to pin a DHCP reservation on the router so the AMP web UI URL stays stable across reboots."
  value       = module.amp_game.mac
}

output "ansible_inventory_hint" {
  description = "Convenience string for pasting into ansible/inventory.yml after the first apply."
  // `ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'` lets
  // the first `just ansible <role>` accept the freshly-regenerated SSH
  // host key without a manual `ssh ...'echo ok'` step. `accept-new` only
  // accepts unknown keys — it still rejects a CHANGED key, which is the
  // safer half of StrictHostKeyChecking=no. Future-deploy churn (clone
  // gets a new IP via DHCP) doesn't strand the operator.
  value = format(
    "amp_game_servers:\n  hosts:\n    amp-game:\n      ansible_host: %s\n      ansible_user: %s\n      ansible_python_interpreter: /usr/bin/python3\n      ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'",
    coalesce(module.amp_game.ipv4, "<paste-from-tofu-output-or-router>"),
    "amp-admin",
  )
}
