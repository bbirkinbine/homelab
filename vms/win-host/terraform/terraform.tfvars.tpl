# vms/win-host/terraform/terraform.tfvars.tpl
#
# Hydrate template for scripts/hydrate.sh. Each `kp://Homelab/...` placeholder
# is resolved against KeePassXC via `keepassxc-cli show` and written to
# terraform.tfvars (gitignored, 0600). For a manual workflow, copy this to
# terraform.tfvars and fill in real values.
#
# Placeholder syntax: kp://<group-path>/<entry-name>[#<field>]
#   field defaults to `Password` if omitted.

proxmox_endpoint  = "https://pve12t2:8006/"
proxmox_api_token = "kp://Homelab/Tofu/proxmox-api-token"
proxmox_node      = "pve12t2"

# Named admin. The username is non-secret (set literally below); only the
# password comes from KeePassXC. Create a KeePassXC entry titled
# `win-host-labadmin` in group `Homelab/Tofu`, and put the Windows admin
# password in its **Password** field (the kp:// ref has no #field, so it reads
# Password). Type one in or use KeePassXC's generator — either way you know it.
#
# Password rules:
#   - Windows complexity: >=12 chars, 3 of 4 of upper/lower/digit/special, and
#     must NOT contain "labadmin". (No custom policy is set on the template, so
#     the Windows default applies; meet complexity anyway — if New-LocalUser
#     rejects it you get NO labadmin and must recover via `qm guest exec`.)
#   - Tooling: the value is written into this HCL tfvars as a quoted string.
#     Hard-prohibited: `"` and `\`. Also avoid the sequences `${` and `%{`
#     (HCL interpolation/directives). Bulletproof: in KeePassXC's generator
#     exclude `"\{}` — that kills both and the ${/%{ risk. Everything else
#     (~ ! @ # $ % ^ & * etc.) is fine; the Windows side gets it base64-encoded.
win_admin_username = "labadmin"
win_admin_password = "kp://Homelab/Tofu/win-host-labadmin"

# Storage — spike defaults to local-lvm + local (matches the 9203 template, so
# the clone is a same-storage op; node-pinned to pve12t2). Uncomment to make it
# cluster-mobile on nas-vms once boot+login is proven.
# disk_storage     = "nas-vms"
# snippets_storage = "nas-vms"
