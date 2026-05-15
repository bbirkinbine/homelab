// =============================================================================
// windows-11-base.pkr.hcl
//
// Builds a Windows 11 Pro x64 VM template with two target builders:
//   1. proxmox-iso    : Per-node Proxmox templates VM 9200/9201/9202 for
//                       pve12t/pve13m/pve13t (parallel to Ubuntu 9100/
//                       9101/9102 — see ADR-0006). Override per host via
//                       VM_ID= in each .env.<node>.
//   2. virtualbox-iso : standalone VMDK/OVF in output-vbox/, convertible
//                       to qcow2 for virt-manager via `qemu-img convert`
//
// Both sources share the same Autounattend.xml (delivered as a `cd_files`
// CD that Win11 Setup auto-detects), the same PowerShell provisioner
// pipeline, and the same end-state (sysprep'd, ready for cloudbase-init
// at first boot of each clone).
// =============================================================================

// =============================================================================
// SOURCE 1: proxmox-iso — homelab Proxmox template
// =============================================================================

source "proxmox-iso" "windows-11-base" {

  // ---------- Proxmox API ----------
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_skip_tls_verify
  node                     = var.proxmox_node

  // ---------- VM identity ----------
  vm_id                = var.vm_id
  vm_name              = var.vm_name
  template_name        = var.vm_name
  template_description = "Windows 11 Pro x64 hardened base, packer-built ${formatdate("YYYY-MM-DD", timestamp())}"

  // ---------- VM hardware (Win11 requires UEFI + TPM 2.0) ----------
  // Boot disk is on SATA (AHCI), not virtio-scsi or LSI. This was
  // determined empirically on 2026-05-07 by listing Win11 24H2's WinPE
  // bundled storage drivers from Shift+F10:
  //   - msiscsi.sys, pvscsii.sys, scsiport.sys, storahci.sys present
  //   - sym_*, megasas, viostor, vioscsi NOT present
  // So out-of-the-box Win11 24H2 only sees the install disk if it's on
  // SATA AHCI (storahci.sys), VMware PV SCSI (pvscsii.sys), or NVMe.
  //
  // virtio-scsi-single would be ideal — but Win11 24H2's setup host also
  // ignores Microsoft-Windows-Setup\DriverPaths in Autounattend.xml, so
  // we can't inject vioscsi at install-time without modifying the install
  // ISO (which we may revisit later). LSI 53C895A was dropped from
  // 24H2 entirely. SATA is the universally-supported fallback.
  //
  // After install, provision/10-install-virtio.ps1 runs
  // virtio-win-guest-tools.exe which adds vioscsi to the driver store as
  // a boot-critical service. Clones can then switch their disk bus to
  // virtio-scsi at clone time and boot fine via OVMF + the registered
  // boot driver.
  cores    = var.vm_cores
  memory   = var.vm_memory
  cpu_type = "host"
  os       = "win11"
  machine  = "q35"
  bios     = "ovmf"

  efi_config {
    efi_storage_pool  = var.vm_storage_pool
    pre_enrolled_keys = false
    efi_type          = "4m"
  }

  tpm_config {
    tpm_storage_pool = var.vm_storage_pool
    tpm_version      = "v2.0"
  }

  disks {
    type         = "sata"
    storage_pool = var.vm_storage_pool
    disk_size    = var.vm_disk_size
    format       = "raw"
    cache_mode   = "writeback"
    discard      = true
    ssd          = true
    // io_thread is intentionally not set: it's only valid on
    // scsihw=virtio-scsi-single. Clones that switch to virtio-scsi can
    // re-enable io_thread on their per-clone disks.
  }

  network_adapters {
    // e1000e (Intel 82574L) for the BUILD, not virtio. Win11 24H2 ships
    // storahci.sys for the disk but does NOT ship netkvm.sys (verified
    // 2026-05-07), so a virtio NIC has no driver during install/OOBE,
    // the VM cannot DHCP, the QEMU guest agent has no IP to report, and
    // Packer's "Waiting for WinRM" hangs until manual intervention.
    // e1000e is built-in on 24H2. After the provisioner installs the
    // virtio driver suite, clones can switch to model=virtio for perf.
    model    = "e1000e"
    bridge   = var.vm_bridge
    vlan_tag = var.vlan_tag
    firewall = false
  }

  qemu_agent = true

  // ---------- ISO sources: Windows 11 + VirtIO drivers ----------
  boot_iso {
    type             = "ide"
    iso_file         = var.iso_file
    iso_storage_pool = var.iso_storage_pool
    unmount          = true
  }

  additional_iso_files {
    type             = "ide"
    iso_file         = var.virtio_iso_file
    iso_storage_pool = var.iso_storage_pool
    unmount          = true
  }

  // Auto-built CD containing Autounattend.xml. Windows Setup scans the root
  // of every attached optical drive for Autounattend.xml and applies the first
  // one it finds — that is the only delivery path that works for stock Win11
  // ISOs. Serving the file over HTTP alone is not sufficient: Setup does not
  // fetch from arbitrary URLs without WDS/MDT scaffolding. cd_files makes
  // Packer assemble a tiny ISO from the listed files, upload it to the
  // configured storage pool, and attach it as a CD-ROM for the install.
  additional_iso_files {
    type             = "ide"
    cd_files         = ["./http/Autounattend.xml"]
    cd_label         = "Unattend"
    iso_storage_pool = var.iso_storage_pool
    unmount          = true
  }

  // ---------- Boot command ----------
  // Setup reaches the unattend file via the auto-built CD above; the HTTP
  // directory is kept available so post-install scripts can fetch from it
  // if we ever need that, but Setup itself is no longer dependent on HTTP.
  http_directory = "http"

  boot_wait = "5s"
  boot_command = [
    // Press a key at "Press any key to boot from CD or DVD..." prompt so
    // setup launches from the Win11 ISO. Once Setup runs, Autounattend.xml
    // on the unattend CD takes over; no further keypresses needed.
    "<enter><wait>"
  ]

  // ---------- WinRM for provisioners ----------
  // Autounattend.xml's <FirstLogonCommands> enables WinRM with HTTP listeners
  // and opens the firewall port before declaring install complete.
  communicator   = "winrm"
  winrm_username = var.build_username
  winrm_password = var.build_password
  winrm_timeout  = "60m"
  winrm_port     = 5985

  // ---------- Cloud-init for first-boot per-clone config ----------
  // Proxmox attaches a cloud-init drive; cloudbase-init in the guest reads it.
  cloud_init              = true
  cloud_init_storage_pool = var.vm_storage_pool
}

