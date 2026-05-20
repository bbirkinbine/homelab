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

> **STOP — this role is not all-`just`.** Unlike openclaw / nemoclaw /
> amp-game, the operator installs the OpenBao binary **by hand**
> between Phase 1 and Phase 3 below. `just ansible openbao` will
> refuse to run against a VM with no `bao` on disk — there is a
> pre-flight assert in the role that fails loud with a pointer back
> to Phase 2. The manual install is intentional: OpenBao is a trust
> anchor, and the .deb fetch + GPG verification stays under the
> operator's direct control (same custody discipline as the Shamir
> shares downstream). OpenBao also doesn't publish an apt repo
> (`apt.openbao.org` is NXDOMAIN), so the practical install path is
> a pinned .deb from GitHub releases either way.

**Fresh deploy vs. existing instance — storage decision.** The committed
`terraform.tfvars.tpl` carries a two-line pre-flip pin
(`disk_storage = "local-lvm"` and `snippets_storage = "local"`) that
keeps the original openbao instance bit-identical across `tofu apply`.
If you're standing this role up **for the first time** (e.g. DR rebuild,
new lab), drop those two pin lines from
`vms/openbao/terraform/terraform.tfvars.tpl` BEFORE running `just hydrate`
so the fresh VM lands on `nas-vms` (cluster-shared NFS, the role default
for cluster-mobility). If you're operating an existing instance, leave the
pin alone — see [Storage migration](#storage-migration-local-lvm--nas-vms)
for the in-place move path.

### Phase 1 — provision the VM (workstation)

```bash
just ansible-deps openbao   # one-time per workstation
just hydrate openbao        # render terraform.tfvars from KeePassXC
just plan openbao           # review the plan
just apply openbao          # create the VM
just inventory openbao      # write ansible/inventory.yml from tofu output (waits on guest-agent)
```

### Phase 2 — install OpenBao on the VM (manual, GPG-verified)

Pick a release from
[`github.com/openbao/openbao/releases`](https://github.com/openbao/openbao/releases)
(2.5.3 or later — the role asserts `>= 2.5`). Get the VM's IP from
`just output openbao` or by reading `vms/openbao/ansible/inventory.yml`.
Then, on the VM:

```bash
ssh bao-admin@<vm-ip>
VER=2.5.3                                                       # bump as needed
cd /tmp

# Fetch the .deb, the checksums file, its detached GPG signature,
# and the OpenBao signing key.
curl -fsSLO https://github.com/openbao/openbao/releases/download/v${VER}/openbao_${VER}_linux_amd64.deb
curl -fsSLO https://github.com/openbao/openbao/releases/download/v${VER}/checksums-linux.txt
curl -fsSLO https://github.com/openbao/openbao/releases/download/v${VER}/checksums-linux.txt.gpgsig
curl -fsSLO https://openbao.org/assets/openbao-gpg-pub-20240618.asc

# Verify the GPG signature on the checksums file.
gpg --import openbao-gpg-pub-20240618.asc
gpg --verify checksums-linux.txt.gpgsig checksums-linux.txt
# Expect: Good signature from "OpenBao <openbao@lists.lfedge.org>"
# Primary key fingerprint: 66D1 5FDD 8728 7219 C8E1  5478 D200 CD70 2853 E6D0

# Verify the .deb's SHA256 against the now-trusted checksums file.
grep "openbao_${VER}_linux_amd64.deb" checksums-linux.txt | sha256sum -c -
# Expect: openbao_X.Y.Z_linux_amd64.deb: OK

# Install. The postinst creates the openbao user/group and lays
# down /usr/lib/systemd/system/openbao.service.
sudo dpkg -i openbao_${VER}_linux_amd64.deb
bao --version
exit
```

Upgrade path: when bumping versions later, re-run Phase 2 on the VM
with a newer `VER`. The role's `>= 2.5` assert catches an accidental
downgrade.

### Phase 3 — configure with Ansible (workstation)

```bash
just ansible-check openbao  # optional dry-run with --diff
just ansible openbao        # configure OpenBao + bring the service up
```

End state: openbao service is **running but sealed** — `bao status`
returns `Initialized: false; Sealed: true`. The role deliberately does
NOT run `bao operator init`; that's the operator's ceremony, below.

## First-init ceremony (operator-driven, one-time)

Per [[OpenBao Homelab Setup]] Phase 3 (in the vault). The init command's
output is the only time the unseal shares are visible — stage every
custody destination *before* running it.

### Stage custody destinations (do this first)

**KeePassXC (workstation).** Unlock the homelab DB and pre-create five
empty entries under group `Homelab/OpenBao/`:

| Entry title | Secret field | What it will hold |
| --- | --- | --- |
| `unseal-1` | password | Shamir share 1 (full string from init output) |
| `unseal-2` | password | Shamir share 2 |
| `unseal-3` | password | Shamir share 3 |
| `initial-root` | password | initial root token — revoke after admin policy lands |
| `share-fingerprints` | notes | last-4 of SHA-256 for each of the 5 shares (non-secret; for DR-drill verification without retyping the share) |

**Paper cards (shares 4 and 5).** Have ready: two standard letter-size
sheets, two envelopes that can be sealed and signed across the flap,
and a pen. Letter-size on purpose — a card-sized share is easy to
misplace in a drawer or mistake for a receipt; an 8.5×11 sheet folded
into a labelled envelope is not.

**Session hygiene.** The init output prints all 5 shares + the root
token in plaintext. Before running it, confirm no terminal logger is
active (no `script(1)` session, no tmux `pipe-pane`, no IDE remote
terminal that persists scrollback to disk). After distribution, run
`history -c` and close the SSH session.

### Run init

Run from the VM:

```bash
ssh bao-admin@<vm-ip>
export BAO_ADDR=http://127.0.0.1:8200

# 5 shares total, any 3 unseal. Output is the only time these values
# are visible — capture immediately into the destinations staged above.
bao operator init -key-shares=5 -key-threshold=3
```

3-of-5 means you can lose any 2 shares and still recover. The
home/offsite paper split keeps any single physical loss event from
taking 3.

### Distribute the output

Paste each item into its staged destination:

| Item | Where |
| --- | --- |
| Unseal Share 1 | KeePassXC entry `Homelab/OpenBao/unseal-1` (password field) |
| Unseal Share 2 | KeePassXC entry `Homelab/OpenBao/unseal-2` |
| Unseal Share 3 | KeePassXC entry `Homelab/OpenBao/unseal-3` |
| Unseal Share 4 | Paper card, sealed envelope, fire safe (home) |
| Unseal Share 5 | Paper card, sealed envelope, offsite (in-laws') |
| Initial Root Token | KeePassXC entry `Homelab/OpenBao/initial-root` — **revoke after first admin policy** |
| Share fingerprints | KeePassXC entry `Homelab/OpenBao/share-fingerprints` (notes field) — see fingerprint step below |

**Paper card template.** Fill in one sheet per share before sealing:

```text
OpenBao Shamir Share — Homelab
==============================
Share index:        __ of 5
Threshold:          3 of 5 shares unseal

Share string:
  _________________________________________________________________
  _________________________________________________________________

Last 4 of SHA-256:  ____
Generated:          YYYY-MM-DD
VM:                 openbao (homelab)

To unseal: ssh bao-admin@<vm-ip>, then run `bao operator unseal` and
paste this share when prompted. Repeat with two other shares to
fully unseal.
```

Sign and date across the envelope flap so any later tampering is
visible.

**Compute fingerprints.** For each share, last-4 of its SHA-256:

```bash
# In the same terminal that has the init output, for each share string:
printf '%s' '<share-string>' | sha256sum | cut -c1-4
```

Record the five values in the `share-fingerprints` entry's notes:

```text
share-1: ab12
share-2: cd34
share-3: ef56
share-4: 7890
share-5: 1a2b
```

These let the quarterly DR drill confirm a paper card survived legibly
by recomputing the fingerprint of what's written and matching it
against the recorded value — without anyone having to type the full
share back into a shell.

### Unseal

```bash
bao operator unseal   # paste share 1
bao operator unseal   # paste share 2
bao operator unseal   # paste share 3 — unsealed
bao status            # Initialized: true; Sealed: false
```

### Audit log

The file audit device is wired **declaratively** in
`/etc/openbao/openbao.hcl` (rendered from the role's
`templates/openbao.hcl.j2` — search for the `audit "file"` stanza).
OpenBao removed the runtime `bao audit enable` API pre-v2.5; that
command now returns HTTP 400 unless the unsafe API flag is set,
which we deliberately leave off.

On a freshly-deployed instance, audit is active from first start —
no operator step required. After init + unseal, confirm:

```bash
bao login <root-token>
bao read sys/audit                 # 'file/' (matches the stanza label "audit-log" → audit-log/)
sudo ls -la /var/log/openbao/audit.log
sudo tail /var/log/openbao/audit.log
```

To change the audit destination, edit `openbao_audit_log_path` in
the role's defaults (or set per-host in inventory) and re-run
`just ansible openbao`. The template change triggers a service
restart via the handler, which means a re-seal — keep 3 shares
within reach.

Then proceed to Phase 3 of [[13 Homelab Blueprint]] (PKI Intermediate,
Transit, etc.).

## Operations

### After every restart — manual unseal (on the VM)

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

### Stable IP via DHCP reservation (on the LAN router)

`just output openbao` reports the MAC of the VM's NIC. Pin a DHCP
reservation on the router so the IP doesn't rotate — Ansible's
inventory and the OpenBao API URL both reference the IP, and
re-pasting after every lease change is friction.

### Raft snapshots (setup on the VM)

Cron'd inside the VM. The role doesn't lay this down (it would need
a non-root token with `sys/storage/raft/snapshot` capability, which
requires the operator-driven init to have completed). Once you've
done the ceremony, install the snapshot job in three steps.

**1. Stage the credentials.** Create a token with snapshot capability,
then write it where cron's `openbao` user can read it (and only it):

```bash
bao policy write snapshot - <<'POLICY'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
POLICY
SNAP_TOKEN=$(bao token create -policy=snapshot -period=720h -display-name=snapshot-cron -field=token)
sudo install -d -m 700 -o openbao -g openbao /var/lib/openbao
echo "$SNAP_TOKEN" | sudo tee /var/lib/openbao/.bao-token >/dev/null
sudo chown openbao:openbao /var/lib/openbao/.bao-token
sudo chmod 600 /var/lib/openbao/.bao-token
```

**2. Prepare the backup directory.**

```bash
sudo install -d -m 700 -o openbao -g openbao /backups
```

**3. Install the cron entry.** Run this heredoc as-is — it writes the
file `/etc/cron.d/openbao-snapshot` with a single cron record. The
record's command line wraps visually in your renderer, but on disk
it's one physical line (cron's `/etc/cron.d/` format does not honor
`\` line continuation):

```bash
sudo tee /etc/cron.d/openbao-snapshot >/dev/null <<'EOF'
0 3 * * * openbao BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN_FILE=/var/lib/openbao/.bao-token /usr/bin/bao operator raft snapshot save /backups/openbao-$(date +\%F).snap 2>&1 | logger -t openbao-snapshot
EOF
```

> **Don't paste the cron line on its own into a shell.** It's a cron
> *record format*, not a shell command — bash would see the first
> word `0` and try to execute it as a program. The line only works
> inside `/etc/cron.d/`, parsed by cron. Use the heredoc above.

For editing or troubleshooting, here's the record broken down field
by field:

| Field | Value | Notes |
| --- | --- | --- |
| Schedule | `0 3 * * *` | 03:00 daily |
| User | `openbao` | cron runs the command as this user (NOT root) |
| Env | `BAO_ADDR=http://127.0.0.1:8200` | Listener URL (matches the role's `openbao_api_addr`) |
| Env | `BAO_TOKEN_FILE=/var/lib/openbao/.bao-token` | Path containing the snapshot-policy token from step 1 |
| Command | `/usr/bin/bao operator raft snapshot save /backups/openbao-$(date +\%F).snap` | `\%F` is cron-escaped `%F` (`YYYY-MM-DD`) — cron strips bare `%` |
| Logging | `2>&1 \| logger -t openbao-snapshot` | Routes stdout + stderr to syslog under tag `openbao-snapshot` |

**Verify the run.** Wait for the first 03:00, then:

```bash
ls -la /backups/                                  # expect openbao-YYYY-MM-DD.snap
sudo journalctl -t openbao-snapshot --since today # expect a single success line
```

Push snapshots offsite weekly via your preferred backup path.

### Re-run a single Ansible task (from the workstation)

From the repo root on the workstation:

```bash
cd vms/openbao/ansible
ansible-playbook -i inventory.yml site.yml --tags <tag>   # if you've added tags
# or, run the whole playbook idempotently:
just ansible-check openbao   # --check --diff (no changes)
just ansible openbao
```

### Storage migration (local-lvm → nas-vms)

This VM was created on per-node `local-lvm` before `nas-vms` (Asustor
NFS, cluster-shared per ADR-0004) became the role default. The
committed `terraform.tfvars.tpl` carries a pre-flip pin
(`disk_storage = "local-lvm"` + `snippets_storage = "local"`) so
`just apply openbao` stays a no-op for storage.

Two paths to move the disk to nas-vms:

**A. In-place move via Proxmox (preserves the VM, no recreate).**
Recommended for an initialized OpenBao — keeps raft state intact
without a snapshot/restore loop.

```bash
ssh root@pve12t 'qm move-disk 8030 scsi0 nas-vms --delete 1'
ssh root@pve12t 'qm move-disk 8030 ide2 nas-vms --delete 1'   # cloud-init drive
```

Then remove the pin from `vms/openbao/terraform/terraform.tfvars.tpl`,
re-run `just hydrate openbao`, and `just plan openbao`. Plan should
report no changes (or only attribute drift like `datastore_id`
reconciliation) — if it wants to destroy and recreate the disk,
abort and verify the move first.

**B. Destructive recreate via tofu (loses raft state).** Drop the pin
lines, re-hydrate, `just apply openbao` — the boot disk is destroyed
and recreated on nas-vms. Then re-run `just ansible openbao` and the
DR-drill snapshot-restore flow in **Destroy and rebuild** below to
get OpenBao back to a known state.

The snippet move is non-destructive in either case — the snippet is
regenerated by `tofu apply` and the bpg/proxmox provider uploads it
fresh on every run.

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
| RAM | 2 GiB | Comfortable for the secrets engine + audit log + UI |
| Disk | 32 GiB | Mostly for /var/log + audit-log retention |
| Balloon | 0 | Predictable memory for a trust anchor (no surprise pressure on the secrets engine); was historically required by mlock, kept after OpenBao moved to cgroup MemorySwapMax=0 |
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
