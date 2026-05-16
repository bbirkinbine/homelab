# homelab Justfile — wraps OpenTofu + Ansible flows per role.
#
# All recipes that touch infra (plan, apply, destroy, ansible) accept
# a `role` argument and operate on vms/<role>/. List options:
#   just                  # show available recipes
#   just plan openbao
#   just apply openbao
#   just ansible openbao
#
# Why a Justfile and not Make: Make's tab-vs-space pitfall and
# implicit-rule baggage cost more than they buy on a script-wrapper
# usage. Just is one binary, no implicit anything, and parameterized
# recipes are first-class.

default:
    @just --list

# --- secrets -----------------------------------------------------------------

# Render terraform.tfvars from terraform.tfvars.tpl via KeePassXC (--force to rehydrate).
hydrate role *FLAGS:
    @./scripts/hydrate.sh {{role}} {{FLAGS}}

# --- preflight ---------------------------------------------------------------

# (internal) Verify ssh/Proxmox/template/snippets prerequisites for `role`.
_check role:
    @./scripts/preflight.sh {{role}}

# Run preflight standalone (without applying).
check role: (_check role)

# --- tofu --------------------------------------------------------------------

# Run `tofu init -upgrade` in the role's workspace.
init role: (_check role)
    cd vms/{{role}}/terraform && tofu init -upgrade

# Show the `tofu plan` for `role` (runs preflight + hydrate first).
plan role: (_check role) (hydrate role)
    cd vms/{{role}}/terraform && tofu init -upgrade && tofu plan

# Apply the plan for `role` (runs preflight + hydrate first).
apply role: (_check role) (hydrate role)
    cd vms/{{role}}/terraform && tofu apply

# Destroy `role`'s VM. WARNING — for openbao this wipes raft storage.
destroy role:
    cd vms/{{role}}/terraform && tofu destroy

# Print tofu outputs for `role` (ipv4, mac, inventory hint).
output role:
    cd vms/{{role}}/terraform && tofu output

# --- ansible -----------------------------------------------------------------

# Install the role's Galaxy collections (one-time per workstation).
ansible-deps role:
    cd vms/{{role}}/ansible && ansible-galaxy collection install -r requirements.yml

# Write vms/<role>/ansible/inventory.yml from `tofu output ansible_inventory_hint` (replaces the manual paste step).
inventory role:
    @./scripts/write-inventory.sh {{role}}

# Run the role's site.yml against vms/<role>/ansible/inventory.yml.
ansible role:
    cd vms/{{role}}/ansible && ansible-playbook -i inventory.yml site.yml

# Same, but --check --diff (no changes applied, drift report only).
ansible-check role:
    cd vms/{{role}}/ansible && ansible-playbook -i inventory.yml site.yml --check --diff

# --- pve-hosts (layer 0) -----------------------------------------------------
#
# Separate recipes from `ansible <role>` above because layer 0 targets
# Proxmox hosts (not VMs) and lives under pve-hosts/, not vms/<role>/.
# Inventory shape and preconditions diverge enough that a unified
# recipe would be mostly branching.

# Install Galaxy collections for the pve-host role (one-time per workstation).
pve-hosts-deps:
    cd pve-hosts/ansible && ansible-galaxy collection install -r requirements.yml

# Apply the pve-host role across all PVE nodes in inventory.yml.
pve-hosts:
    cd pve-hosts/ansible && ansible-playbook -i inventory.yml site.yml

# Same, but --check --diff (drift report only, no changes applied).
pve-hosts-check:
    cd pve-hosts/ansible && ansible-playbook -i inventory.yml site.yml --check --diff

# Apply against a single node — handy when pve13t first arrives.
#   just pve-hosts-one pve13t
pve-hosts-one host:
    cd pve-hosts/ansible && ansible-playbook -i inventory.yml site.yml --limit {{host}}

# --- pbs-hosts (layer 0, parallel to pve-hosts) ------------------------------
#
# Mirror of the pve-hosts-* recipes for the Proxmox Backup Server hosts
# under pbs-hosts/. Same separation rationale: layer 0 against bare-
# metal PBS, not VMs; inventory + preconditions diverge from pve-hosts
# enough that a shared recipe would mostly be branching.

# Install Galaxy collections for the pbs-host role (one-time per workstation).
pbs-hosts-deps:
    cd pbs-hosts/ansible && ansible-galaxy collection install -r requirements.yml

# Apply the pbs-host role across all PBS hosts in inventory.yml.
pbs-hosts:
    cd pbs-hosts/ansible && ansible-playbook -i inventory.yml site.yml

# Same, but --check --diff (drift report only, no changes applied).
pbs-hosts-check:
    cd pbs-hosts/ansible && ansible-playbook -i inventory.yml site.yml --check --diff

# Apply against a single PBS host (useful when more than one PBS host exists).
#   just pbs-hosts-one pbs01
pbs-hosts-one host:
    cd pbs-hosts/ansible && ansible-playbook -i inventory.yml site.yml --limit {{host}}

# --- housekeeping ------------------------------------------------------------

# `tofu fmt -recursive` across every .tf file in the repo.
fmt:
    tofu fmt -recursive .

# `tofu validate` against a specific role's workspace.
validate role:
    cd vms/{{role}}/terraform && tofu init -backend=false && tofu validate

# `tofu fmt -check` — fails if any .tf is mis-formatted.
fmt-check:
    tofu fmt -check -recursive .

# Lint + syntax-check the helper scripts. shellcheck must be on PATH.
shell-lint:
    bash -n scripts/preflight.sh scripts/hydrate.sh
    shellcheck scripts/preflight.sh scripts/hydrate.sh
