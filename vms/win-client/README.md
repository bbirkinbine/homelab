# vms/win-client

Clones the [Windows 11 base template](../../packer/windows-11-base/) into a
usable Windows host and auto-injects a named local admin on first boot via
cloud-init (`cloudbase-init`). The result is a Windows VM you can RDP into with
a password you control from your password manager — no manual OOBE, no baked-in
credentials.

The Windows-specific hardware (q35/OVMF/TPM, SATA disk, configdrive2 JSON
meta-data, ide3 cloud-init) lives in the shared
[`modules/proxmox-vm-windows/`](../../modules/proxmox-vm-windows/) module — the
Windows counterpart to `modules/proxmox-vm/`. This role just wires identity,
sizing, storage, and the account-provisioning user-data into it.

## Layout

```text
terraform/                  OpenTofu: calls modules/proxmox-vm-windows
  main.tf                   provider + per-node template map + the module block
  variables.tf              node, sizing, storage, the admin username/password
  outputs.tf                vm_id / name / ipv4_addresses (re-exported)
  terraform.tfvars.tpl      kp:// placeholders → hydrate.sh → terraform.tfvars
  terraform.tfvars.example  manual (non-KeePassXC) copy-and-fill template
cloud-init/
  user-data.ps1.tftpl       #ps1_sysnative PowerShell run on first boot:
                            creates the admin, adds to Administrators, enables RDP
```

## Prerequisites

1. **The Windows base template must be built on the target node.** Templates are
   per-node (VMIDs cluster-wide unique, [ADR-0006](../../docs/decisions/0006-packer-templates-per-node.md)):
   Windows uses `9200`/`9201`/`9202`/`9203` for `pve12t`/`pve13m`/`pve13t`/`pve12t2`.
   Build it from the Mac (the `proxmox-iso` builder runs there):

   ```bash
   cd packer/windows-11-base
   cp .env.pve.example .env.<node>     # set PROXMOX_NODE=<node>, VM_ID=<92xx>
   ./build-pve.sh <node>               # ~15 min (Windows updates disabled by default)
   ```

   The build needs the Win11 ISO and the virtio-win ISO in **that node's** local
   ISO library (ISO storage is per-node, not shared).

