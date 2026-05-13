# Outputs from the shared module. ipv4 will populate only while the
# NIC is attached (i.e. during the bootstrap window). After
# enable_network=false, the agent has no NIC to report and ipv4 is
# null — that's the correct end state.

output "vm_id" {
  description = "The created VM's Proxmox ID."
  value       = module.rootca.vm_id
}

output "ipv4" {
  description = "First non-loopback IPv4 (only while enable_network=true). Used to populate ansible/inventory.yml during bootstrap; null otherwise."
  value       = module.rootca.ipv4
}

output "mac" {
  description = "First NIC's MAC address (only while enable_network=true). Pin a DHCP reservation on the router for the duration of bootstrap so the IP stays stable across Ansible re-runs."
  value       = module.rootca.mac
}

output "ansible_inventory_hint" {
  description = "Pre-formatted inventory.yml block. Paste over vms/rootca/ansible/inventory.yml during bootstrap."
  value = format(
    "rootca_servers:\n  hosts:\n    rootca:\n      ansible_host: %s\n      ansible_user: %s\n      ansible_python_interpreter: /usr/bin/python3",
    coalesce(module.rootca.ipv4, "<bootstrap-NIC-IP-or-paste-from-router>"),
    "rootca-admin",
  )
}

output "air_gap_status" {
  description = "Human-readable summary of the network state at last apply."
  value = format(
    "network %s — %s",
    var.enable_network ? "ATTACHED" : "REMOVED",
    var.enable_network
    ? "VM is reachable over SSH; run `just ansible rootca`, verify, then flip enable_network=false in terraform.tfvars and re-apply."
    : "VM is AIR-GAPPED. All future access is via Proxmox noVNC console only."
  )
}
