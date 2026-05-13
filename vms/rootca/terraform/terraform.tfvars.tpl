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

encrypted_storage_pool = "rootca-encrypted"
snippets_storage       = "local"

hsm_usb_host_port = "1-2"
hsm_usb3          = false
