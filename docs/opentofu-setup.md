# OpenTofu setup for the homelab repo

> **What this is.** Workstation-side setup notes for the OpenTofu +
> Ansible flow that supersedes the old `deploy.sh` shell scripts. The
> first role on this flow is `vms/openbao/`; later roles (Root CA,
> LLM, k3s) will copy the same shape.
>
> **What this is not.** A tour of OpenTofu itself. If you've used
> Terraform, the language is identical. If you haven't, the
> [OpenTofu docs](https://opentofu.org/docs/) are a one-evening read
> and worth doing before touching this repo.

---

## Install

```bash
brew install opentofu just keepassxc ansible
```

- **opentofu** — `tofu` binary; drop-in for `terraform`.
- **just** — command runner; wraps `tofu` + `ansible-playbook` per role.
- **keepassxc** — provides `keepassxc-cli` for `scripts/hydrate.sh`.
- **ansible** — `ansible-playbook` + `ansible-galaxy` for the
  configuration-management layer.

Then install the Galaxy collections each role needs:

```bash
just ansible-deps openbao
```

This currently pulls `community.general` (for `ufw`); future roles
may add more.

---

## First-time per-machine setup

### 1. Proxmox API token

Follow [`proxmox-tofu-permissions.md`](proxmox-tofu-permissions.md) to
create the `tofu@pve` user + `apply` token on every Proxmox node you
plan to provision against. Store the token in KeePassXC as
`Homelab/Tofu/proxmox-api-token` (Password field).

### 2. SSH access to Proxmox nodes

`bpg/proxmox` uploads cloud-init snippets over SSH (not the HTTP API).
Your workstation's pubkey must be in `root@<node>:~/.ssh/authorized_keys`:

```bash
ssh-copy-id root@pve12t
```

`scripts/preflight.sh` verifies this with `ssh -o BatchMode=yes` before
every apply, so a missing key fails the preflight cheaply rather than
deep inside `tofu apply`.

### 3. KeePassXC + hydrate

Set the path to your homelab `.kdbx` in your shell profile:

```bash
# ~/.zshrc
export KEEPASSXC_DB="$HOME/Documents/KeePassXC/homelab.kdbx"
# If your DB also requires a key file:
# export KEEPASSXC_KEYFILE="$HOME/.config/keepassxc/homelab.key"
```

Add an entry per secret the .tfvars.tpl references. For openbao that's
two entries:

- `Homelab/Tofu/proxmox-api-token` — full token string `tofu@pve!apply=...`.
  Password field.
- `Homelab/Tofu/workstation-ssh-pubkey` — single-line ed25519 pubkey.
  Stored in the Notes field (KeePassXC's Password field would mangle a
  long string with whitespace stripping; Notes handles it cleanly).

The .tfvars.tpl placeholder syntax for the latter is therefore
`kp://Homelab/Tofu/workstation-ssh-pubkey#Notes`.

---

## Per-role workflow

The Justfile recipes are parameterized by role name (the directory
under `vms/`). Today, that's just `openbao`. The full path from zero
to a running, configured VM:

```bash
# One-time per workstation: install Galaxy collections.
just ansible-deps openbao

# Resolve KeePassXC placeholders into vms/openbao/terraform/terraform.tfvars.
just hydrate openbao

# Verify ssh/Proxmox/template/snippets prerequisites.
just check openbao

# Plan + apply (each implicitly runs preflight + hydrate first).
just plan openbao
just apply openbao

# Paste tofu output into the static Ansible inventory.
just output openbao
$EDITOR vms/openbao/ansible/inventory.yml          # ansible_host = <ipv4>

# Run the role's playbook.
just ansible openbao
```

After this completes, `bao status` on the VM returns `Initialized:
false; Sealed: true` — the service is up but waiting on the operator
to run `bao operator init`. See `vms/openbao/README.md` for the
ceremony.

---

## State management

### Phase 1 (today): local state

Each role's `terraform.tfstate` lives in `vms/<role>/terraform/`,
gitignored. Backup is your responsibility — `cp` the file to a safe
location before destructive operations.

The state file **contains the Proxmox token** (it's in the provider
config snapshot). `chmod 600` it and never sync the directory to
iCloud / Dropbox / Drive. The `.gitignore` covers the obvious case
but won't save you from cross-folder sync.

### Phase 2 (later): MinIO on the Asustor

When a second VM lands and you want shared state + locking, promote
to the S3-compat backend described in [Homelab Repo Migration to
OpenTofu](https://example.invalid/private-vault-link) §"State backend
— phased". The recipe:

```hcl
# in vms/<role>/terraform/versions.tf
backend "s3" {
  bucket    = "tofu-state"
  key       = "vms/openbao/terraform.tfstate"
  endpoints = { s3 = "https://asustor.lan:9000" }
  use_path_style = true
  # plus skip_credentials_validation, skip_metadata_api_check,
  # skip_region_validation, skip_requesting_account_id
}
```

`tofu init -migrate-state` moves the existing local state to MinIO
without losing anything.

### Phase 3 (eventual): real S3 + DynamoDB for AWS-touching workloads

Same backend block, no skip flags, real region. Coexists with MinIO —
homelab-only state in MinIO, AWS-touching state in S3.

---

## Lockfile policy

Commit `.terraform.lock.hcl` per role. Reasons:

- The provider has had attribute renames between minor releases.
  Pinning to the same provider hash across machines avoids "works on
  my Mac, fails on CI" surprises.
- The lockfile is small (a few KB) and not sensitive.
- Public-repo convention is to commit it.

Bump the lock deliberately with `tofu init -upgrade` when you read the
release notes and decide to move forward.

---

## Per-role layout

```text
vms/<role>/
├── README.md                 role-specific docs (deployment, first-init, ops)
├── terraform/
│   ├── main.tf               provider block + module call
│   ├── variables.tf          inputs
│   ├── versions.tf           required_providers pin
│   ├── outputs.tf            useful outputs (ipv4, mac, inventory hint)
│   ├── terraform.tfvars.tpl  kp:// placeholders, committed
│   ├── terraform.tfvars.example  manual-fill alternative, committed
│   ├── terraform.tfvars      resolved values, GITIGNORED
│   ├── terraform.tfstate     local state, GITIGNORED, chmod 600
│   └── .terraform.lock.hcl   committed
├── ansible/
│   ├── site.yml              top-level play (role: <role>)
│   ├── requirements.yml      Galaxy collections
│   ├── inventory.yml.example committed
│   ├── inventory.yml         your IPs, GITIGNORED
│   └── roles/<role>/
│       ├── defaults/main.yml overridable vars
│       ├── tasks/main.yml    the actual work
│       ├── handlers/main.yml restart, reload-daemon
│       ├── templates/        Jinja2 → /etc paths
│       ├── files/            static drops (e.g. systemd overrides)
│       └── meta/main.yml     Galaxy metadata + collection deps
└── cloud-init/
    └── user-data.yaml.tftpl  identity-only; renderable by templatefile()
```

Cloud-init lives next to the role (not under `terraform/`) because it
is logically part of the role, not the IaC layer. Tofu's call-site
reads it via `${path.module}/../cloud-init/user-data.yaml.tftpl`.

---

## Common breakage

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `terraform.tfvars.tpl not found` from hydrate | role doesn't have a hydrate template | Either create `.tfvars.tpl` with kp:// placeholders, or copy `.tfvars.example` to `.tfvars` directly. |
| `ssh-agent has no keys loaded` from preflight | Forgot to `ssh-add` after reboot | `ssh-add ~/.ssh/id_ed25519` then retry. |
| `cannot reach Proxmox API` from preflight | VPN / Tailscale dropped, or DNS for the node fails | `ping` the node, restart Tailscale, check `/etc/hosts`. |
| `storage 'local' does not allow 'snippets'` | Snippets content type not enabled on the storage | Run the cure command preflight prints, OR Datacenter → Storage → local → Edit → tick Snippets. |
| `tofu apply` hangs at "Creating proxmox_virtual_environment_file" | SSH-side upload failing silently | Watch `journalctl -u sshd` on the node; usually means `~/.ssh/authorized_keys` on root is wrong. |
| `bao status` after `just ansible` fails with `connection refused` | OpenBao service didn't start | `ssh bao-admin@<ip> journalctl -u openbao -n 100`; most often a typo in the role's openbao.hcl template. |
| Provider attribute name mismatch on `tofu plan` | Provider version drifted from what the module was written against | Check the `~> 0.66` pin in `modules/proxmox-vm/versions.tf`; bump deliberately and re-test. |

---

## Related

- `docs/proxmox-tofu-permissions.md` — `tofu@pve` API token setup.
- `docs/proxmox-permissions.md` — Packer-side analog; the two
  pipelines have separate user/role/token.
- `modules/proxmox-vm/` — shared module. Read its `variables.tf` for
  the full input surface.
- `vms/openbao/README.md` — first role on this flow; canonical
  example.
- `vms/openbao/legacy/README.md` — what the previous (shell-script)
  shape looked like and why it was retired.