2. **KeePassXC entries** — see [Credentials](#credentials-keepassxc) below.

3. **ssh-agent key trusted by the target node.** bpg uploads the cloud-init
   snippets over SSH, so your workstation's key must be in
   `root@<node>:~/.ssh/authorized_keys`. `scripts/preflight.sh` checks this.

4. **Proxmox API token** in KeePassXC at `Homelab/Tofu/proxmox-api-token`
   (shared across all roles).

## Credentials (KeePassXC)

win-client pulls two secrets at hydrate time. Both read the entry's **Password**
field (the `kp://` refs carry no `#field`, so they default to `Password`):

| KeePassXC entry (group / title)  | Used for          | Status                  |
| -------------------------------- | ----------------- | ----------------------- |
| `Homelab/Tofu/proxmox-api-token` | Proxmox API token | shared — already exists |
| `Homelab/Tofu/win-client-labadmin` | the VM admin pw   | **you create this**     |

Create `win-client-labadmin`:

1. KeePassXC → group **`Homelab/Tofu`** → New Entry → title exactly
   **`win-client-labadmin`**.
2. Generate the password (dice icon): **length 20**, and in the generator's
   *exclude characters* field put **`"\{}`**. Those characters break the value
   when it is written into the HCL `terraform.tfvars` (`"` and `\` are HCL
   string syntax; `${` and `%{` are HCL interpolation/directives). Every other
   symbol is safe — the Windows side receives the password base64-encoded.
3. The password must **not contain `labadmin`** (Windows rejects passwords
   containing the account name) and should meet complexity (≥12 chars, 3 of 4
   of upper/lower/digit/special — length 20 covers it).
4. Store it in the **Password** field. Leave Username blank: the Windows account
   name is set in `terraform.tfvars` (`win_admin_username`), not pulled from the
   vault. **Only the password comes from KeePassXC.**

Running more than one Windows host later: give each its own entry and point that
host's `terraform.tfvars.tpl` `kp://` ref at it — don't share one password.

## Deploy

Steps 1–2 run from the **repo root** (where the `Justfile` and `scripts/` live);
step 3 runs from **`vms/win-client/terraform/`**. Each block below is labelled.

```bash
# ===== from the REPO ROOT =====================================================

# 1. Hydrate kp:// → terraform.tfvars (gitignored, 0600). MUST use --force if
#    terraform.tfvars already exists (hydrate is a no-op otherwise). DB is on
#    YubiKey slot 2.
KEEPASSXC_YUBIKEY=2 just hydrate win-client --force

# 2. Preflight. preflight defaults to the UBUNTU template id for the node, so
#    override it to verify the WINDOWS template exists (e.g. 9203 on pve12t2):
TEMPLATE_VM_ID=9203 ./scripts/preflight.sh win-client

# ===== from vms/win-client/terraform/ ========================================
cd vms/win-client/terraform

# 3. Plan, read it (expect "3 to add, 0 to destroy"; check the efi_disk /
#    tpm_state / single ide3 cloud-init drive), then apply. Never -auto-approve.
tofu init -upgrade && tofu plan
tofu apply
```

> `just` recipes always run from the repo root regardless of your current
> directory (that's where the `Justfile` is); `tofu` acts on the workspace in
> the current directory, so it must be run from `vms/win-client/terraform/`.

First boot takes a few minutes: the clone boots, `cloudbase-init` sets the
hostname (which **reboots Windows once**), then runs the user-data that creates
the admin. `tofu apply` returns as soon as the guest agent reports an IP, which
is often *before* that reboot finishes — give it ~2–3 minutes to settle.

### Changing cloud-init after first boot needs a rebuild

`cloudbase-init` runs **once per instance-id**, and `meta_data_file_id` is
`ForceNew`/`ignore_changes`. So editing the password or user-data and re-running
`tofu apply` will **not** re-provision an existing VM. To apply cloud-init
changes, recreate it (from `vms/win-client/terraform/`):

```bash
tofu destroy && tofu apply
```

## Verify

Log in on the Proxmox **console** (or RDP to the VM's IP) as the admin user with
the KeePassXC password. To check from the Proxmox host without logging in (uses
the guest agent):

```bash
ssh root@<node> "qm guest exec <vmid> -- powershell -NoProfile -Command \
  \"hostname; Get-Content C:\Windows\Setup\Scripts\win-client-userdata.log; \
    net localgroup Administrators\""
```

Expect: `hostname` = the VM name, the log showing "admin … ensured in
Administrators" / "done", and the admin user listed under Administrators.

## Account model and recovery

- **Named admin** (`labadmin` by default) created by the user-data script, in the
  Administrators group, with the password from KeePassXC.
- **Built-in Administrator stays disabled.** The base template's first-boot
  `packer-cleanup` task rotates its password to a random throwaway and disables
  it — after waiting for `cloudbase-init` to finish, so the named admin always
  exists first. Do not rely on Administrator.
- **Locked out?** (e.g. cloud-init failed to run) Recover from the Proxmox host
  via the qemu-guest-agent, which runs independently of cloud-init:

  ```bash
  ssh root@<node> "qm guest exec <vmid> --timeout 60 -- powershell -NoProfile -Command \
    \"New-LocalUser -Name rescue -Password (ConvertTo-SecureString 'ChangeMe!23' -AsPlainText -Force) -PasswordNeverExpires; \
      Add-LocalGroupMember -Group Administrators -Member rescue\""
  ```

  Then log in as `rescue`. If the guest agent is also down, recover offline via
  the console (WinPE / utilman.exe) or just `tofu destroy && tofu apply`.

## Gotchas

These are Windows-specific and bit during bring-up — they are why this role
exists separately from the Linux roles:

- **Cloud-init meta-data must be JSON, not YAML.** Proxmox defaults Windows
  guests (`ostype win*`) to `citype=configdrive2`, which presents the cloud-init
  drive as an OpenStack ConfigDrive. `cloudbase-init` does `json.loads()` on
  `meta_data.json`; a NoCloud YAML meta-data file crashes it with
  `JSONDecodeError` **before any plugin runs** — no hostname, no user-data, no
  account. The Linux roles can stay YAML because Linux guests default to
  `citype=nocloud`.
- **The cloud-init drive must match the template's slot (`ide3`).** Declaring a
  different interface leaves the inherited drive in place and creates a second
  one, which `cloudbase-init` may read instead of ours.
- **Account creation uses `#ps1_sysnative` PowerShell user-data**, not a
  cloud-config `users:` list. Both are supported by cloudbase-init, but the
  PowerShell path is version-stable and self-logging.
- **`just hydrate` no-ops if `terraform.tfvars` already exists** — use `--force`.
- **Password may not contain `"` `\` `${` `%{`** (HCL tfvars constraints) — see
  [Credentials](#credentials-keepassxc).
- **Disk grows but the partition doesn't.** `disk_size_gb` (default 64) is larger
  than the template's 60 GB; Windows sees the extra space as unallocated. Extend
  the C: partition in-guest if you need it.

## Storage

Defaults to **`local-lvm`** (disk/EFI/TPM) + **`local`** (snippets) to match the
template, so the clone is a same-storage operation — fast, and it keeps EFI/TPM
off NFS. For a cluster-mobile host that can live-migrate, set `disk_storage` and
`snippets_storage` to `nas-vms` (verify NFS handles the EFI/TPM disks first;
not yet exercised).

## Config management and monitoring (not wired)

Two deliberate gaps, each to be filled when there's a real consumer rather than
as empty scaffolding:

- **No Ansible role.** This role is provisioning + first-boot identity only.
  Add `ansible/` (over WinRM/SSH) when post-boot config is needed — domain join,
  software, hardening beyond the template baseline.
- **No monitoring scrape target.** The lab's monitoring uses `node_exporter`
  (Linux); Windows needs **`windows_exporter`** (port 9182), which is not yet
  installed by the template or this role, and the Linux
  `install-node-exporter-guests.yml` playbook does not apply. Wiring Windows
  telemetry means: add a windows_exporter install step (template or user-data),
  a Windows scrape job in `vms/monitoring/`, and a Windows dashboard.

## Sizing

| Knob           | Default | Notes                                   |
| -------------- | ------- | --------------------------------------- |
| `cores`        | 4       | Win11 desktop is comfortable here       |
| `memory_mb`    | 8192    | 8 GiB to feel usable; 4 GiB hard floor  |
| `disk_size_gb` | 64      | template is 60; extra is unallocated    |
| `cpu_type`     | x86-64-v3 | cluster baseline ([CLAUDE.md](../../CLAUDE.md)) |

No ballooning (memory pinned) — one fewer variable while the clone path is young.

## Ports

The base template ships with these reachable (firewall default-deny inbound,
these allowed): **RDP 3389**, **OpenSSH 22**, **WinRM 5985**. The user-data
re-asserts RDP on first boot.

## Creating another Windows host

Windows hosts are pets here — one role dir per VM, same as the Linux roles.
There is no `_win-template` yet (one Windows role doesn't justify extracting a
skeleton); **copy this role** — it is the canonical Windows starting point.
To stand up e.g. `win-dev`, from the repo root:

```bash
cp -r vms/win-client vms/win-dev
cd vms/win-dev

# 1. Drop the copied LOCAL state + secrets — they belong to win-client's VM,
#    NOT the new one. (gitignored, so the cp dragged them along.)
rm -rf terraform/.terraform terraform/terraform.tfstate* terraform/terraform.tfvars

# 2. Rename win-client -> win-dev across the copy. Two forms: the hyphenated
#    name (win-client) and the HCL module label (win_client).
git ls-files -o --exclude-standard | xargs \
  sed -i '' -e 's/win-client/win-dev/g' -e 's/win_client/win_dev/g'   # macOS
#   (Linux: sed -i -e 's/win-client/win-dev/g' -e 's/win_client/win_dev/g')

# 3. Pick a unique VMID (workload range 100-399 per ADR-0008; confirm it's free
#    cluster-wide with `qm list`) and edit `vm_id = 310` in terraform/main.tf.

# 4. Register the new role as a workload in scripts/check-role-consistency.sh
#    role_class() — add it next to win-client.

# 5. Rewrite this README's opening + purpose for the new host.
```

Then create its KeePassXC entry `Homelab/Tofu/win-dev-labadmin` (the **Password**
field — see [Credentials](#credentials-keepassxc)) and deploy exactly as above:
`just hydrate win-dev --force` → preflight (`TEMPLATE_VM_ID=<92xx>`) → plan →
apply. Confirm the copy is still canonical with `just check-roles`.

> When a genuinely different second Windows *type* appears (e.g. a `win-server`
> for general use), extract the real commonality between it and win-client into
> a `_win-template/` then — built from two examples, not guessed from one.

## Related

- [modules/proxmox-vm-windows/](../../modules/proxmox-vm-windows/) — the Windows VM module this role calls
- [packer/windows-11-base/README.md](../../packer/windows-11-base/README.md) — building the base template
- [docs/cloning-templates.md](../../docs/cloning-templates.md) — clone + per-clone identity model (both bases)
- [docs/decisions/0006-packer-templates-per-node.md](../../docs/decisions/0006-packer-templates-per-node.md) — per-node template VMIDs
