# vms/amp-game/terraform/terraform.tfvars.tpl
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

proxmox_endpoint  = "https://pve13t:8006/"
proxmox_api_token = "kp://Homelab/Tofu/proxmox-api-token"
proxmox_node      = "pve13t"

admin_username = "amp-admin"
ssh_public_key = "kp://Homelab/Tofu/workstation-ssh-pubkey#Notes"

# Sizing overrides — uncomment any of these to deviate from the
# defaults in variables.tf (4 cores / 12 GiB / 100 GiB).
# vm_cores        = 6
# vm_memory_mb    = 24576
# vm_disk_size_gb = 200

# Storage overrides — uncomment to deviate from the defaults in
# variables.tf. amp-game defaults to local-lvm (NVMe) + per-node `local`
# snippets because game-server I/O latency outweighs cluster-mobility.
# Flip both to "nas-vms" if you need to relocate the VM to a node without
# enough local NVMe headroom, or for a planned move that prioritizes
# mobility over I/O latency (expect a noticeable hit to world-save and
# player-join responsiveness).
# disk_storage     = "local-lvm"
# snippets_storage = "local"
