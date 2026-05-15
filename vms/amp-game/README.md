# amp-game

VM running [CubeCoders AMP](https://cubecoders.com/AMP) for hosting game
servers (Minecraft Java + Bedrock by default, ARK/Rust/7DTD and other
Steam-based games optional).

Cloned at deploy time from the Ubuntu 24.04 base template (per-node VMID
per [ADR-0006](../../docs/decisions/0006-packer-templates-per-node.md));
cloud-init lays down hostname + admin user + SSH key only. Ansible installs
apt prerequisites, opens ufw ports (8080/tcp AMP UI, 25565/tcp+udp
Minecraft), enables unattended-upgrades. **AMP itself is operator-installed**
post-Ansible via `bash <(curl -fsSL https://getamp.sh)` — the AMP installer
is interactive (license key, dashboard creds, Standalone mode) and not
amenable to fully-automated provisioning. This mirrors openbao's "Ansible
installs the service, `bao operator init` is operator ceremony" pattern.

VMID `110` per [ADR-0008](../../docs/decisions/0008-service-vmid-range.md)
(workload range 100-399). Services like openbao (8030) and rootca (8031)
live in the 8000-8099 range, kept distinct from workloads.

The legacy shell-script + cloud-init shape is preserved under
[`legacy/`](legacy/README.md) for reference.

## Deployment flow

The Justfile recipes are parameterized by role name. From repo root:

```bash
# One-time per workstation: install Galaxy collections.
just ansible-deps amp-game

# Resolve KeePassXC placeholders into vms/amp-game/terraform/terraform.tfvars.
just hydrate amp-game

# Per session/reboot: load your homelab SSH key into the agent if it
# isn't already. (preflight fails with "ssh-agent has no keys loaded"
# otherwise.) Skip if macOS keychain integration is set up.
ssh-add -l >/dev/null 2>&1 || ssh-add ~/.ssh/id_ed25519_homelab

# Verify ssh/Proxmox/template/snippets prerequisites.
just check amp-game

# Plan + apply.
just plan amp-game
just apply amp-game

# Paste tofu output into the static Ansible inventory.
just output amp-game
$EDITOR vms/amp-game/ansible/inventory.yml          # ansible_host = <ipv4>

# Run the role's playbook (apt deps + ufw + unattended-upgrades).
just ansible amp-game
```

After Ansible completes, the VM is in the state described in [Post-deploy
ceremony](#post-deploy-ceremony) below — bootstrap complete, AMP not yet
installed.

## Post-deploy ceremony

The Ansible role intentionally stops short of running AMP's installer.
Operator runs the ceremony manually:

1. **SSH in:**

   ```bash
   ssh amp-admin@<vm-ip>
   ```

2. **Run the AMP installer:**

   ```bash
   bash <(curl -fsSL https://getamp.sh)
   ```

   `https://getamp.sh` is CubeCoders' canonical short URL (302-redirects
   to their Cloudflare-fronted CDN). Prefer the short URL over hardcoding
   the CDN URL so future CDN changes don't break.

   Installer prompts:
   - **Dashboard username + password**: your choice.
   - **"Run Docker?"**: `n` for vanilla Minecraft (no isolation needed).
     Answer `y` only if you're hosting Steam games (ARK, Rust, 7DTD)
     where Docker isolates library/glibc conflicts.
   - **"Configure HTTPS?"**: `n` (LAN-only).

3. **Web UI**: open `http://<vm-ip>:8080`, paste your CubeCoders license
   key, choose **Standalone** mode.

4. **Game-server config**: AMP dashboard → create your first instance,
   pick a game (Minecraft Java / Bedrock / Steam title), AMP handles
   the rest.

After this, day-to-day admin is via the AMP web UI — no Linux access
required for game-server management.

## Sizing

Defaults in [`terraform/variables.tf`](terraform/variables.tf):

| Resource | Default | When to bump |
| --- | --- | --- |
| vCPU | 4 | Modded Minecraft: 6-8. Steam games: 6+. Multiple instances: scale linearly. |
| RAM | 12288 MB (12 GiB) | Modpacks: 24-32 GiB. Multiple instances: ~6 GiB per instance + AMP overhead. |
| Disk | 100 GiB | Pure Steam-game host: 200+ GiB (game installs balloon). |
| balloon | 0 (disabled) | Don't enable — game-server latency suffers under memory pressure. |
| Storage | `local-lvm` (NVMe) | Stay on local-lvm. Game-server I/O latency outweighs cluster-mobility from `nas-vms`. |

Override per deploy in `terraform.tfvars` (uncomment the sizing lines).

## Ports

| Port | Protocol | Source | Purpose |
| --- | --- | --- | --- |
| 22 | tcp | LAN | SSH (open by the Packer base) |
| 8080 | tcp | LAN | AMP web UI (installer default; change `amp_web_ui_port` in Ansible defaults if it shifts) |
| 25565 | tcp | LAN | Minecraft Java |
| 25565 | udp | LAN | Minecraft Bedrock / query |

ufw is set inside the VM by Ansible. Perimeter firewall (router) is what
gates external access — port-forward only when guests need to connect
from outside the LAN.

## Operations

### Find the VM's IP

DHCP lease, so the IP can change. Three lookups:

1. **`tofu output ipv4`** in `vms/amp-game/terraform/` — what qemu-guest-agent
   reports, scraped by the provider. Usually the easiest.
2. **Proxmox Web UI** → VM 110 → Summary tab → "IPs" row.
3. **Router DHCP lease table** by hostname `amp-game` or by MAC (from
   `tofu output mac`).

For stability, pin a DHCP reservation on the router using the MAC.

### Resize a running VM

Edit `terraform.tfvars` to bump sizing, then `just apply amp-game`. The
provider's clone block reconciles in place:

```bash
# Edit terraform.tfvars: uncomment + raise vm_memory_mb / vm_cores
just plan amp-game        # confirm only memory/cores change
just apply amp-game
```

Memory grows live (no reboot needed when balloon=0). Cores require a
VM reboot to take effect — the provider triggers it automatically.

### Recovery

- **Take a Proxmox snapshot** before risky changes (UI: VM 110 → Snapshots).
- **Roll back**: `qm rollback 110 <snapshot-name>` on the node.
- **Game-server-level backups**: AMP has its own backup feature in the
  web UI. Configure scheduled backups under each instance's Schedule tab.

### Destroy and rebuild

```bash
just destroy amp-game     # or: tofu destroy in vms/amp-game/terraform/
just apply amp-game       # re-creates the VM; cloud-init re-runs identity
just ansible amp-game     # re-applies prereqs + ufw + unattended-upgrades
# Then re-run the AMP installer ceremony (Post-deploy ceremony above).
```

## Legacy

The pre-port shell+packer shape (legacy `deploy.sh` + `cloud-init/user-data.yaml`)
is preserved under [`legacy/`](legacy/README.md). It still works as a
reference for the deploy steps and ufw/unattended-upgrades patterns that
moved into the Ansible role.

## Related

- [`docs/0-scratch-build-order.md`](../../docs/0-scratch-build-order.md) — full lab bring-up sequence
- [`docs/deploying-vms.md`](../../docs/deploying-vms.md) — role-class chooser + 7-step VM flow
- [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) — workstation setup, hydrate flow
- [`vms/openbao/README.md`](../openbao/README.md) — canonical OpenTofu + Ansible + cloud-init role (this role is the second instance of the pattern)
- [ADR-0006](../../docs/decisions/0006-packer-templates-per-node.md) — per-node template VMIDs
- [ADR-0008](../../docs/decisions/0008-service-vmid-range.md) — service vs workload VMID convention
