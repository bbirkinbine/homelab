# win-client — SPIKE NOTES (feat/windows-host, Phase 1)

This directory is an **experiment**, not yet a canonical role. It exists to
answer a handful of unknowns about cloning the Windows 11 base template and
auto-injecting accounts, before any of it is hardened into the shared module +
the canonical `vms/<role>/` shape.

> **Operator instructions (prerequisites, KeePassXC, deploy, verify) now live in
> [README.md](README.md).** This file is the experiment log: what was unknown,
> what was learned, and the remaining Phase-2 work. The proven findings are
> resolved below; the Credentials / How-to-run / success-criteria steps that
> were here have moved to the README to keep one source of truth.

## Goal

Usable Windows hosts (not a pentest lab) that we can auto-provision accounts
into. Account model chosen up front:

- **Named admin** (`labadmin` by default) created on first boot, added to
  Administrators. Password comes from KeePassXC — type one in, or let KeePassXC
  generate it; either way it lives in your vault so you know it.
- **Built-in Administrator stays disabled.** The template's first-boot
  `packer-cleanup.ps1` rotates Administrator to a random throwaway password and
  disables it. We do not fight that — it is the secure default. The cleanup
  waits for cloudbase-init to finish, so the named admin exists before
  Administrator is locked out.
- **If cloud-init never runs**, recover from the host via `qm guest exec` — see
  "Break-glass & recovery" below. (We deliberately do NOT carry a second
  in-guest "break-glass" account: it only covered the narrow case of the
  primary account failing while the script otherwise ran, and the guest-agent
  path covers that and more without an extra secret to track.)
- **Your own users/groups** via the PowerShell user-data
  (`cloud-init/user-data.ps1.tftpl`) — the named admin is wired; an example
  block shows the pattern for more.

## Mechanism (decided, verified against upstream)

cloudbase-init upstream docs confirm BOTH a `#cloud-config` `users:` list AND
`#ps1_sysnative` PowerShell user-data are supported. We use **PowerShell
`#ps1_sysnative`** because it is the most version-stable and debuggable path:
cloudbase-init only has to execute a script (a core, long-standing feature),
versus parsing a `users:` list through its newer cloud-config user plugin. The
script writes `C:\Windows\Setup\Scripts\win-client-userdata.log`, so first-boot
behavior is observable. The cloud-config `users:` path in
[docs/cloning-templates.md](../../docs/cloning-templates.md) remains a valid
documented alternative; this spike deliberately does not use it.

## Credentials — KeePassXC setup (do this first)

win-client pulls two secrets from KeePassXC at hydrate time. Both come from the
entry's **Password** field (the `kp://` refs carry no `#field`, so they default
to `Password`):

| KeePassXC entry (group / title)   | Used for             | Status                  |
| --------------------------------- | -------------------- | ----------------------- |
| `Homelab/Tofu/proxmox-api-token`  | Proxmox API token    | shared — already exists |
| `Homelab/Tofu/win-client-labadmin`  | the VM's admin pw    | **you create this**     |

Create `win-client-labadmin`:

1. In KeePassXC, group **`Homelab/Tofu`** → New Entry → title exactly
   **`win-client-labadmin`**.
