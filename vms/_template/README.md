# `vms/_template/` — canonical starting point for a new role

This is **not a deployable role** — it's the skeleton every new VM role
gets copied from. It deliberately compiles (`tofu fmt -check`, `tofu
validate`, ansible-syntax-check) so you can verify your copy is still
canonical after editing, but the placeholder VMID (`8099`) and identifier
(`__ROLE__`) mean it can't actually deploy as-is.

> **Excluded from `just check-roles`.** The consistency script skips any
> `vms/_*` directory (template / scaffolding convention). The template
> itself stays canonical by being copy-tested whenever someone uses it
> to create a new role.

## Using the template

From the repo root:

```bash
cp -r vms/_template vms/<newrole>
cd vms/<newrole>

# Replace __ROLE__ everywhere — directory, identifiers, comments. The
# placeholder is a valid HCL/YAML identifier so it's already syntactically
# parsed; you just need to swap names.
git ls-files -o --exclude-standard | xargs sed -i '' 's/__ROLE__/<newrole>/g'   # macOS
# (Linux: `sed -i 's/__ROLE__/<newrole>/g'`)

# Rename the ansible role directory too.
mv ansible/roles/__ROLE__ ansible/roles/<newrole>
```

Then sweep for `# TODO:` markers — each one flags a place that needs
real content:

```bash
grep -rn 'TODO:' .
```

Concrete swap-out list (in addition to the `__ROLE__` rename):

- `terraform/main.tf` — pick a unique `vm_id` per
  [ADR-0008](../../docs/decisions/0008-service-vmid-range.md) (services
  8000-8099, workloads 100-399); right-size `cores` / `memory_mb` /
  `disk_size_gb`; replace the sizing-rationale comments.
- `terraform/variables.tf` — keep the storage knobs (the convention
  every role follows). Override the `disk_storage` / `snippets_storage`
  defaults only if the role is hardware-pinned or I/O-latency-sensitive.
  See [vms/amp-game/terraform/variables.tf](../amp-game/terraform/variables.tf)
  and [vms/rootca/terraform/variables.tf](../rootca/terraform/variables.tf)
  for the two override patterns.
- `cloud-init/user-data.yaml.tftpl` — identity only. Hostname, admin
  user, SSH key. Resist the urge to install software here; that's
  Ansible's job (cloud-init runs once per instance-id, Ansible is
  idempotent across reruns).
- `ansible/roles/<newrole>/tasks/main.yml` — replace the commented-out
  starter tasks with the role's real work. See
  [vms/openbao/ansible/roles/openbao/tasks/main.yml](../openbao/ansible/roles/openbao/tasks/main.yml)
  for a service-VM example.
- `ansible/roles/<newrole>/defaults/main.yml` — define the variables
  your tasks reference. Empty file is a valid minimum; remove the
  TODO comment if there are no defaults to declare.
- `ansible/roles/<newrole>/handlers/main.yml` — keep the `Reload
  systemd` handler; uncomment the `Restart` / `Reload ufw` ones if
  your role manages a service or firewall rules.
- `ansible/roles/<newrole>/meta/main.yml` — one-line description.
- `README.md` — write the role's README (this template's README does
  NOT get copied as-is; you're writing a new one). Use
  [vms/openbao/README.md](../openbao/README.md) as the canonical
  structure: Layout / Prerequisites / Deploy / First-init ceremony /
  Operations / Sizing / Ports / Files / Related.

When you're done, validate:

```bash
just check-roles            # picks up the new role automatically
just check <newrole>        # per-role preflight (ssh, Proxmox API, template, snippets)
just plan <newrole>         # tofu plan against the live cluster
```

## What this template assumes

- **Cluster-mobile by default.** Storage defaults to `nas-vms` so a
  freshly-applied role can live-migrate. Hardware-pinned roles
  (USB / eGPU passthrough) override `disk_storage` to `local-lvm`
  and `snippets_storage` to `local` — cross-reference
  [vms/rootca/](../rootca/) for the pinned pattern.
- **Ubuntu 24.04 base** from `packer/ubuntu-24-04-base/`. Per-node
  template VMIDs map (9100 on pve12t, 9101 on pve13m, 9102 on pve13t)
  per [ADR-0006](../../docs/decisions/0006-packer-templates-per-node.md).
- **bpg/proxmox provider** pinned `~> 0.66`. Matches the rest of the
  lab; bump deliberately when the module bumps.
- **Identity-only cloud-init.** Hostname + admin user + SSH key.
  Everything else is Ansible.
- **One Ansible play** at `ansible/site.yml` against the `<role>_servers`
  group (pluralized to dodge Ansible 2.16+ group-vs-host name warnings).

## What this template does NOT include

Conscious omissions — add them only when the role actually needs them:

- USB passthrough — see [vms/rootca/terraform/main.tf](../rootca/terraform/main.tf)
  for the `usb_passthrough` shape (pinned by host bus-port, NOT VID:PID).
- PCIe / eGPU passthrough — see [vms/llm/terraform/main.tf](../llm/terraform/main.tf)
  for the `hostpci_devices` shape (references a Proxmox cluster-wide PCI
  resource mapping by name; mapping is a one-time bring-up step).
- Air-gap toggle — [vms/rootca/](../rootca/) shows the conditional NIC
  pattern (`enable_network = true/false` + `network_devices = []` to
  remove declaratively).
- HA / multi-host inventory — `site.yml` and `inventory.yml.example`
  default to a single host. Pluralized group name already supports
  HA, just add hosts.
- Pre-flip storage pin — only applies to roles created before nas-vms
  became the cluster-mobile default (openbao / openclaw / nemoclaw).
  New roles don't need it.

## Maintaining the template

If a new convention emerges across roles (the way `disk_storage` /
`snippets_storage` surfacing became a convention during the nas-vms
default flip), update the template to match. Run `just check-roles`
afterward — though it skips the template, the same checks that protect
real roles should pass against the template by construction.

Two anti-patterns to avoid:

- **Don't add role-specific cruft here.** The template's value is in
  being minimal and generic. If you're tempted to add "the openbao
  way of doing X" or "the rootca air-gap toggle," add it to the
  documentation pointing back to those roles instead.
- **Don't let the template diverge from real roles silently.** When
  the storage-knob convention landed, the template was created
  reflecting that convention. The next cross-cutting change should
  update both the affected roles AND the template in the same branch.