// =============================================================================
// SOURCE 2: virtualbox-iso — standalone VMDK/OVF for VirtualBox/virt-manager
// =============================================================================
//
// Why this source exists. The proxmox-iso source above produces a Proxmox
// VM template that's cloned by Terraform/OpenTofu via the Proxmox API; that
// covers the homelab's primary use case. The virtualbox-iso source covers
// non-Proxmox consumers: builds locally on a Linux host with VirtualBox
// 7.0+, produces a VMDK/OVF that imports cleanly into VBox, and the disk
// converts to qcow2 in ~5 minutes for use in virt-manager / libvirt.
//
// (Earlier we attempted a `qemu` source via packer-plugin-qemu directly.
// That source's HCL was structurally complete but the actual install was
// blocked on a host-specific input-timing class of bug on T480 + qemu 8.2
// + Ubuntu OVMF: cdboot.efi's "Press any key to boot from CD or DVD..."
// prompt window cannot be reliably caught by Packer's RFB/VNC keystroke
// delivery or even by QMP send-key direct injection — every variant
// tested 2026-05-07 missed. VirtualBox's display/input pipeline is
// independent of RFB and doesn't have that latency, so the install
// proceeds normally here. The qemu source was removed 2026-05-08; git
// history has the attempt if anyone wants to revisit it on different
// hardware.)
//
// Output in output-vbox/: windows-11-base-disk001.vmdk (boot disk),
// windows-11-base.ovf (descriptor), windows-11-base.nvram (UEFI vars).
// The plugin's format = "ovf" packages with VMware-style VMDK; despite
// the name, this is a VBox-built disk in OVF/VMDK convention, not a
// VMware disk. qemu-img reads VMDK natively. Convert to qcow2 for
// virt-manager / libvirt with:
//
//   qemu-img convert -f vmdk -O qcow2 -p \
//     output-vbox/windows-11-base-disk001.vmdk \
//     output-vbox/windows-11-base.qcow2
//
// The resulting qcow2 boots in virt-manager with UEFI (OVMF) + TPM 2.0
// + sata disk. virtio-win-guest-tools.exe is installed by
// provision/10-install-virtio.ps1 during the build, so vioscsi/NetKVM
// drivers are registered in the driver store and clones can switch to
// virtio-scsi/virtio-net later if desired.

