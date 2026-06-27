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
#
# Opt-in cross-inventory loading: if the role's ansible/ dir contains a
# .extra-inventories file (one inventory path per line, repo-relative),
# each path is added as an extra `-i` flag BEFORE the role's own
# inventory.yml. Lets a role (e.g. monitoring) read hostvars from
# pve-hosts / pbs-hosts / guest VM inventories without duplicating IPs.
#
# Missing inventories are skipped silently — guest VM inventory.yml's
# are produced by `just inventory <role>` after a deploy and may not
# exist for every role yet. The monitoring play's hosts_file task uses
# groups.get(...) defensively so absent groups just don't render an
# /etc/hosts entry for that role's host.
ansible role:
    cd vms/{{role}}/ansible && \
      extra_inv="" ; \
      if [ -f .extra-inventories ]; then \
        while IFS= read -r p; do \
          [ -z "$p" ] && continue ; \
          [ "${p#\#}" != "$p" ] && continue ; \
          [ -f "../../../$p" ] || continue ; \
          extra_inv="$extra_inv -i ../../../$p" ; \
        done < .extra-inventories ; \
      fi ; \
      ansible-playbook $extra_inv -i inventory.yml site.yml

# Same, but --check --diff (no changes applied, drift report only).
ansible-check role:
    cd vms/{{role}}/ansible && \
      extra_inv="" ; \
      if [ -f .extra-inventories ]; then \
        while IFS= read -r p; do \
          [ -z "$p" ] && continue ; \
          [ "${p#\#}" != "$p" ] && continue ; \
          [ -f "../../../$p" ] || continue ; \
          extra_inv="$extra_inv -i ../../../$p" ; \
        done < .extra-inventories ; \
      fi ; \
      ansible-playbook $extra_inv -i inventory.yml site.yml --check --diff

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

# --- pdm-hosts (layer 0, parallel to pve-hosts / pbs-hosts) ------------------
#
# Mirror of the pbs-hosts-* recipes for the Proxmox Datacenter Manager
# host under pdm-hosts/. Same separation rationale: layer 0 against the
# bare-metal PDM host, not VMs; PDM's config surface diverges enough that
# a shared recipe would mostly be branching.

# Install Galaxy collections for the pdm-host role (one-time per workstation).
pdm-hosts-deps:
    cd pdm-hosts/ansible && ansible-galaxy collection install -r requirements.yml

# Apply the pdm-host role across all PDM hosts in inventory.yml.
pdm-hosts:
    cd pdm-hosts/ansible && ansible-playbook -i inventory.yml site.yml

# Same, but --check --diff (drift report only, no changes applied).
pdm-hosts-check:
    cd pdm-hosts/ansible && ansible-playbook -i inventory.yml site.yml --check --diff

# Apply against a single PDM host (useful when more than one PDM host exists).
#   just pdm-hosts-one pdm01
pdm-hosts-one host:
    cd pdm-hosts/ansible && ansible-playbook -i inventory.yml site.yml --limit {{host}}

# --- housekeeping ------------------------------------------------------------

# `tofu fmt -recursive` across every .tf file in the repo.
fmt:
    tofu fmt -recursive .

# `tofu validate` against a specific role's workspace.
validate role:
    cd vms/{{role}}/terraform && tofu init -backend=false && tofu validate

# `tofu fmt -check` — fails if any tracked .tf is mis-formatted.
# Scoped to tracked files (via `git ls-files`) so gitignored local
# terraform.tfvars whitespace drift doesn't fail the check — repo
# state is what we care about, not the operator's local sizing overrides.
fmt-check:
    git ls-files -- '*.tf' | xargs tofu fmt -check

# Run all role-consistency checks across vms/*/terraform/. See the script
# header for what's checked. Intended as a pre-PR / pre-merge sanity pass
# when a change touches multiple role definitions.
check-roles:
    @./scripts/check-role-consistency.sh

# Lint + syntax-check the helper scripts. shellcheck must be on PATH.
# `-S warning` skips info-level findings (e.g. SC2029, which flags
# every `ssh host "cmd $localvar"` pattern even when client-side
# expansion is exactly the intent).
shell-lint:
    bash -n scripts/preflight.sh scripts/hydrate.sh scripts/check-role-consistency.sh scripts/cluster-shutdown.sh scripts/cluster-poweroff.sh scripts/cluster-coldstart.sh scripts/nas-ups-guardian.sh scripts/pbs-config-backup.sh
    shellcheck -S warning scripts/preflight.sh scripts/hydrate.sh scripts/check-role-consistency.sh scripts/cluster-shutdown.sh scripts/cluster-poweroff.sh scripts/cluster-coldstart.sh scripts/nas-ups-guardian.sh scripts/pbs-config-backup.sh

# --- cluster ops -------------------------------------------------------------

# Graceful ACPI shutdown of every running VM cluster-wide, for a
# maintenance window. DRY RUN by default — pass --apply to act. Set the
# NODES env var to your cluster's LAN IPs first; see the script header
# for --timeout/--force/EXCLUDE (e.g. the Minecraft host).
#   NODES="10.0.0.12 10.0.0.13 ..." just shutdown
#   NODES="..." just shutdown --apply --force
shutdown *FLAGS:
    @./scripts/cluster-shutdown.sh {{FLAGS}}

# Restore + verify corosync ring1 / the TB fabric after a cold start (the
# recurring maintenance-window case). DRY RUN (read-only verify) by default —
# pass --apply to ifreload the tbnet-* interfaces and re-verify. Set the
# NODES env var to your cluster's LAN IPs first; see the script header.
#   NODES="10.0.0.12 10.0.0.13 ..." just coldstart           # verify only
#   NODES="..." just coldstart --apply                       # remediate
coldstart *FLAGS:
    @./scripts/cluster-coldstart.sh {{FLAGS}}
