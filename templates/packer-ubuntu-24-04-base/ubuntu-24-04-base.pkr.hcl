// =============================================================================
// ubuntu-24-04-base.pkr.hcl
//
// Builds a hardened Ubuntu Server 24.04 LTS (Noble) VM template on Proxmox VE
// using the proxmox-iso builder. The output is the universal parent template
// for every downstream homelab VM role.
//
// See ../../Packer Ubuntu-24.04 Base Image for Proxmox NUCs.md for design
// context.
// =============================================================================

source "proxmox-iso" "ubuntu-24-04-base" {

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
  template_description = "Ubuntu 24.04 LTS hardened base, packer-built ${formatdate("YYYY-MM-DD", timestamp())}"

  // ---------- VM hardware ----------
  cores           = var.vm_cores
  memory          = var.vm_memory
  cpu_type        = "host"
  os              = "l26"
  scsi_controller = "virtio-scsi-single"

  disks {
    type         = "scsi"
    storage_pool = var.vm_storage_pool
    disk_size    = var.vm_disk_size
    format       = "raw"
    cache_mode   = "writeback"
    discard      = true
    ssd          = true
    io_thread    = true
  }

  network_adapters {
    model    = "virtio"
    bridge   = var.vm_bridge
    vlan_tag = var.vlan_tag
    firewall = false
  }

  // Serial console for headless install + debugging
  serials = ["socket"]
  vga {
    type   = "serial0"
    memory = 16
  }

  qemu_agent = true

  // ---------- ISO source ----------
  // Use existing ISO if iso_file is set; otherwise have Proxmox download it
  // into iso_storage_pool.
  boot_iso {
    type             = "scsi"
    iso_file         = var.iso_file != "" ? var.iso_file : null
    iso_url          = var.iso_file == "" ? var.iso_url : null
    iso_checksum     = var.iso_file == "" ? var.iso_checksum : null
    iso_storage_pool = var.iso_storage_pool
    unmount          = true
    iso_download_pve = var.iso_file == "" ? true : false
  }

  // ---------- Boot command (Ubuntu 24.04 autoinstall via GRUB) ----------
  // - http_directory serves user-data + meta-data to the installer.
  // - 'c' drops into GRUB command-line mode (skipping the 30s menu).
  // - 'autoinstall ds=...' tells subiquity to fetch cloud-init data from
  //   our HTTP server.
  // - The ';' inside the ds= value must be escaped from the shell layer of
  //   the kernel cmdline parser, hence the inner double-quotes.
  http_directory = "http"

  boot_wait = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=\"nocloud-net;s=http://{{.HTTPIP}}:{{.HTTPPort}}/\"<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  // ---------- SSH for provisioners ----------
  // Autoinstall creates 'packer' user with the password below (hash in
  // http/user-data must match var.build_password). Provisioners use sudo
  // NOPASSWD (configured by autoinstall late-commands). Cleanup script wipes
  // this user before the template is finalized.
  ssh_username = var.build_username
  ssh_password = var.build_password
  ssh_timeout  = "60m" // autoinstall + first reboot can take 25-40 min on a slow network
  ssh_pty      = true

  // Shutdown is driven by Proxmox itself. With qemu_agent = true above and
  // the agent installed via autoinstall, Proxmox issues a graceful guest-
  // agent shutdown; otherwise it falls back to ACPI. Either is fine for a
  // clean template.

  // Add a cloud-init drive so clones get cloud-init by default.
  cloud_init              = true
  cloud_init_storage_pool = var.vm_storage_pool
}

// =============================================================================
// build block — provisioners
// =============================================================================

build {
  name    = "ubuntu-24-04-base"
  sources = ["source.proxmox-iso.ubuntu-24-04-base"]

  provisioner "shell" {
    execute_command = "echo '${var.build_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    scripts = [
      "provision/00-wait-for-cloud-init.sh",
      "provision/10-base-packages.sh",
      "provision/15-ubuntu-cleanup.sh",
      "provision/20-harden.sh",
      "provision/30-cloud-init-config.sh",
      "provision/99-cleanup.sh",
    ]
    expect_disconnect = true
  }
}
