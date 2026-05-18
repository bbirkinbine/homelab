# vms/openbao

OpenBao (HashiCorp Vault fork) on Ubuntu 24.04, sealed with **Shamir's
Secret Sharing** (5 shares, 3-of-5 threshold) — no HSM. Provisioned
with OpenTofu, configured with Ansible.

This is the first VM in the repo to migrate off the legacy shell
`deploy.sh` flow. Future roles (Root CA, LLM, k3s) will copy
the structure here. See [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md)
for the cross-cutting workflow.

## Layout

```text
vms/openbao/
├── README.md                  this file
├── terraform/                 VM provisioning (clone, size, cloud-init)
├── ansible/                   role config (install + service + hardening)
├── cloud-init/                first-boot identity (hostname, user, SSH key)
└── legacy/                    shell-script + HSM-passthrough predecessor
```

## Prerequisites

1. **Workstation tooling.** `brew install opentofu just keepassxc ansible`.
   First-time setup steps in [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md).
2. **Packer base template.** VM `9100` (ubuntu-24-04-base) must exist
   on the target node. If not: `packer/ubuntu-24-04-base/build-pve.sh <node>`.
3. **`tofu@pve` API token.** See [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md).
   Stash the token string in KeePassXC at `Homelab/Tofu/proxmox-api-token`.
4. **SSH access to the node + key loaded into `ssh-agent`.**
   `ssh-copy-id root@pve12t` (or whichever node `proxmox_node` points
   at), then `ssh-add ~/.ssh/id_ed25519` once per shell session. The
   `bpg/proxmox` provider uploads cloud-init snippets over SSH (not
   the HTTP API) and shells out non-interactively, so the key must
   already be in the agent before `tofu apply`. Preflight verifies
   both. See [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md)
   section **(d) Load the private key into `ssh-agent`** for the
   macOS Keychain auto-load pattern that survives reboot.
5. **Snippets storage enabled.** Datacenter → Storage → `local` →
   Edit → tick **Snippets**. Preflight reports a cure command if not.

## Deploy

From repo root:

```bash
just ansible-deps openbao   # one-time per workstation
just hydrate openbao        # render terraform.tfvars from KeePassXC
just plan openbao           # review the plan
just apply openbao          # create the VM
just inventory openbao      # write ansible/inventory.yml from tofu output (waits on guest-agent)
just ansible openbao        # install + configure OpenBao
```

End state: openbao service is **running but sealed** — `bao status`
returns `Initialized: false; Sealed: true`. The role deliberately does
NOT run `bao operator init`; that's the operator's ceremony, below.

## First-init ceremony (operator-driven, one-time)

Per [[OpenBao Homelab Setup]] Phase 3 (in the vault). Run from the VM:

```bash
ssh bao-admin@<vm-ip>
export BAO_ADDR=http://127.0.0.1:8200

# 5 shares total, any 3 unseal. Output is the only time these values
# are visible — capture immediately.
bao operator init -key-shares=5 -key-threshold=3
```

Share custody (3-of-5 means you can lose any 2 shares and still recover):

