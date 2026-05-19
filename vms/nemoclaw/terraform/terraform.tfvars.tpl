# vms/nemoclaw/terraform/terraform.tfvars.tpl
#
# Hydrate template for scripts/hydrate.sh. Each `kp://Homelab/...`
# placeholder is resolved against KeePassXC via `keepassxc-cli show`
# and the result is written to terraform.tfvars (gitignored, 0600).
#
# For a manual workflow (no KeePassXC), copy terraform.tfvars.example
# instead and fill in real values directly.

proxmox_endpoint  = "https://pve13m:8006/"
proxmox_api_token = "kp://Homelab/Tofu/proxmox-api-token"
proxmox_node      = "pve13m"

admin_username = "nemo-admin"
ssh_public_key = "kp://Homelab/Tofu/workstation-ssh-pubkey#Notes"

# Pre-flip pin: nemoclaw was created on per-node local-lvm before nas-vms
# became the role default. Keep these two lines to make `tofu apply` a
# no-op for storage; remove them to let the next apply move the boot disk
# to nas-vms (destructive — disk is recreated). See vms/nemoclaw/README.md
# "Storage migration" for the manual move path that avoids a recreate.
disk_storage     = "local-lvm"
snippets_storage = "local"