2. Generate the password (dice icon): **length 20**, and in the generator's
   *exclude characters* field put **`"\{}`** (kills the chars that break the
   HCL tfvars: `"`, `\`, and the `${`/`%{` sequences). All other character
   sets on. It must **not contain `labadmin`** (Windows rejects passwords
   containing the username), and should meet complexity (>=12 chars, 3 of 4 of
   upper/lower/digit/special — the length-20 generator covers this).
3. Put it in the **Password** field. Leave Username blank — the Windows account
   name (`labadmin`) is set literally in `terraform.tfvars`, NOT pulled from the
   vault. Only the password comes from KeePassXC.

Spinning up MORE than one Windows host later: give each its own entry and point
that host's `terraform.tfvars.tpl` `kp://` ref at it (don't share one password
across hosts).

## How to run

```bash
# 1. Resolve kp:// placeholders into terraform.tfvars (gitignored, 0600).
#    Requires the win-client-labadmin entry above. DB is YubiKey slot 2.
KEEPASSXC_YUBIKEY=2 just hydrate win-client   # or: scripts/hydrate.sh vms/win-client/terraform

# 2. Preflight: ssh / API token / template-exists / snippets-store checks.
#    preflight defaults to the UBUNTU template id for the node (pve12t2->9103),
#    so override it to check the real WINDOWS template (9203 on pve12t2):
TEMPLATE_VM_ID=9203 ./scripts/preflight.sh win-client

# 3. Plan, read it, then apply. NEVER -auto-approve against the cluster
#    (see the 2026-05-21 incident). Read the create/destroy line.
just plan win-client
just apply win-client          # plain `tofu apply`, type yes after reading
```

> The `just` recipes are parameterized by role name; if `win-client` isn't picked
> up because the dir isn't canonical yet, run the `scripts/...` / `tofu` forms
> shown in the comments directly from `vms/win-client/terraform/`.

## What success looks like

1. `tofu apply` completes; `qm list` on the node shows VMID 310 running.
2. The clone boots to Windows (not a UEFI shell / no-bootable-device) — this
   proves the EFI/TPM/SATA clone path (unknown #1 below).
3. `tofu output ipv4_addresses` reports a LAN IP — proves the virtio NIC +
   qemu-guest-agent came up on the clone.
4. RDP (or Proxmox console) login as `labadmin` with the vault password works.
5. On the guest, `C:\Windows\Setup\Scripts\win-client-userdata.log` shows the
   "admin labadmin ensured" / "done" lines — proves cloudbase-init ran the
   PowerShell user-data.
6. `net user Administrator` shows `Account active: No` — proves the cleanup
   ordering held. `net localgroup Administrators` lists `labadmin`.

## Break-glass & recovery

Login depends on cloudbase-init running our user-data on first boot. Defenses
against being locked out, weakest-failure to strongest-failure:

1. **The user-data script fails partway.** The admin account is created FIRST,
   before RDP and any other logic, so later failures can't strand you. The
   script also never re-throws — partial success is preserved and logged to
   `C:\Windows\Setup\Scripts\win-client-userdata.log`.

2. **cloudbase-init never runs / never reads the drive (worst case).** No
   account exists and the console has no usable login. Recover from the
   Proxmox HOST via the qemu-guest-agent, which runs as SYSTEM independently
   of cloudbase-init (it ships in the template and starts on boot):

   ```bash
   # From a Proxmox node (replace <vmid>). Creates a rescue admin out-of-band.
   ssh root@<node> "qm guest exec <vmid> --timeout 60 -- \
     powershell -NoProfile -Command \
     \"New-LocalUser -Name rescue -Password (ConvertTo-SecureString 'ChangeMe!23' -AsPlainText -Force) -PasswordNeverExpires; \
       Add-LocalGroupMember -Group Administrators -Member rescue\""
   ```

   This works as long as the guest agent is up (`qm agent <vmid> ping` from the
   node confirms it). It does NOT require cloudbase-init. This is the reason we
   don't carry a second in-guest "break-glass" account — the guest-agent path
   is independent of cloudbase-init and covers strictly more failure modes.

3. **Guest agent also down.** Last resort: offline recovery via the Proxmox
   console — boot WinPE/rescue media and do the utilman.exe / offline-registry
   password reset, or rebuild the clone (`tofu destroy` + `apply`). For a
   disposable spike VM, rebuild is usually faster than recovery.

## Open unknowns this spike is meant to resolve

Template 9203 config (verified 2026-06-05) the spike is matched against:
`bios: ovmf`, `machine: pc-q35-10.1`, `ostype: win11`; the `efidisk0`,
`tpmstate0`, and `sata0` disks all on `local-lvm`; cloud-init on `ide3`; NIC
`e1000e`.

1. **EFI/TPM on a bpg full-clone.** We declare `efi_disk` + `tpm_state` to match
   the template, on the SAME storage (local-lvm) so the clone copies them in
   place rather than relocating to NFS. Unknown whether bpg reconciles the
   cloned devices cleanly. If the plan proposes anything destructive around
   efi/tpm, STOP and capture the plan output — that informs the Phase-2 module
   change.
2. **cloudbase-init executing PowerShell user-data.** We rely on the
   `#ps1_sysnative` header + `UserDataPlugin`. If the log file never appears,
   cloudbase-init didn't recognize the user-data as a script (check the
   cloudbase-init log under `C:\Program Files\Cloudbase Solutions\...\log\`).
3. **cloud-init drive slot.** Declared `ide3` to match the template's existing
   cloud-init drive. Watch the plan for a SECOND cloud-init drive (e.g. an
   ide2 appearing) or a leftover ide3 — either means bpg isn't reusing the
   slot and cloudbase-init could read the wrong drive.
4. **SATA disk reconcile.** Boot disk declared `sata0` (template confirmed
   `sata0` on local-lvm). If bpg insists on scsi0, note it.
5. **virtio NIC on the clone.** The template uses `e1000e`; the clone declares
   `virtio` because the driver suite was installed post-build. If the guest
   gets no IP, the virtio NIC driver didn't take — fall back to e1000e.

## Known caveats (deliberate, for the spike only)

- **Password lands in cleartext** in the rendered cloud-init snippet on the
  snippets datastore (`local`, per-node). Acceptable for a lab spike; Phase 2
  can revisit (rotation / hashed delivery).
- **No `prevent_destroy`.** Omitted so this disposable VM can be recreated
  freely while iterating. The canonical Phase-2 role re-adds it (ADR-0009).
- **VMID 310 is a placeholder.** Confirm it's free cluster-wide (`qm list` on
  every node) before apply; change `var.vm_id` if it collides.
- **Template 9203 on pve12t2: BUILT 2026-06-05** (`./build-pve.sh pve12t2`,
  14m20s). q35/OVMF/TPM-v2.0, sysprep'd, cloud-init drive on ide3, all disks on
  local-lvm. The earlier blocker (no Windows template existed on any node — the
  Packer config was committed but never instantiated after the cluster
  rebuilds) is cleared. To rebuild it: `cd packer/windows-11-base &&
  ./build-pve.sh pve12t2` (needs `.env.pve12t2` with VM_ID=9203 + the Win11 and
  virtio-win ISOs in pve12t2's local ISO library — per-node, not shared).
- **Not canonical yet.** This dir will fail `just check-roles` (missing the
  canonical file set, non-module terraform). That's expected until Phase 2.

## Phase 2 — harden (only after the spike boots + injects an account)

- [ ] Parameterize `modules/proxmox-vm`: `disk_interface` + `iothread` knobs,
      optional `efi_disk` / `tpm_state` / `bios` / `operating_system`, so a
      Windows role can use the shared module instead of a raw resource.
- [ ] Decide SATA vs virtio-scsi for the boot disk based on spike findings.
- [ ] Make `vms/win-client/` canonical (file set, storage knobs, VMID per
      ADR-0008) so `just check-roles` passes.
- [ ] Wire the 5 new-VM monitoring touchpoints (see
      `vms/_template/README.md`) — node_exporter / windows_exporter for the
      guest, scrape marker, etc.
- [ ] Write `vms/win-client/README.md` (runbook depth matching `vms/openbao/`).
- [ ] Revisit the cleartext-password caveat.
- [ ] Add an Ansible role under `vms/win-client/ansible/` if post-boot config
      beyond account creation is needed (domain join, software, etc.).
