# vms/rootca/terraform/terraform.tfvars.tpl
#
# Hydrate template — resolved by scripts/hydrate.sh against KeePassXC.
# See vms/openbao/terraform/terraform.tfvars.tpl for placeholder syntax.

proxmox_endpoint  = "https://pve12t:8006/"
proxmox_api_token = "kp://Homelab/Tofu/proxmox-api-token"
proxmox_node      = "pve12t"

admin_username = "rootca-admin"
ssh_public_key = "kp://Homelab/Tofu/workstation-ssh-pubkey#Notes"

# Bootstrap mode by default. Flip to false manually in
# terraform.tfvars after Ansible has installed the HSM stack.
enable_network = true

# Storage overrides — uncomment to deviate from the defaults in
# variables.tf. rootca defaults to local-lvm + per-node `local` snippets
# because the VM is hardware-pinned to pve12t (HSM USB passthrough) and
# never live-migrates. Encryption is handled INSIDE the guest (LUKS
# partition on the back half of disk_storage, carved by the Ansible
# role), so the underlying Proxmox pool can be plain local-lvm.
# Flip both to "nas-vms" only if pve12t runs out of local space —
# functionally fine, but adds an NFS dependency to a deliberately
# self-contained offline-CA VM.
# disk_storage     = "local-lvm"
# snippets_storage = "local"

hsm_usb_host_port = "1-2"
hsm_usb3          = false
