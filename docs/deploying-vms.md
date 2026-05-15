# Deploying VMs in this repo

> **Audience.** Someone (you, or a stranger reading the public repo) who
> wants to land a new VM on the Proxmox lab and isn't sure where to
> start. Orientation-first; pointers to the runbooks rather than a
> duplicate of them.

The repo's VM-provisioning shape was migrated off shell `deploy.sh`
scripts to OpenTofu + Ansible on 2026-05-11. Two roles ship today as
worked examples: `vms/openbao/` (a cluster-mobile service VM) and
`vms/rootca/` (an air-gapped, hardware-pinned VM). Everything below is
how to use that shape — and how to add new roles to it.

---

## The mental model — four layers

Same model the vault doc `Provisioning Layers — Packer, Terraform,
cloud-init, Ansible.md` describes; restated here so this doc stands
alone.

| Layer | What | Where | Re-runnable? |
| --- | --- | --- | --- |
| 1. **Packer** | Universal hardening baked into a template | Per-node templates: [`packer/ubuntu-24-04-base/`](../packer/ubuntu-24-04-base/) → 9100/9101/9102, [`packer/windows-11-base/`](../packer/windows-11-base/) → 9200/9201/9202 (see [ADR-0006](decisions/0006-packer-templates-per-node.md)) | Rarely (OS or universal-base changes) |
| 2. **OpenTofu** | VM shape — clone, size, NIC, USB, storage | `vms/<role>/terraform/` + the shared [`modules/proxmox-vm/`](../modules/proxmox-vm/) | Every config change |
| 3. **cloud-init** | Per-VM identity (hostname, admin user, SSH key) | `vms/<role>/cloud-init/user-data.yaml.tftpl` | Once per VM instance |
| 4. **Ansible** | Role-specific software install + config | `vms/<role>/ansible/` | Idempotently, forever |

The seam most people get confused by: tofu doesn't *run* cloud-init,
it *populates the data cloud-init reads* on first boot. Ansible takes
over once the VM is reachable over SSH.

---

## First decision — which role-class fits?

Three patterns ship today; new roles should fit one of them.

### A. Cluster-mobile service VM (the default)

A long-running service that wants live migration eventually, doesn't
need any host hardware, doesn't store irreplaceable state on local
disk. Examples: OpenBao (shipping), future k3s nodes. (amp-game is
intentionally NOT cluster-mobile despite being on the new shape —
its `disk_storage` is pinned to `local-lvm` for I/O latency; see
[`vms/amp-game/README.md`](../vms/amp-game/README.md).)

- **Disk storage**: `local-lvm` today; will move to `nas-vms` (NFS from
  the Asustor) when the cluster transition lands.
- **CPU type**: `x86-64-v3` (module default — common baseline across
  the NUC pair).
- **NIC**: one virtio NIC on vmbr0 (module default).
- **USB passthrough**: none.

**Template to copy:** `vms/openbao/`. Almost everything generalizes.

### B. Hardware-pinned VM (eGPU or USB-bound)

The VM has a Thunderbolt eGPU passthrough or USB-token passthrough
that ties it to one specific Proxmox node. Live migration is
impossible. Examples: future LLM role (eGPU on `pve12t`), the Root CA
(USB-HSM on `pve12t`).

