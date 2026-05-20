# Credentials index — KeePassXC entries the homelab IaC consumes

> Single-page sanity check. Skim it before standing up a new role, or
> when something fails with `401 Unauthorized` and you want to confirm
> the credential exists at the path the tool is reading.

This file is **descriptive**, not a runbook. Each entry below has a
canonical "how to create + grant + rotate" runbook elsewhere — link in
the "Documented in" column. If you're standing up the lab from scratch,
work through the bring-up docs in
[`docs/0-scratch-build-order.md`](0-scratch-build-order.md); they walk
through these credentials in the order they're needed.

---

## Master KeePassXC database

| Property | Value |
| --- | --- |
| Path | Operator-side (workstation only — never committed) |
| Unlock | Master password **+ YubiKey HMAC slot 2** (per the `user-keepassxc-yubikey` memory) |
| CLI access | `keepassxc-cli` honors `--yubikey 2`. `scripts/hydrate.sh` reads `KEEPASSXC_YUBIKEY` env var and forwards it. |
| Direct invocation | `KEEPASSXC_YUBIKEY=2 keepassxc-cli show -a Password <db> <entry-path>` |

---

## All entries the IaC reads

Each row is a KeePassXC entry the repo's tools (or operator ceremony
scripts) pull at run time. Group path is the parent folder in KP; entry
title is the leaf; field is which KP field carries the secret.

| Group | Entry | Field | Holds | Consumed by | Documented in |
| --- | --- | --- | --- | --- | --- |
| `Homelab/Tofu/` | `proxmox-api-token` | Password | `tofu@pve!apply=<secret>` (full string) | `scripts/hydrate.sh` → every role's `terraform.tfvars` | [docs/proxmox-tofu-permissions.md](proxmox-tofu-permissions.md), [docs/opentofu-setup.md](opentofu-setup.md) |
| `Homelab/Tofu/` | `workstation-ssh-pubkey` | **Notes** | single-line ed25519 public key | every role's cloud-init via tfvars | [docs/opentofu-setup.md](opentofu-setup.md) |
| `Homelab/PBS/` | `pveingress-cluster` | Password | PBS UI password for `pveingress@pbs` (kept for completeness; not read at runtime) | — (manual operator-side artifact) | [pbs-hosts/README.md](../pbs-hosts/README.md) |
| `Homelab/PBS/` | `pveingress-cluster` | **Notes** | `pveingress@pbs!cluster=<secret>` (full string) | future PVE-side `pvesm add pbs` play; manual paste during cluster bring-up | [pbs-hosts/README.md](../pbs-hosts/README.md), [docs/0-scratch-build-order.md](0-scratch-build-order.md) |
| `Homelab/Prometheus/` | `proxmox-api-token` | Password | `prometheus@pve!exporter=<secret>` (full string) | operator paste into `/etc/prometheus/pve.yml` on monitoring VM | [docs/proxmox-prometheus-permissions.md](proxmox-prometheus-permissions.md) Part 1 |
| `Homelab/Prometheus/` | `pbs-api-token` | Password | `prometheus@pbs!exporter:<secret>` (full string; **`:` separator**, not `=`) | operator paste into `/etc/prometheus/pbs-exporter.env` on monitoring VM | [docs/proxmox-prometheus-permissions.md](proxmox-prometheus-permissions.md) Part 2 |
| `Homelab/OpenBao/` | `unseal-1` through `unseal-5` | Password | individual Shamir shares (3 of 5 in KP, 2 of 5 on paper) | operator unseal ceremony after every restart | [vms/openbao/README.md](../vms/openbao/README.md) |
| `Homelab/OpenBao/` | `initial-root` | Password | initial root token (one-time; revoke after first admin policy lands) | OpenBao first-init ceremony | [vms/openbao/README.md](../vms/openbao/README.md) |
| `Homelab/OpenBao/` | `share-fingerprints` | **Notes** | last-4 of SHA-256 per share, for quarterly DR drill | operator drill, no runtime consumer | [vms/openbao/README.md](../vms/openbao/README.md) |

### Quick sanity checks

```bash
# List everything under Homelab/ in the KP DB (set KEEPASSXC_DB to your file)
KEEPASSXC_YUBIKEY=2 keepassxc-cli ls "$KEEPASSXC_DB" Homelab -R

# Verify a specific entry exists + has the expected field
KEEPASSXC_YUBIKEY=2 keepassxc-cli show -a Password "$KEEPASSXC_DB" Homelab/Tofu/proxmox-api-token | head -1
KEEPASSXC_YUBIKEY=2 keepassxc-cli show -a Notes    "$KEEPASSXC_DB" Homelab/PBS/pveingress-cluster | head -1
```

### Separator gotcha

Two patterns coexist for token strings, and getting them confused is a
common cause of `401 Unauthorized`:

| Service | Separator | Header form |
| --- | --- | --- |
| PVE API tokens | `=` | `PVEAPIToken=user@realm!tokenid=<secret>` |
| PBS API tokens | `:` | `PBSAPIToken=user@realm!tokenid:<secret>` |

KP entries store the **full string** including the separator (e.g.
`prometheus@pve!exporter=<secret>` in `Password` for PVE,
`prometheus@pbs!exporter:<secret>` in `Password` for PBS). When you
hand-paste into the monitoring VM's exporter configs:

- PVE side (`/etc/prometheus/pve.yml`): `token_value:` field gets just
  the `<secret>` portion (the user + token-name are separate YAML keys).
- PBS side (`/etc/prometheus/pbs-exporter.env`): `PBS_API_TOKEN=` gets
  just the `<secret>` portion (the user + token-name are separate env
  vars).

In both cases, the file fields stitch the auth header back together at
runtime with the right separator.

---

## What's NOT in KeePassXC

Surfaced so you don't go looking for them in KP:

- **Packer's `packer@pve!builder` token.** Packer reads from
  `.env.<target>` files (`.env.pve12` / `.env.pve13` on the Mac;
  `.env.t480-vbox` on the T480) at build time. The token sits in those
  files as `PROXMOX_TOKEN=...`; the files are gitignored.
  See [docs/proxmox-permissions.md](proxmox-permissions.md).
- **VM-internal application secrets** (OpenBao's auto-generated
  encryption keys, claw machine application credentials, etc.). Those
  live inside the VM, generated server-side, never round-trip through
  the workstation.
- **Per-host root passwords** for PVE / PBS hosts. Set manually during
  initial install; not consumed by any IaC.

---

## Adding a new entry

When a new role introduces a new credential the IaC needs to read:

1. Pick a group consistent with the consumer pattern:
   - `Homelab/Tofu/` — provisioning-time secrets read by `hydrate.sh`
   - `Homelab/<service>/` — runtime secrets the operator pastes
     post-Ansible (one group per service: `OpenBao`, `Prometheus`, `PBS`)
   - New top-level group only when no existing one fits
2. Document the entry in the role's README's "Prerequisites" section
   with the canonical `Homelab/<group>/<entry>` path and which field
   carries the secret.
3. Add a row to the table above, with a link back to the role's
   permissions doc.

Don't put runtime application secrets in KP. KP is for **IaC-readable
secrets** — things `hydrate.sh` consumes or things the operator pastes
into a running system once. Long-lived service credentials (e.g.
OpenBao's encryption key) belong inside their service, not in KP.
