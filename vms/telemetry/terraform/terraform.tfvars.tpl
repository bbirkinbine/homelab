# vms/telemetry/terraform/terraform.tfvars.tpl
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

proxmox_endpoint  = "https://pve12t2:8006/"
proxmox_api_token = "kp://Homelab/Tofu/proxmox-api-token"
proxmox_node      = "pve12t2"

admin_username = "telemetry-admin"
ssh_public_key = "kp://Homelab/Tofu/workstation-ssh-pubkey#Notes"

# Storage overrides — this role defaults to local-lvm (node NVMe) +
# per-node `local` snippets in variables.tf, so the VM is node-pinned.
# Uncomment and flip both to nas-vms only to make it cluster-mobile
# (changing disk_storage on a live VM recreates the disk — use
# `qm move-disk` for an in-place move instead).
# disk_storage     = "nas-vms"
# snippets_storage = "nas-vms"

# NIC MAC pin — deliberately NOT set here. It lives in the gitignored
# nic.auto.tfvars (loaded automatically, never rewritten by hydrate), so
# the real MAC stays out of the public repo. See README.md "MAC pin".
# nic_mac_address = "BC:24:11:XX:XX:XX"