- **Disk storage**: node-local (`local-lvm`, or a dedicated pool like
  `nuc12-fast` for the LLM's models cache).
- **CPU type**: `host` is fine since the VM never migrates; `x86-64-v3`
  also works.
- **NIC**: see [C] if also air-gapped, otherwise default.
- **USB passthrough**: set `usb_passthrough = { host = "<bus>-<port>" }`
  in the module call. Pin by **physical bus-port**, not VID:PID — the
  CardLogix HSM pair enumerates identically, and the labeled-jack
  discipline is the contract.

**Template to copy:** `vms/rootca/` (HSM passthrough variant) or — when
it lands — a future `vms/llm/` (eGPU passthrough variant).

### C. Air-gapped VM (no NIC after bootstrap)

A subset of [B] where the VM has no network at all after the initial
toolchain install. The only example today is the Root CA. This adds a
two-phase apply on top of the hardware-pin pattern:

1. **Bootstrap phase**: `enable_network = true` → tofu apply produces
   a VM with one NIC → Ansible installs the toolchain over SSH →
   operator verifies via SSH.
2. **Air-gap phase**: edit `terraform.tfvars` → `enable_network = false`
   → tofu apply removes the NIC declaratively → all future access is
   via Proxmox noVNC console only.

**Template to copy:** `vms/rootca/`. Read its README end-to-end before
adapting — the lifecycle is non-obvious.

---

## The repeatable flow (any role)

Once a role exists at `vms/<role>/`, the deploy sequence is identical
across all of them:

```bash
just ansible-deps <role>    # one-time per workstation — pulls Galaxy collections
just hydrate     <role>     # renders terraform.tfvars from KeePassXC
just check       <role>     # preflight: ssh, Proxmox API, template, snippets
just plan        <role>     # review the plan
just apply       <role>     # create the VM
just output      <role>     # surface the VM's IPv4 / MAC
$EDITOR vms/<role>/ansible/inventory.yml   # paste IPv4 over ansible_host
just ansible     <role>     # install + configure
```

End state varies by role (e.g. openbao is `Initialized: false; Sealed:
true`, awaiting operator init; rootca is `Sealed=true` on the LUKS
pool, awaiting operator ceremony at noVNC). See the role README.

The detailed mechanics of each step (KeePassXC entry layout, what
`preflight.sh` checks, state management, lockfile policy) live in
[`docs/opentofu-setup.md`](opentofu-setup.md). Read that once when you
first set up the workstation; refer back when something breaks.

---

## Where things are documented

Don't re-derive — read the existing doc.

| Concern | Doc |
| --- | --- |
| Workstation setup (`brew install`, env vars, KeePassXC entries) | [`docs/opentofu-setup.md`](opentofu-setup.md) |
| Proxmox API user + role + token for OpenTofu | [`docs/proxmox-tofu-permissions.md`](proxmox-tofu-permissions.md) |
| Proxmox API user + role + token for Packer | [`docs/proxmox-permissions.md`](proxmox-permissions.md) |
| GPU passthrough setup (`vfio-pci`, IOMMU, Thunderbolt eGPU) | [`docs/proxmox-gpu-passthrough.md`](proxmox-gpu-passthrough.md) |
| Shared OpenTofu module input surface | [`modules/proxmox-vm/variables.tf`](../modules/proxmox-vm/variables.tf) |
| Packer base templates | [`packer/ubuntu-24-04-base/README.md`](../packer/ubuntu-24-04-base/README.md), [`packer/windows-11-base/README.md`](../packer/windows-11-base/README.md) |
| Per-role deploy + ops | `vms/<role>/README.md` — start with [`vms/openbao/README.md`](../vms/openbao/README.md) and [`vms/rootca/README.md`](../vms/rootca/README.md) |
| Legacy shell `deploy.sh` artifacts (preserved as reference) | [`vms/openbao/legacy/`](../vms/openbao/legacy/) (USB-passthrough discovery), [`vms/amp-game/legacy/`](../vms/amp-game/legacy/) (cloud-init drive-recreate dance + ufw/unattended-upgrades pattern that moved to Ansible) |

The vault has the design context behind all of this — read the
relevant doc there if you need the *why*, not the *how*. Pointers in
the per-role READMEs.

---

## Creating a new role from scratch

The fastest path is "copy `vms/openbao/`, swap names, swap content."
Concrete steps:

1. **Pick the role-class** from the three above. Note the template VM
   you'll clone:
   - Cluster-mobile → copy `vms/openbao/`
   - Hardware-pinned with USB → copy `vms/rootca/` (and read its
     two-phase lifecycle before deciding if you need the air-gap step)
   - eGPU passthrough → not yet shipping; the `modules/proxmox-vm/`
     module will need a `hostpci` block added when the LLM role lands

2. **Copy the directory structure:**
   ```bash
   cp -r vms/openbao vms/<newrole>
   cd vms/<newrole>
   ```

3. **Edit the tofu workspace** (`vms/<newrole>/terraform/`):
   - `main.tf` — change `name`, `vm_id`, sizing, `tags`, the
     `templatefile()` template path (still points at sibling
     `cloud-init/`).
   - `variables.tf` — drop or rename variables that don't apply.
   - `terraform.tfvars.example` + `.tfvars.tpl` — update both. Pick a
     unique `VM_ID` per the convention in [ADR-0008](decisions/0008-service-vmid-range.md):
     services live in 8000-8099 (`openbao=8030`, `rootca=8031`), workloads
     in 100-399 (`amp-game=110`).

4. **Edit the cloud-init template** (`vms/<newrole>/cloud-init/user-data.yaml.tftpl`):
   - Hostname, admin username placeholders are already in the right
     shape. Add groups (e.g. `plugdev` for HSM roles) only if
     cloud-init's once-per-instance lifecycle is the right place for
     them; otherwise leave to Ansible.

5. **Replace the Ansible role** (`vms/<newrole>/ansible/roles/<newrole>/`):
   - Rename the role directory.
   - Update `meta/main.yml` and `defaults/main.yml`.
   - Rewrite `tasks/main.yml` for the role's actual concerns (apt
     repo, install, config templates, systemd, ufw).
   - The handler set in `handlers/main.yml` (reload-daemon,
     restart-service, ldconfig, reload-udev) is generic — usually
     copy as-is.
   - Update `site.yml` and `inventory.yml.example` to use the
     `<newrole>_servers` group name (avoid the "group and host with
     same name" Ansible warning).
   - Update `requirements.yml` if the role needs Galaxy collections
     beyond `community.general`.

6. **Write the role README** (`vms/<newrole>/README.md`):
   - One-paragraph intent.
   - Prerequisites (template, API token, any role-specific host setup).
   - Deploy section — paste the repeatable flow above with `<role>`
     filled in.
   - Operator ceremonies (any one-shot operations not in Ansible).
   - Destroy / rebuild warning (any state that would be lost).
   - Sizing + ports tables.
   - Related pointers (vault docs, sibling roles, shared module).

7. **No Justfile changes needed.** The recipes are parameterized by
   role name; `just plan <newrole>`, `just apply <newrole>`, etc.
   work as soon as the directory exists.

8. **Validate before deploying:**
   ```bash
   tofu fmt -recursive .
   cd vms/<newrole>/terraform && tofu init -backend=false && tofu validate
   cd ../ansible && cp inventory.yml.example /tmp/<newrole>-inv.yml \
     && ansible-playbook --syntax-check -i /tmp/<newrole>-inv.yml site.yml
   ```

9. **First-deploy test** against a sacrificial VM ID (e.g. 9999) on
   a non-default node before committing to the real `vm_id`. The
   destroy-rebuild loop is cheap once everything works.

---

## Common gotchas

- **Cluster transition is not done yet.** Hostnames stay `pveXX`
  (Inventory doc's `nuc*` are physical-chassis labels). `nas-vms`
  shared storage doesn't exist; module default is still `local-lvm`.
  See CLAUDE.md "Active context".
- **The bpg/proxmox provider's API shifts between minor versions.**
  Module is pinned `~> 0.66`; lockfile pins to v0.106.0. If you bump,
  re-validate before applying.
- **`ssh-agent` must have a key loaded when `tofu apply` runs.** The
  provider uploads cloud-init snippets over SSH (not the HTTP API);
  preflight checks this but the failure mode without preflight is
  opaque.
- **Snippets storage must allow `snippets` content type.** Datacenter
  → Storage → `local` → Edit → tick Snippets. Preflight reports a
  cure command if missing.
- **Don't mix `terraform.tfvars` and `terraform.tfvars.tpl` workflows.**
  Pick one per role: `.tpl` + `just hydrate` (KeePassXC) OR `.example`
  copied to `.tfvars` and filled in manually. The hydrate flow is the
  default; the manual flow exists for users without KeePassXC.
- **`terraform.tfvars` is gitignored.** The `.tpl` and `.example`
  versions are committed; the rendered `.tfvars` (with real secrets)
  must never be. The repo's `.gitignore` covers this; don't override
  it.

---

## Related

- [`docs/opentofu-setup.md`](opentofu-setup.md) — the workflow doc this
  doc orients you toward.
- [`docs/proxmox-tofu-permissions.md`](proxmox-tofu-permissions.md) — API
  token + role.
- `modules/proxmox-vm/` — shared module's input surface is the contract
  for what role authors can configure.
- Vault docs (Obsidian, `Projects/Homelab/`):
  - `Homelab Repo Migration to OpenTofu.md` — the migration plan this
    implements (plan-shaped, not runbook-shaped).
  - `Provisioning Layers — Packer, Terraform, cloud-init, Ansible.md`
    — conceptual 4-layer model + debugging-by-layer cheat sheet.
  - `VM Mobility — 3-Node Cluster on 2.5GbE.md` — cluster + NFS
    architecture the storage defaults will eventually shift to.