source "virtualbox-iso" "windows-11-base" {

  // ---------- VM identity / hardware ----------
  vm_name              = var.vm_name
  guest_os_type        = "Windows11_64"
  cpus                 = var.vm_cores
  memory               = var.vm_memory
  disk_size            = parseint(replace(var.vm_disk_size, "G", ""), 10) * 1024
  hard_drive_interface = "sata"

  // VirtualBox-native EFI flag. With firmware = "efi" + the vboxmanage
  // commands below (--tpm-type 2.0, secureboot --enable), this matches
  // the Win11 hardware requirements VBox enforces. Microsoft's UEFI CA
  // is in VBox's pre-enrolled key set, so bootmgfw verifies cleanly and
  // the install proceeds without our BypassSecureBootCheck reg writes
  // (which Autounattend.xml has anyway, harmlessly).
  firmware = "efi"

  // ---------- ISO sources ----------
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  // 82540EM = Intel PRO/1000 MT Desktop. Win11 24H2 has the e1g6032e.sys
  // driver built in to WinPE, so DHCP works during install with no
  // driver injection. AHCI for the boot disk likewise has built-in
  // storahci.sys. Win11 boots cleanly without virtio drivers; those
  // are installed post-WinRM via provision/10-install-virtio.ps1 so
  // the qcow2 is portable to libvirt with virtio-scsi later.
  nic_type      = "82540EM"
  iso_interface = "sata"

  // ---------- Autounattend on auto-built CD ----------
  //
  // Win11 24H2 Setup scans the root of every attached OPTICAL drive
  // for Autounattend.xml and applies the first one it finds; floppy
  // delivery doesn't work with the multi-edition Pro install ISO
  // (verified 2026-05-07 — VBox build with floppy_files booted past
  // press-any-key but Setup landed on the interactive Select-Language
  // screen and waited for Next, indicating Autounattend wasn't read).
  // This matches the proxmox-iso source's mechanism: cd_files makes
  // Packer assemble a tiny ISO from the listed files and attach it
  // as an additional CD-ROM that Setup picks up automatically.
  //
  // The PnpCustomizationsWinPE driver-paths block in the answer file
  // references E:\<driver>\w11\amd64 paths (the virtio-win.iso CDROM
  // drive letter). On VBox, virtio-win.iso is attached as a second
  // SATA CDROM via the vboxmanage block below; the auto-built unattend
  // CD becomes a third CDROM. Drive-letter assignment in WinPE is
  // alphabetical-by-discovery, but the PnP block matches by INF
  // metadata (wcm:keyValue) so exact letter doesn't matter.
  cd_files = ["./http/Autounattend.xml"]
  cd_label = "Unattend"

  http_directory = "http"

  // ---------- VBox-specific provisioning ----------
  //
  // vboxmanage runs `VBoxManage <args>` after VM creation but before
  // first boot. {{.Name}} expands to the VM's name (var.vm_name).
  //
  // 1. --tpm-type 2.0 — emulated TPM 2.0, required by Win11.
  // 2. modifynvram inituefivarstore — create the UEFI variable store
  //    file. VBox doesn't create this until first boot otherwise, so
  //    the enrollmssignatures and secureboot subcommands below would
  //    fail with "The UEFI NVRAM file is not existing for this
  //    machine" (verified empirically 2026-05-07).
  // 3. modifynvram enrollmssignatures — enroll Microsoft's UEFI CA +
  //    Windows production signing keys into the variable store. With
  //    these enrolled, bootmgfw verifies cleanly under Secure Boot.
  // 4. modifynvram secureboot --enable — turn on Secure Boot
  //    enforcement. Win11 install sees secboot active and proceeds.
  //    Our existing BypassSecureBootCheck reg writes in the
  //    Autounattend become a no-op here, harmless.
  // 5. --graphicscontroller vboxsvga — paravirtualized; works without
  //    extra drivers and gives a usable Setup GUI.
  // 6. storageattach to add virtio-win.iso as a second CDROM on the
  //    SATA controller. VBox auto-creates a SATA controller named
  //    "SATA Controller" when hard_drive_interface = "sata"; the
  //    plugin attaches the boot ISO at port 0 and the qcow2 disk at
  //    port 1, so virtio-win.iso goes at port 2.
  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--tpm-type", "2.0"],
    ["modifynvram", "{{.Name}}", "inituefivarstore"],
    // Enroll Oracle's platform key (PK). Without a PK, Secure Boot
    // can't be enabled — VBoxManage errors with "Secure boot is not
    // available because the platform key (PK) is not enrolled". The
    // PK signs the KEK; with Oracle's PK in place we can then enroll
    // Microsoft's KEK + db via enrollmssignatures.
    ["modifynvram", "{{.Name}}", "enrollorclpk"],
    ["modifynvram", "{{.Name}}", "enrollmssignatures"],
    ["modifynvram", "{{.Name}}", "secureboot", "--enable"],
    ["modifyvm", "{{.Name}}", "--graphicscontroller", "vboxsvga"],
    ["storageattach", "{{.Name}}",
      "--storagectl", "SATA Controller",
      "--port", "2",
      "--type", "dvddrive",
    "--medium", "${var.virtio_iso_path}"],
  ]

  // ---------- Display ----------
  //
  // headless = false opens the VBox GUI window during the build. This
  // is a) useful for watching the install land, b) free since this
  // host has DISPLAY=:0 available, and c) doesn't have the
  // qemu-style RFB-keystroke timing pitfalls because VBox's input
  // pipeline is fundamentally different (no separate VNC server to
  // race against firmware init).
  headless = false

  // ---------- Boot timing ----------
  //
  // Simple. cdboot.efi's "Press any key" window is ~5 seconds wide;
  // VBox's input is ready well before then, so a 5s wait + single
  // <enter> reliably catches the prompt. (We tested boot_wait="1s"+
  // <enter> on qemu and that missed even with secboot OVMF — but
  // that was a qemu-RFB problem, not a wall-clock-too-tight problem.
  // VBox doesn't have the same race.)
  boot_wait    = "5s"
  boot_command = ["<enter>"]

  // ---------- WinRM for provisioners ----------
  //
  // VBox's NAT engine forwards the host port (auto-allocated by Packer)
  // to the guest's 5985, so once Autounattend's FirstLogonCommands
  // bring up WinRM, Packer connects via WinRM the same way it does on
  // the qemu source.
  communicator   = "winrm"
  winrm_username = var.build_username
  winrm_password = var.build_password
  winrm_timeout  = "60m"
  winrm_port     = 5985

  // ---------- Output ----------
  //
  // format = "ova" packages the resulting VM into an OVA, but for our
  // purposes the raw .vdi is more useful: that's what `qemu-img convert`
  // reads to produce the qcow2 we want for virt-manager.
  format               = "ovf"
  output_directory     = var.vbox_output_dir
  guest_additions_mode = "disable"

  // ---------- Shutdown ----------
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "15m"
}

