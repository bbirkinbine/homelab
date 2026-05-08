# windows-11-base.qcow2 — first-boot state and credentials

The qcow2 image produced by `packer/windows-11-base/build-vbox.sh` (and converted via `qemu-img convert -f vmdk -O qcow2`) is sysprep'd and ready for cloning, but it boots in a "build-only" credential state. This doc explains what's set, how to verify it, and how to lock it down for general use.

For the Proxmox-template equivalent (VM 9101), see [docs/cloning-templates.md](cloning-templates.md). The state described below is specific to the standalone qcow2 produced by the virtualbox-iso target — Proxmox-side cloning uses `cicustom` cloud-init to inject per-clone identity at clone time, which generally hides the build-Administrator account.

## What's on disk after sysprep

Sysprep `/generalize /oobe` runs at the end of the build via [packer/windows-11-base/provision/99-sysprep.ps1](../packer/windows-11-base/provision/99-sysprep.ps1). The next time the disk boots:

- The **built-in `Administrator` account is enabled** with the build password `packer-build-only-Win11!`. This was set in [http/Autounattend.xml](../packer/windows-11-base/http/Autounattend.xml) `<UserAccounts>` and survives `/generalize` (sysprep clears machine SID and drivers, not local account passwords).
- The **`AutoAdminLogon` registry values** in `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` are **also preserved through sysprep**: `AutoAdminLogon = 1`, `DefaultUserName = Administrator`, `DefaultPassword` (LSA-secret), and `AutoLogonCount = 5` (set by `<AutoLogon><LogonCount>` in the answer file).
- On each boot, `AutoLogonCount` decrements by one. When it reaches zero, AutoAdminLogon is disabled by Windows itself and the login prompt returns.
- **cloudbase-init is installed** and active on first boot; it looks for a NoCloud datasource (CDROM with FAT/ISO9660 volume label `cidata`, files `meta-data` and `user-data` at root). If found, cloudbase-init creates the user(s) defined in `user-data` and the boot proceeds without further interaction. If no cidata is present, cloudbase-init logs the absence and exits silently — Windows then auto-logs in as `Administrator` per the registry values.

The net effect for a fresh `qemu-system-x86_64` boot of the qcow2 with no cloud-init seed attached: you land on the desktop as `Administrator` with no password prompt, for the next ~5 boots.

## Credential reference (build-only)

| Field | Value | Source |
|---|---|---|
| Username | `Administrator` | built-in account, enabled |
| Password | `packer-build-only-Win11!` | [variables.pkr.hcl](../packer/windows-11-base/variables.pkr.hcl) `var.build_password`, embedded in [http/Autounattend.xml](../packer/windows-11-base/http/Autounattend.xml) |
| AutoAdminLogon | `1` (5 boots remaining max) | [http/Autounattend.xml](../packer/windows-11-base/http/Autounattend.xml) `<AutoLogon><LogonCount>5</LogonCount>` |

These credentials are **build-only by intent** and should not be left in place on any VM that's reachable from the network. Lock down before exposing the VM (see *Hardening before general use* below).

## Verifying the password and AutoLogon state from inside the VM

You can confirm the account/AutoLogon state without rebooting. Open `cmd.exe` and run:

```
net user Administrator
```

Look for these lines:

```
Account active               Yes
Password required            Yes
Password last set            <date>
```

Then check the AutoLogon registry keys:

```
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount
```

Expect `AutoAdminLogon = 1`, `DefaultUserName = Administrator`, and `AutoLogonCount` decreasing each boot. `DefaultPassword` is stored as an LSA secret and won't appear via `reg query` — that's normal.

**Quick behavioural test:** press **Win+L** to lock the session. The lock screen will prompt for a password — enter `packer-build-only-Win11!` and it should unlock. If the lock screen accepts an empty password, the account has been re-configured and the values above no longer apply.

## Hardening before general use

If you plan to keep this qcow2 around as a reusable workstation image (rather than a one-shot template that gets discarded after each clone), run the following from an elevated `cmd.exe` to remove the AutoLogon and rotate the Administrator password:

```
:: 1. Kill AutoAdminLogon — every login from now on prompts for credentials
reg add    "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount /f

:: 2. Rotate the Administrator password — pick a strong one
net user Administrator <new-password-here>

:: 3. (Optional) Disable the built-in Administrator entirely if you've created
::    your own account with admin rights. Windows recommends this for the
::    "real" account model.
net user Administrator /active:no
```

The two `reg delete` commands can fail with "ERROR: The system was unable to find the specified registry key or value" if those values aren't present — that's fine, it just means there's nothing to remove.

After rotating, capture the new password somewhere durable (KeePassXC) and reboot to confirm the lock-screen prompt now expects the new password.

## First-boot user provisioning via cloud-init

For the production-clone path (the way Proxmox templates are consumed), don't log in as Administrator at all — let cloudbase-init create your user from a NoCloud seed. Build the seed once:

```bash
mkdir -p /tmp/cidata
cat > /tmp/cidata/meta-data <<'EOF'
instance-id: win11-test
local-hostname: win11-test
EOF
cat > /tmp/cidata/user-data <<'EOF'
#cloud-config
users:
  - name: brian
    passwd: <strong-password>
    groups: Administrators
EOF
genisoimage -output /tmp/cidata.iso -volid cidata \
            -joliet -rock /tmp/cidata
```

Attach `/tmp/cidata.iso` as a second CDROM in the VM (in virt-manager: Add Hardware → CDROM → point at the file). Boot. cloudbase-init reads the seed, creates the `brian` user, and from then on you log in as `brian` with the password from `user-data`. The Administrator account is still there but you stop using it.

For richer per-clone configuration (SSH keys, runcmd, hostname patterns, package install via Chocolatey, etc.) see [docs/cloning-templates.md](cloning-templates.md). The cloudbase-init configuration installed by [provision/30-install-cloudbase-init.ps1](../packer/windows-11-base/provision/30-install-cloudbase-init.ps1) accepts the same `cloud-config` shape Linux cloud-init does, modulo Windows-specific limitations (no `chpasswd`, password is plaintext for the user-creation step rather than `hashed_passwd`, etc.).

## Open improvement: tighten the sysprep script

[provision/99-sysprep.ps1](../packer/windows-11-base/provision/99-sysprep.ps1) currently writes a minimal post-sysprep `unattend.xml` that skips OOBE pages but does not clear the AutoAdminLogon registry values, disable the built-in Administrator, or rotate the build password. The above hardening steps should arguably run as part of sysprep so the qcow2 ships in a locked-down state by default. That's a future change to the build pipeline; for now, run the hardening manually if you're using the qcow2 outside the per-clone cloud-init flow.
