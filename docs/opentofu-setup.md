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
create the `tofu@pve` user + `apply` token once on any cluster node
(pmxcfs replicates `/etc/pve/user.cfg` to all three). Store the token
in KeePassXC as `Homelab/Tofu/proxmox-api-token` (Password field).

### 2. SSH access to Proxmox nodes

`bpg/proxmox` uploads cloud-init snippets over SSH (not the HTTP API),
so the workstation needs a working `root@<node>` SSH login. Use a
**dedicated homelab key** for this — don't reuse your GitHub /
upstream / work key. Cleaner blast radius, simpler rotation, and an
explicit `~/.ssh/config` entry means `tofu` won't accidentally try
half a dozen other keys against PVE and trip `MaxAuthTries`.

**(a) Create the homelab key** (one-time, skip if you already have one):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_homelab -C "homelab tofu"
```

**(b) Put its pubkey in `root@<node>:~/.ssh/authorized_keys`** on each
node you'll target. Use `-i` so only the homelab key is copied (the
default copies *every* key in your agent):

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_homelab.pub root@pve12t
ssh-copy-id -i ~/.ssh/id_ed25519_homelab.pub root@pve13m
ssh-copy-id -i ~/.ssh/id_ed25519_homelab.pub root@pve13t
```

**(c) Tell SSH to use only that key for PVE hosts.** Add to
`~/.ssh/config`:

```sshconfig
Host pve12t pve13m pve13t
  User root
  IdentityFile ~/.ssh/id_ed25519_homelab
  IdentitiesOnly yes
```

`IdentitiesOnly yes` is load-bearing: without it, SSH offers every key
in the agent in sequence, and PVE's default `MaxAuthTries 6` will
disconnect you before the right key is tried if you have many keys
loaded. With it, only `id_ed25519_homelab` is offered for these hosts.

**(d) Load the private key into `ssh-agent`** on the workstation.
`bpg/proxmox` shells out non-interactively, so it can't prompt for a
passphrase mid-apply — the key has to be in the agent already. Once
per shell session (or once per reboot):

```bash
ssh-add ~/.ssh/id_ed25519_homelab
ssh-add -l                          # verify; should list the homelab key
```

On macOS, persist the passphrase into the login keychain so you don't
have to redo (d) after every reboot:

```bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_homelab
```

And add to the `Host pve...` block in `~/.ssh/config` (or as a global
`Host *` if you want it everywhere):

```sshconfig
  UseKeychain yes
  AddKeysToAgent yes
```

The agent then auto-loads the key on subsequent logins.

**Verify it all hangs together:**

```bash
ssh root@pve12t 'hostname'          # should print "pve12t" with no prompt
```

`scripts/preflight.sh` verifies (b) and (d) — it greps `ssh-add -l`
for at least one key, then opens an `ssh -o BatchMode=yes` to the
node. A missing key fails the preflight cheaply rather than deep
inside `tofu apply`.

`scripts/preflight.sh` verifies both (a) and (b) — it greps `ssh-add
-l` for at least one key, then opens an `ssh -o BatchMode=yes` to the
node. A missing key fails the preflight cheaply rather than deep
inside `tofu apply`.

### 3. KeePassXC + hydrate

Set the path to your homelab `.kdbx` in your shell profile:

```bash
# ~/.zshrc
export KEEPASSXC_DB="$HOME/Documents/KeePassXC/homelab.kdbx"
# If your DB also requires a key file:
# export KEEPASSXC_KEYFILE="$HOME/.config/keepassxc/homelab.key"
# If your DB is locked with a YubiKey HMAC-SHA1 challenge-response,
# set the slot here. Confirm the slot with:
#   keepassxc-cli ls --yubikey 2 "$KEEPASSXC_DB" /
# (try slot 1 if 2 errors with "HMAC mismatch"). hydrate prompts the
# key for a touch once per kp:// placeholder it resolves — watch for
# the YubiKey's status LED to start flashing before tapping; pressing
# it before the flash is a no-op. The terminal doesn't print anything
# between lookups, so the LED is the only cue.
# export KEEPASSXC_YUBIKEY=2
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

> **Prerequisite — base template must exist on the target node.** The
> commands below culminate in `just check <role>`, which runs
> `scripts/preflight.sh` and verifies the right Ubuntu template VMID
> is present on the node your role's tfvars targets. Build it first per
> [`docs/0-scratch-build-order.md` step 11](0-scratch-build-order.md)
> (`packer/ubuntu-24-04-base/build-pve.sh <node>`, once per cluster
> node you'll deploy roles to — VMIDs are per-node: `pve12t=9100`,
> `pve13m=9101`, `pve13t=9102`; see [ADR-0006](decisions/0006-packer-templates-per-node.md)).
> The Packer build itself only needs the API token from step 8; the
> workstation→PVE SSH setup in §2 above is OpenTofu-specific (bpg/proxmox
> uploads snippets over SSH) and is not a prerequisite for the Packer
> build in step 11. If you're following the scratch build order
> top-to-bottom, this section belongs to step 14, not step 10 — the
> workstation setup itself ends at the KeePassXC + hydrate section
> above.
>
> **Once the templates exist on every target node, return to this
> section and continue with the per-role workflow below** (it's the
> body of scratch-build step 14).

A **role** is a directory under `vms/` containing the OpenTofu config,
Ansible playbook, and cloud-init template for one VM purpose. Every
Justfile recipe (`hydrate`, `check`, `plan`, `apply`, `ansible`, …)
takes the role name as its argument:

```bash
just check openbao      # operates on vms/openbao/
just check rootca       # operates on vms/rootca/
```

List what's currently available:

```bash
ls vms/                 # excludes legacy/ and README
```

The full path from zero to a running, configured VM (substitute your
role name for `openbao` in every command below):

```bash
# One-time per workstation: install Galaxy collections.
just ansible-deps openbao

# Resolve KeePassXC placeholders into vms/openbao/terraform/terraform.tfvars.
just hydrate openbao

# Per session/reboot: load your homelab SSH key into the agent if it
# isn't already. (preflight fails with "ssh-agent has no keys loaded"
# otherwise.) Skip this if you set up the macOS keychain integration
# in setup step 2(d) — the agent auto-loads on login.
ssh-add -l >/dev/null 2>&1 || ssh-add ~/.ssh/id_ed25519_homelab

# Verify ssh/Proxmox/template/snippets prerequisites.
just check openbao

# Plan + apply (each implicitly runs preflight + hydrate first).
just plan openbao
just apply openbao

# Write the static Ansible inventory from tofu output. Fails if the
# qemu-guest-agent hasn't reported the VM's IP yet (wait ~30s and retry).
just inventory openbao

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
| `hydrate` reports `could not resolve kp://...` with `HMAC mismatch` in the captured keepassxc-cli output | DB is locked with a YubiKey challenge-response but `KEEPASSXC_YUBIKEY` is unset | `export KEEPASSXC_YUBIKEY=<slot>` (usually 2) and rerun. Confirm the slot with `keepassxc-cli ls --yubikey 2 "$KEEPASSXC_DB" /`. |
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