// =============================================================================
// BUILD: shared provisioner pipeline for both sources
// =============================================================================

build {
  name = "windows-11-base"
  sources = [
    "source.proxmox-iso.windows-11-base",
    "source.virtualbox-iso.windows-11-base",
  ]

  // Wait for WinRM to settle before the first real provisioner runs.
  provisioner "powershell" {
    scripts = [
      "provision/00-wait-for-winrm.ps1",
    ]
  }

  // ===========================================================================
  // WINDOWS UPDATES: DISABLED BY DEFAULT.
  //
  // The two provisioner blocks below are commented out so a default
  // `./build-pve.sh pve12` finishes in ~15 minutes instead of 60-90. The cost
  // is that every template you build is unpatched as of the install ISO's
  // release date — clones inherit that patch level until something else
  // patches them.
  //
  // This is intentional, but only safe because the homelab applies patches
  // downstream of the template:
  //
  //   - Per-clone: a `runcmd:` block in the cloud-config snippet attached
  //     via `qm set --cicustom` can call PSWindowsUpdate, sconfig, or
  //     `usoclient StartScan && usoclient StartDownload && usoclient StartInstall`
  //     on first boot. See docs/cloning-templates.md.
  //   - Per-role: an Ansible playbook (or equivalent) targeting the clone
  //     after deploy. Same outcome, easier to schedule.
  //
  // To produce a fully-patched template at build time instead (~60-90 min):
  // uncomment BOTH the windows-update and windows-restart blocks below.
  // ===========================================================================
  //
  // provisioner "windows-update" {
  //   search_criteria = "IsInstalled=0"
  //   filters = [
  //     "exclude:$_.Title -like '*Preview*'",
  //     "exclude:$_.InstallationBehavior.CanRequestUserInput",
  //     "include:$true"
  //   ]
  //   update_limit = 25
  // }
  //
  // provisioner "windows-restart" {
  //   restart_timeout = "30m"
  // }

  // Main provisioner pipeline. elevated_user/elevated_password forces
  // Packer to invoke the script via a scheduled task running as that
  // account, which yields a fully-elevated UAC token. Without this,
  // DISM-style operations like Add-WindowsCapability / Disable-WindowsOptionalFeature
  // fail with "Access is denied" even when winrm_username is Administrator,
  // because the WinRM remote token is filtered (split-token UAC).
  provisioner "powershell" {
    elevated_user     = var.build_username
    elevated_password = var.build_password
    scripts = [
      "provision/10-install-virtio.ps1",
      "provision/15-windows-cleanup.ps1",
      "provision/20-harden.ps1",
      "provision/30-install-cloudbase-init.ps1",
    ]
  }

  // Sysprep generalize + shutdown. Must be the last step; Windows shuts down
  // when this completes and the next time the disk boots is on a clone.
  // Sysprep itself must run elevated.
  provisioner "powershell" {
    elevated_user     = var.build_username
    elevated_password = var.build_password
    scripts = [
      "provision/99-sysprep.ps1",
    ]
    // Sysprep terminates the WinRM session as part of generalize. Tell Packer
    // to expect a disconnect rather than failing.
    valid_exit_codes = [0]
  }
}