| Item | Where |
| --- | --- |
| Unseal Share 1 | KeePassXC entry `Homelab/OpenBao/unseal-1` |
| Unseal Share 2 | KeePassXC entry `Homelab/OpenBao/unseal-2` |
| Unseal Share 3 | KeePassXC entry `Homelab/OpenBao/unseal-3` |
| Unseal Share 4 | Sealed paper envelope, fire safe (home) |
| Unseal Share 5 | Sealed paper envelope, offsite (in-laws') |
| Initial Root Token | KeePassXC entry `Homelab/OpenBao/initial-root` — **revoke after first admin policy** |

Unseal:

```bash
bao operator unseal   # paste share 1
bao operator unseal   # paste share 2
bao operator unseal   # paste share 3 — unsealed
bao status            # Initialized: true; Sealed: false
```

Enable the audit log immediately (any operation without it is
unauditable):

```bash
bao login <root-token>
bao audit enable file file_path=/var/log/openbao/audit.log
```

Then proceed to Phase 3 of [[13 Homelab Blueprint]] (PKI Intermediate,
Transit, etc.).

## Operations

### After every restart — manual unseal

Shamir is the trade-off for not having an HSM: OpenBao boots **sealed**
on every reboot. Roughly 30 seconds of human time per restart:

```bash
ssh bao-admin@<vm-ip>
bao status                       # Sealed: true
bao operator unseal              # paste share 1
bao operator unseal              # paste share 2
bao operator unseal              # paste share 3
bao status                       # Sealed: false
```

### Stable IP via DHCP reservation

`just output openbao` reports the MAC of the VM's NIC. Pin a DHCP
reservation on the router so the IP doesn't rotate — Ansible's
inventory and the OpenBao API URL both reference the IP, and
re-pasting after every lease change is friction.

### Raft snapshots

Cron'd inside the VM. The role doesn't lay this down (it would need
a non-root token with `sys/storage/raft/snapshot` capability, which
requires the operator-driven init to have completed). Once you've
done the ceremony:

```bash
# As root, on the VM:
install -d -m 700 -o openbao -g openbao /backups
sudo tee /etc/cron.d/openbao-snapshot >/dev/null <<'EOF'
0 3 * * * openbao BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN_FILE=/var/lib/openbao/.bao-token /usr/bin/bao operator raft snapshot save /backups/openbao-$(date +\%F).snap 2>&1 | logger -t openbao-snapshot
EOF
```

Push snapshots offsite weekly via your preferred backup path.

### Re-run a single Ansible task

```bash
cd vms/openbao/ansible
ansible-playbook -i inventory.yml site.yml --tags <tag>   # if you've added tags
# or, run the whole playbook idempotently:
just ansible-check openbao   # --check --diff (no changes)
just ansible openbao
```

### Resize a running VM

`tofu apply` after editing `vms/openbao/terraform/main.tf`. Memory
grows live; cores require a guest reboot. Disk grows live but the
guest must `growpart` + `resize2fs` to use it (the Packer base does
this automatically on first boot only — subsequent resizes are manual).

## Destroy and rebuild

> **WARNING.** Destroying this VM means losing OpenBao's raft storage.
> If you've completed the init ceremony, the destroy + rebuild loses
> all secrets, policies, and unseal-share metadata — and the new VM
> will require its own fresh init (with **new** Shamir shares — the
> old ones unlock no barrier in the new instance). The HSM is no
> longer part of the picture, so there's no on-token state to worry
> about, but the raft state matters.
>
> **Recover instead** by restoring a snapshot into a freshly-initialized
> instance:
>
> 1. `just apply openbao` on the rebuilt VM.
> 2. `just ansible openbao`.
> 3. `bao operator init -key-shares=5 -key-threshold=3` — get new
>    shares; the operator unseals once.
> 4. `bao operator raft snapshot restore -force /backups/openbao-<date>.snap` —
>    this REPLACES the new instance's storage with the snapshot,
>    *including* the seal-encrypted barrier from the original.
> 5. Now run `bao operator unseal` 3× with the **original** Shamir
>    shares (the new init's shares unlock nothing after restore;
>    they served only to bootstrap the encryption layer).
>
> The whole loop is covered by the DR drill section of
> [[OpenBao Homelab Setup]]. Test it quarterly.

```bash
just destroy openbao        # only after a snapshot is safely offsite
just apply openbao
just ansible openbao
# then the recovery flow above
```

## Sizing

| Resource | Value | Why |
| --- | --- | --- |
| vCPU | 2 | OpenBao is light — a few goroutines, KV store, audit log |
| RAM | 2 GiB | Comfortable; ballooning disabled so mlock works |
| Disk | 32 GiB | Mostly for /var/log + audit-log retention |
| Balloon | 0 | OpenBao mlocks; ballooning would interfere |
| Machine | q35 | Matches the rest of the homelab |
| CPU type | x86-64-v3 | Common baseline across the cluster's NUCs (Alder/Raptor Lake-P/H) — supports live migration |

Override in `vms/openbao/terraform/main.tf`'s `module "openbao"` call.

## Ports

| Port | Protocol | Source | Purpose |
| --- | --- | --- | --- |
| 22 | tcp | LAN | SSH (opened by base template + Ansible) |
| 8200 | tcp | LAN | OpenBao API |
| 8201 | tcp | — | OpenBao cluster port — **intentionally closed**; opens if/when you run an HA pair |

UFW inside the VM; perimeter is the LAN router. Keep this LAN-only
unless you front it with mTLS at a reverse proxy.

## Files

- `terraform/main.tf` — provider + module call (sizing, cloud-init).
- `terraform/variables.tf` — five inputs (endpoint, token, node, user, key).
- `terraform/terraform.tfvars.tpl` — committed, kp:// placeholders.
- `terraform/terraform.tfvars.example` — committed, manual-fill alternative.
- `cloud-init/user-data.yaml.tftpl` — identity only.
- `ansible/site.yml` + `roles/openbao/` — install + config.
- `legacy/` — HSM-era artifacts predating the Shamir-seal switch; see [`legacy/README.md`](legacy/README.md).

## Related

- [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) — workstation setup, hydrate flow, state.
- [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md) — API token + role.
- `modules/proxmox-vm/` — the shared module this role calls.
- `packer/ubuntu-24-04-base/` — produces template 9100.
- Vault doc `OpenBao Homelab Setup.md` — canonical Shamir-seal runbook.
- Vault doc `Homelab Repo Migration to OpenTofu.md` — the broader plan this implements.
