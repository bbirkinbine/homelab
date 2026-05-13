# vms/openbao/terraform/terraform.tfvars.tpl
#
# Hydrate template for scripts/hydrate.sh. Each `kp://Homelab/...`
# placeholder is resolved against KeePassXC via `keepassxc-cli show`
# and the result is written to terraform.tfvars (gitignored, 0600).
#
# Placeholder syntax: kp://<group-path>/<entry-name>[#<field>]
#   - <group-path>  : KeePassXC group path (e.g. Homelab/Tofu)
#   - <entry-name>  : entry title within that group
#   - <field>       : optional field name; defaults to `Password` if
#                     omitted. Common fields: Password, UserName,
#                     URL, Notes.
#
# For a manual workflow (no KeePassXC), copy terraform.tfvars.example
# instead and fill in real values directly.

proxmox_endpoint  = "https://pve12t:8006/"
proxmox_api_token = "kp://Homelab/Tofu/proxmox-api-token"
proxmox_node      = "pve12t"

admin_username = "bao-admin"
ssh_public_key = "kp://Homelab/Tofu/workstation-ssh-pubkey#Notes"
