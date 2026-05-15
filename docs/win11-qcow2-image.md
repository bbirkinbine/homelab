# windows-11-base.qcow2 — first-boot state and credentials

The qcow2 image produced by `packer/windows-11-base/build-vbox.sh` (and converted from VMDK via `qemu-img convert -f vmdk -O qcow2`) is sysprep'd and ready for cloning. On first boot of every clone, a one-shot `PackerBuildCleanup` scheduled task disables the build credentials before any login is possible — so the only supported login path is to attach a NoCloud cidata seed and let `cloudbase-init` create your account from it.

For the Proxmox-template equivalent (per-node VMIDs 9200/9201/9202 — see [ADR-0006](decisions/0006-packer-templates-per-node.md)) the per-clone identity flows through `cicustom` cloud-init; see [docs/cloning-templates.md](cloning-templates.md). The credential model is the same on both targets — the cleanup task is registered by the shared [provision/99-sysprep.ps1](../packer/windows-11-base/provision/99-sysprep.ps1) and rides into every clone via sysprep `/generalize`.

## What's on disk after sysprep

Sysprep `/generalize /oobe` runs at the end of the build via [packer/windows-11-base/provision/99-sysprep.ps1](../packer/windows-11-base/provision/99-sysprep.ps1). Before sysprep itself runs, that script installs `C:\Windows\Setup\Scripts\packer-cleanup.ps1` and registers `PackerBuildCleanup` — a SYSTEM-context scheduled task triggered AtStartup. Sysprep preserves task definitions, so the task lands in every clone.

On the first boot of any clone, the task fires once and:

1. Waits up to ~120 s for `cloudbase-init` to reach Stopped (so per-clone user creation has finished).
2. Rotates the built-in Administrator password to a 32-byte random value generated from `RandomNumberGenerator.Create()` — never stored anywhere.
3. Runs `net user Administrator /active:no` to disable the account.
4. Clears `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`'s `AutoAdminLogon` / `DefaultPassword` / `DefaultUserName` / `AutoLogonCount` values written by the answer file.
5. Unregisters itself, removes its own script.

Net result: by the time the lock screen appears, the embedded build password from [http/Autounattend.xml](../packer/windows-11-base/http/Autounattend.xml) no longer works against any account, the Administrator account is disabled outright, and AutoAdminLogon will not fire. The only login path is whatever account `cloudbase-init` creates from a seed.

A log of the cleanup run is left at `C:\Windows\Setup\Scripts\packer-cleanup.log` for debugging.

## Verifying the cleanup ran

If you have console access to a freshly booted clone (e.g. via VBox's display), open `cmd.exe` from a logged-in cloudbase-init user and run:

```cmd
net user Administrator
```

Expect:

```text
Account active               No
```

Then check the AutoLogon registry keys:

```cmd
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount
```

`AutoAdminLogon` should be `0`; `AutoLogonCount` should report "ERROR: The system was unable to find the specified registry key or value" (the cleanup deleted the value).

If any of these don't match, look at `C:\Windows\Setup\Scripts\packer-cleanup.log` for the failure line, and verify the task ran:

```cmd
schtasks /query /tn PackerBuildCleanup
```

A successful one-shot leaves no task — the cleanup unregisters itself. `ERROR: The system cannot find the file specified` from `schtasks /query` means the task already self-destructed.

## First-boot user provisioning via cloud-init

The supported way to log into a clone is to attach a NoCloud cidata ISO so `cloudbase-init` creates your account on first boot. There's a helper for the standalone qcow2 path:

```bash
cd packer/windows-11-base
cp seed/lab-seed.example.yaml seed/lab-seed.yaml      # one-time
# Edit seed/lab-seed.yaml — set username, plaintext password, SSH pubkey
./seed/build-cidata.sh                                 # → output-vbox/cidata.iso
```

`seed/lab-seed.yaml` is gitignored — only `seed/lab-seed.example.yaml` ships in the repo. `build-vbox.sh` also auto-runs `build-cidata.sh` at the end of a successful build if `seed/lab-seed.yaml` is present, so a single `./build-vbox.sh t480-vbox` produces both the qcow2 and a matching cidata.iso.

To use:

```bash
qemu-img convert -f vmdk -O qcow2 -p \
  output-vbox/windows-11-base-disk001.vmdk \
  output-vbox/windows-11-base.qcow2

VBoxManage import output-vbox/windows-11-base.ovf
# In VBox UI: attach output-vbox/cidata.iso as a second CDROM, boot.
```

The same cidata.iso works for virt-manager / libvirt — attach as a second CDROM under the imported qcow2.

For richer per-clone configuration (multiple users, runcmd, hostname patterns, package install via Chocolatey, etc.) see [docs/cloning-templates.md](cloning-templates.md). The `cloudbase-init` configuration installed by [provision/30-install-cloudbase-init.ps1](../packer/windows-11-base/provision/30-install-cloudbase-init.ps1) accepts the same `cloud-config` shape Linux cloud-init does, modulo the Windows-specific limitations called out in that doc's "Gotchas" section.

## What if there's no cidata seed attached?

Boot proceeds normally. `cloudbase-init` logs "no NoCloud datasource found" and exits. The `PackerBuildCleanup` task still fires AtStartup, the Administrator account is still disabled, and the lock screen comes up with no enabled local user. **There is no usable login path in this state** — recovery is offline registry edit on the qcow2 (boot rescue media, mount the disk, re-enable Administrator and rotate the password). Don't rely on this.

If you want to fire up the image for a one-off and don't already have a `seed/lab-seed.yaml`, the fastest path is to make one and rebuild the cidata.iso — `seed/build-cidata.sh` runs in under a second.

## Related

- [docs/cloning-templates.md](cloning-templates.md) — full cloud-init / cicustom flow for both bases, including the Proxmox-side Terraform pattern.
- [packer/windows-11-base/seed/lab-seed.example.yaml](../packer/windows-11-base/seed/lab-seed.example.yaml) — committed template; copy to `lab-seed.yaml` and edit.
- [packer/windows-11-base/seed/build-cidata.sh](../packer/windows-11-base/seed/build-cidata.sh) — Linux helper, requires `genisoimage`.
- [packer/windows-11-base/provision/99-sysprep.ps1](../packer/windows-11-base/provision/99-sysprep.ps1) — registers the cleanup task; the embedded `packer-cleanup.ps1` heredoc is the cleanup script itself.
