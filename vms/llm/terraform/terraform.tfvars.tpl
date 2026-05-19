# vms/llm/terraform/terraform.tfvars.tpl
#
# Hydrate template for scripts/hydrate.sh. Each `kp://Homelab/...`
# placeholder is resolved against KeePassXC via `keepassxc-cli show`
# and the result is written to terraform.tfvars (gitignored, 0600).
#
# For a manual workflow (no KeePassXC), copy terraform.tfvars.example
# instead and fill in real values directly.

proxmox_endpoint  = "https://pve12t:8006/"
proxmox_api_token = "kp://Homelab/Tofu/proxmox-api-token"
proxmox_node      = "pve12t"

admin_username = "llm-admin"
ssh_public_key = "kp://Homelab/Tofu/workstation-ssh-pubkey#Notes"

# eGPU passthrough mapping name. The mapping itself is created once at
# the cluster level (see vms/llm/README.md "PCI mapping prereq"); this
# variable just references it by name. Change ONLY if you named the
# mapping something different at create time.
gpu_pci_mapping = "rtx-3090"

# Storage overrides — uncomment to deviate from the defaults in
# variables.tf (nuc12-fast / local — pinned to pve12t alongside the eGPU).
# Flip to nas-vms only for a planned move to a different node (which
# also requires moving the eGPU mapping and IOMMU setup).
# disk_storage     = "nuc12-fast"
# snippets_storage = "local"

# Sizing overrides — uncomment any of these to deviate from the
# defaults in variables.tf (6 cores / 32 GiB / 300 GiB).
# vm_cores        = 8
# vm_memory_mb    = 49152
# vm_disk_size_gb = 500
