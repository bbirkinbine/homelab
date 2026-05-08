# windows-11-base — Windows 11 Pro x64 Packer template

Builds a Windows 11 Pro x64 VM template for two targets in one Packer config:

- **`proxmox-iso`** — Proxmox template VM 9101 (parallel to `ubuntu-24-04-base` at VM 9100). **Validated, shipping.**
- **`virtualbox-iso`** — VMware-style OVF + VMDK + NVRAM in `output-vbox/`. Local builds on a Linux host with VirtualBox 7.0+; the VMDK converts to qcow2 in ~5 minutes for use in virt-manager / libvirt. **Validated end-to-end 2026-05-08** — full Win11 24H2 install + sysprep in ~44 minutes.

Both share the same `Autounattend.xml` and the same PowerShell provisioner pipeline, ending at the same sysprep'd state.

---

## Requirements

The two builders have different build-host needs and are intentionally run from different machines. The shared HCL config is cloned to both; each host runs only its own target via `-only=` (set automatically from the env file's `BUILDER` var).

### Build host for `proxmox-iso` — any OS

`packer build` only talks to the Proxmox API; the Windows install runs on the Proxmox node, not on the build host. So this side has no local hypervisor dependency and runs equally well from macOS or Linux.

- macOS or Linux (this is the primary dev machine in our setup — MacBook Pro M2 Max).
- `packer` >= 1.10.0 (`brew install packer` on macOS, `apt install packer` on Ubuntu).
- Network reachability to the Proxmox node and a Proxmox API token (`packer@pve!builder`).
- For the windows-update provisioner (optional): the `rgl/windows-update` plugin (auto-installed by `packer init`).

### Build host for `virtualbox-iso` — Linux with VirtualBox 7.0+ (the T480)

The virtualbox-iso source runs the Windows install in VirtualBox locally and writes VMDK + OVF + NVRAM to `output-vbox/`. The disk converts to qcow2 with `qemu-img convert` for use in virt-manager / libvirt.

- Ubuntu 24.04 with VirtualBox **>= 7.0** (Win11 needs UEFI + TPM 2.0 + Secure Boot, all introduced in 7.0). Ubuntu 24.04 universe currently ships VBox 7.2.x, which is fine:

  ```bash
  sudo apt install -y virtualbox
  ```

  VBox kernel modules (`vboxdrv`, `vboxnetadp`, `vboxnetflt`) coexist with `kvm_intel`/`kvm_amd` on this host without issue, so this build host can keep its KVM workloads.
- `packer` >= 1.10.0. Note: HashiCorp moved Packer to the BSL license in late 2023, so it's no longer in Ubuntu's main repos. Install the static binary from `https://releases.hashicorp.com/packer/<version>/packer_<version>_linux_amd64.zip` and drop into `/usr/local/bin/`.
- The `virtualbox` Packer plugin (`packer init` installs it automatically; pulled from `github.com/hashicorp/virtualbox`).
- Optional: `qemu-utils` for the post-build `qemu-img convert -f vmdk -O qcow2 …` step that produces the qcow2 for virt-manager.

### ISOs (download once)

- **Windows 11 multi-edition x64 ISO** — from [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11)
- **virtio-win.iso** — from [fedorapeople.org/groups/virt/virtio-win](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso)

For the proxmox-iso target: upload both ISOs into a Proxmox storage pool (e.g. `local`) before building.

For the virtualbox-iso target: place both on the build host's local filesystem and reference paths in the env file.

---

## Quick start

The repo is cloned to both build hosts. Each one only has the env file(s) for the targets it builds.

### 1. Configure credentials and paths

**On the Mac (proxmox-iso targets):**

```bash
cd packer/windows-11-base
cp .env.pve.example .env.pve12     # proxmox build on pve12 — edit and fill in
cp .env.pve.example .env.pve13     # proxmox build on pve13 — edit and fill in
```

**On the T480 (virtualbox-iso target):**

```bash
cd packer/windows-11-base
cp .env.vbox.example .env.t480-vbox   # local VBox build — edit and fill in
```

`.env.*` files are gitignored — fill in per-host secrets without committing.
Each builder has its own `.env.*.example` template; the proxmox one
covers Proxmox API + storage refs, and the vbox one covers local file
paths + checksum + the post-build VMDK→qcow2 conversion recipe.

### 2. Initialize Packer

`build-pve.sh` and `build-vbox.sh` each invoke `packer init` for you on
first run, so you don't normally need to do this manually. If you're
debugging or want to pre-fetch the plugins:

```bash
packer init .
```

Downloads the `proxmox`, `virtualbox`, and `windows-update` plugins.
(The build scripts only consume the plugin matching their builder, but
`packer init` is a no-op for already-installed plugins so it's
harmless either way.)

### 3. Build

**On the Mac (proxmox-iso target):**

```bash
./build-pve.sh pve12       # → Proxmox template VM 9101 on pve12
./build-pve.sh pve13       # → Proxmox template VM 9101 on pve13
```

**On the T480 (virtualbox-iso target):**

```bash
./build-vbox.sh t480-vbox  # → output-vbox/windows-11-base.vdi (+ .ovf, .mf)
```

After the VBox build, convert the VMDK to qcow2 for virt-manager / libvirt:

```bash
qemu-img convert -f vmdk -O qcow2 -p \
  output-vbox/windows-11-base-disk001.vmdk \
  output-vbox/windows-11-base.qcow2
```

`build-pve.sh` and `build-vbox.sh` are sibling scripts: same `.pkr.hcl`, same Autounattend.xml, same provisioner pipeline, but separate operational paths because the host requirements diverge sharply (Proxmox API access vs. local VirtualBox). Both refuse to run when their preconditions aren't met (e.g. `build-vbox.sh` checks `VBoxManage --version` >= 7.0).

Build duration:

- proxmox-iso (Mac → Proxmox API): **~15 minutes default** (no patches), ~60–90 minutes if you uncomment the windows-update provisioner — see *Patching strategy* below
- virtualbox-iso (T480 local VBox): **~45 minutes default** (no patches) for the install + provisioners + sysprep, then ~5 minutes for the VMDK→qcow2 conversion

A single invocation runs one source. There are deliberately two separate build scripts instead of one with branching, because each target has meaningfully different host requirements and different fragility surfaces.

---

## What the build produces

### Proxmox target

Template VM 9101 in the configured Proxmox node:

- BIOS=ovmf (UEFI), EFI vars disk + emulated TPM 2.0
- VirtIO SCSI disk + VirtIO NIC
- Cloud-init drive attached for first-boot per-clone configuration
- VirtIO drivers + QEMU guest agent + cloudbase-init installed
- Sysprep'd and shut down — boots into OOBE-mini → cloudbase-init on next clone

Clone with Terraform/OpenTofu the same way as the Ubuntu base.

### virtualbox-iso target

In `output-vbox/`:

- `windows-11-base-disk001.vmdk` — the boot disk (~18 GB on disk, 60 GB sparse). Despite the VMware-style VMDK extension, this is a VBox-built disk packaged in the OVF/VMDK convention (the `format = "ovf"` setting in the HCL).
- `windows-11-base.ovf` — VMware OVF descriptor.
- `windows-11-base.nvram` — UEFI variable store (Secure Boot keys, boot order).

Same OS state as the Proxmox target (sysprep'd, cloudbase-init present, virtio drivers registered in the driver store).

To use directly in VirtualBox: `VBoxManage import output-vbox/windows-11-base.ovf`.

To use in virt-manager / libvirt, convert the VMDK to qcow2:

```bash
qemu-img convert -f vmdk -O qcow2 -p \
  output-vbox/windows-11-base-disk001.vmdk \
  output-vbox/windows-11-base.qcow2
```

Then in virt-manager: New VM → Import existing disk image → point at the qcow2 → choose Windows 11 → enable UEFI (OVMF) + TPM 2.0 in customize-before-install → 8 GB RAM / 4 vCPUs / sata or virtio-scsi disk.

The disk is built with VBox's AHCI controller and the Intel PRO/1000 NIC, both of which Win11 has built-in drivers for. `virtio-win-guest-tools.exe` is also installed during the build so the disk and NIC can be switched to virtio-scsi/virtio-net once running on libvirt — the drivers are already in the driver store, no second install pass needed.

---

## Patching strategy

**By default, this template is unpatched as of the install ISO's release
date.** The `windows-update` and `windows-restart` provisioner blocks in
[windows-11-base.pkr.hcl](windows-11-base.pkr.hcl) are commented out so
the default `./build-pve.sh pve12` run is fast (~15 min) instead of the
60–90 min required to apply cumulative updates at build time.

This is intentional, but it only works because patches are applied
*downstream* of the template, not in it. Pick one of these per-clone
patterns when you deploy:

**Per-clone via cloud-init.** Add a `runcmd:` block to the cloud-config
snippet attached at clone time. Example for SSH'ing in and running
PSWindowsUpdate:

```yaml
#cloud-config
hostname: myvm
users:
  - name: brian
    primary_group: Administrators
    passwd: SomeStrongPassword!
runcmd:
  - 'powershell.exe -NoProfile -Command "Install-PackageProvider -Name NuGet -Force; Install-Module PSWindowsUpdate -Force; Get-WindowsUpdate -AcceptAll -Install -AutoReboot"'
```

See [docs/cloning-templates.md](../../docs/cloning-templates.md) for the
full clone + cicustom flow.

**Per-role via Ansible / Terraform.** A separate playbook step targeting
the deployed VM. Same outcome, easier to schedule and re-run.

**At template build time (the slow path).** If you'd rather ship a
fully-patched template — e.g. for an air-gapped network where clones
can't reach Windows Update — uncomment both provisioner blocks in
[windows-11-base.pkr.hcl](windows-11-base.pkr.hcl) (search for
`WINDOWS UPDATES: DISABLED BY DEFAULT`). Expect 60–90 min builds and
plan for the rgl/windows-update plugin's `SucceededWithErrors` retry
loop on a fresh 24H2 install — common on a clean image, the plugin
retries automatically and usually breaks through within 5–8 minutes.

---

## File layout

```
windows-11-base/
├── README.md                      # this file
├── windows-11-base.pkr.hcl        # main config: 2 sources + 1 build block
├── variables.pkr.hcl              # input variables
├── versions.pkr.hcl               # required_plugins
├── http/
│   └── Autounattend.xml           # Windows unattended install config
├── provision/
│   ├── 00-wait-for-winrm.ps1      # idle until WinRM is reachable
│   ├── 10-install-virtio.ps1      # VirtIO drivers + QEMU guest agent
│   ├── 15-windows-cleanup.ps1     # disable telemetry, hibernate, news, OneDrive
│   ├── 20-harden.ps1              # firewall, RDP, SSH, audit policy
│   ├── 30-install-cloudbase-init.ps1   # cloud-init for Windows
│   └── 99-sysprep.ps1             # generalize, shutdown
├── build-pve.sh                   # proxmox-iso builder wrapper (Mac or any host with Proxmox API access)
├── build-vbox.sh                  # virtualbox-iso builder wrapper (Linux + VirtualBox 7.0+ only)
├── .env.pve.example               # template for .env.<node> (proxmox builds)
└── .env.vbox.example              # template for .env.<host> (VirtualBox builds)
```

---

## Validation after build

After `./build-pve.sh pve12`:

1. Proxmox UI → confirm VM 9101 exists, marked as template, BIOS=ovmf, EFI disk + TPM present, no CD-ROM attached.
2. Clone via Terraform/OpenTofu (or `qm clone 9101 999 --name wintest`).
3. RDP/SSH in via the credentials cloudbase-init configured.
4. From inside the VM:
   ```powershell
   Get-Service WinRM, sshd, cloudbase-init    # all running
   Get-NetFirewallRule -DisplayName "Allow RDP*"  # Enabled
   Get-WindowsOptionalFeature -Online -FeatureName OpenSSH-Server  # Enabled
   ```
5. Destroy the test clone.

After `./build-vbox.sh t480-vbox`:

1. Convert the VMDK to qcow2 (see *Build* above) — `qemu-img convert -f vmdk -O qcow2 …`.
2. Open virt-manager → New VM → Import existing disk image → browse to `output-vbox/windows-11-base.qcow2`.
3. Configure: UEFI firmware, emulated TPM 2.0, sata or virtio-scsi disk, virtio NIC, 8 GB RAM, 4 vCPUs.
4. Boot — should land at OOBE-mini, then cloudbase-init reads any attached cloud-init seed and configures the clone.
5. For lab use without a cloud-init seed, you can also boot directly to OOBE and complete it manually once. See [docs/win11-qcow2-image.md](../../docs/win11-qcow2-image.md) for the first-boot Administrator credential state and NoCloud seed instructions.

---

## Operational gotchas

- **Autounattend.xml is brittle.** A typo in a `<UserData>` or `<ProductKey>` block can hang the install at OOBE indefinitely with no error message. Test changes incrementally.
- **VirtIO driver path** must match the Windows version (`amd64\w11\` for Win11). Wrong path = "no disk found" at install.
- **WinRM bootstrap** is the most fragile single command. The Autounattend.xml runs synchronous PowerShell at end-of-install to enable WinRM and open the firewall. If that fails, Packer never connects.
- **Microsoft account skip.** The `OOBE/HideOnlineAccountScreens` setting in Autounattend.xml is what bypasses the cloud-account requirement on Win11 24H2. If a future Windows version blocks this too, you may need to splice in `OOBE\BYPASSNRO` reg writes from the answer file.
- **VirtualBox kernel modules.** `build-vbox.sh` requires `vboxdrv` / `vboxnetadp` / `vboxnetflt` loaded. After a kernel upgrade these can be missing until DKMS rebuilds — `sudo modprobe vboxdrv` or `sudo /sbin/vboxconfig`.
- **Sysprep terminates the WinRM session.** The `99-sysprep.ps1` script generalizes and shuts down; Packer expects the WinRM disconnect. The build block sets `valid_exit_codes = [0]` to allow it.
- **License activation watermark.** The KMS install key in Autounattend gets you through setup but doesn't activate Windows. Clones will show an activation watermark unless you supply a real key or use the eval ISO. Acceptable for lab.
- **VM ID collision.** Default is 9101 (next to Ubuntu's 9100). If 9101 is taken on the target node, set `VM_ID=` in the env file.
- **Build user password embedded.** Both `variables.pkr.hcl` and `http/Autounattend.xml` have `packer-build-only-Win11!`. Change one, change the other.
- **Windows Update is disabled by default.** See *Patching strategy* above. The default fast path produces an unpatched template; clones must be patched downstream via cloud-init `runcmd:` or per-role Ansible. The HCL toggle is a documented one-line uncomment.

---

## Related

- `../ubuntu-24-04-base/` — sibling Linux base (Proxmox-only)
- `../../docs/proxmox-permissions.md` — Proxmox API user/token setup (reused as-is for the proxmox-iso target)
