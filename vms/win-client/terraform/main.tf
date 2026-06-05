# win-client SPIKE — clone the Windows 11 base template and inject a named
# admin account at first boot via cloudbase-init.
#
# This is Phase 1 of feat/windows-host: a deliberately raw, single-file
# workspace (NOT the shared module) whose only job is to answer the open
# questions in ../SPIKE-NOTES.md — does a bpg full-clone of a q35/OVMF/TPM
# Win11 template boot, and does a PowerShell user-data script create a
# working local admin. Once that's proven, Phase 2 folds the answers back
# into modules/proxmox-vm + a canonical role.

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  // Self-signed Proxmox API until OpenBao PKI is wired up (lab convention).
  insecure = true

  // bpg uploads cloud-init snippets over SSH (not the HTTP API), so the
  // operator's ssh-agent key must be in root@<node>:authorized_keys.
  // scripts/preflight.sh checks this before apply.
  ssh {
    agent    = true
    username = "root"
  }
}

locals {
  vm_name = "win-client"

  // Per-node Windows 11 base template VMIDs (ADR-0006 — VMIDs are cluster-
  // wide unique post-cluster, so one constant doesn't work). Parallel to the
  // Ubuntu 9100/9101/9102/9103 set; the convention extends +1 per node, so
  // pve12t2 = 9203. NOTE: as of 2026-06-05 NO Windows template is built on
  // ANY node yet — build the target node's template before applying (for
  // pve12t2: VM_ID=9203 ./build-pve.sh pve12t2). See ../SPIKE-NOTES.md.
  windows_template_ids = {
    pve12t  = 9200
    pve13m  = 9201
    pve13t  = 9202
    pve12t2 = 9203
  }
}

// ---------- cloud-init: PowerShell user-data (account provisioning) ----------
//
// cloudbase-init's UserDataPlugin runs this as SYSTEM on first boot. The
// `#ps1_sysnative` header is how cloudbase-init knows to execute it as 64-bit
// PowerShell rather than treat it as cloud-config YAML. This is the reliable
// account-creation path on Windows — cloudbase-init does NOT honor a Linux
// cloud-config `users:` block the way Ubuntu's cloud-init does.
resource "proxmox_virtual_environment_file" "user_data" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/../cloud-init/user-data.ps1.tftpl", {
      admin_username = var.win_admin_username
      // base64 so the password survives templatefile + PowerShell quoting
      // intact no matter which symbols KeePassXC generated (quotes, $, `).
      admin_password_b64 = base64encode(var.win_admin_password)
    })
    file_name = "vm-${var.vm_id}-${local.vm_name}-user.ps1"
  }
}

// Pinned cloud-init meta-data — same instance-id stability rationale as the
// shared module (see modules/proxmox-vm/main.tf): a fixed iid keeps
// cloudbase-init's "have I run on this instance before" state stable across
// reboots / live-migration so first-boot provisioning is genuinely once-only.
// cloudbase-init's SetHostNamePlugin reads `hostname` from the JSON below.
resource "proxmox_virtual_environment_file" "meta_data" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.proxmox_node

  source_raw {
    // JSON, NOT NoCloud YAML. Proxmox defaults Windows guests (ostype win*)
    // to citype=configdrive2, which presents the cloud-init drive as an
    // OpenStack ConfigDrive (label "config-2"). cloudbase-init's
    // ConfigDriveService does json.loads() on meta_data.json and reads
    // `uuid` as the instance-id. A YAML meta-data file makes it crash with
    // JSONDecodeError BEFORE any plugin runs — no hostname, no user-data, no
    // account (verified on VM 310, 2026-06-05). `uuid` pins the instance-id
    // (stable cloud-init state across reboots); `hostname` feeds
    // SetHostNamePlugin. The Linux module can stay YAML because Linux guests
    // default to citype=nocloud.
    data = jsonencode({
      uuid     = "iid-${local.vm_name}-${var.vm_id}"
      hostname = local.vm_name
    })
    file_name = "vm-${var.vm_id}-${local.vm_name}-meta.json"
  }
}

// ---------- the VM ----------
resource "proxmox_virtual_environment_vm" "this" {
  name      = local.vm_name
  vm_id     = var.vm_id
  node_name = var.proxmox_node
  tags      = ["win-client", "tofu", "spike"]

  // Win11 hardware gates. The template was built q35 + OVMF + TPM 2.0; we
  // restate them here so the clone's shape is explicit and any drift is
  // visible in the plan rather than silently inherited.
  machine = "q35"
  bios    = "ovmf"

  operating_system {
    type = "win11"
  }

  clone {
    vm_id   = local.windows_template_ids[var.proxmox_node]
    full    = true
    retries = 3
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  // No ballooning — keep it simple for the spike (and Win11's balloon driver
  // behavior is one less variable while we prove the clone boots).
  memory {
    dedicated = var.memory_mb
    floating  = var.memory_mb
  }

  // Boot disk on SATA (AHCI). The template's disk is SATA because Win11 24H2
  // WinPE ships storahci.sys but not vioscsi (see windows-11-base.pkr.hcl).
  // virtio-scsi drivers WERE installed into the template post-build, so a
  // future iteration can switch this to scsi0 + iothread for perf — but SATA
  // is the zero-risk first proof. NOTE: iothread is invalid on SATA, so it is
  // intentionally absent here.
  disk {
    datastore_id = var.disk_storage
    interface    = "sata0"
    size         = var.disk_size_gb
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  // Win11 requires a UEFI firmware disk and a TPM. On a full clone the
  // template already carries both; declaring them here lets bpg manage them
  // explicitly. Whether bpg reconciles cleanly vs. fighting the cloned
  // devices is the #1 thing this spike is verifying — see SPIKE-NOTES.md.
  efi_disk {
    datastore_id      = var.disk_storage
    type              = "4m"
    pre_enrolled_keys = false // matches the template's efi_config
  }

  tpm_state {
    datastore_id = var.disk_storage
    version      = "v2.0"
  }

  vga {
    type = "std"
  }

  // qemu-guest-agent ships in the template (and 10-install-virtio.ps1
  // registered the virtio drivers it needs). Enabling it lets bpg read the
  // clone's DHCP IPv4 back for the outputs.
  agent {
    enabled = true
    trim    = false
    type    = "virtio"
  }

  // virtio NIC — safe on the CLONE (drivers installed post-build), unlike the
  // e1000e the template BUILD needed during driverless WinPE/OOBE.
  network_device {
    bridge = var.vm_bridge
    model  = "virtio"
  }

  // interface = "ide3" matches the slot the Packer template already uses for
  // its cloud-init drive (verified on template 9203: `ide3: ...vm-9203-
  // cloudinit,media=cdrom`). Matching it makes bpg manage that ONE drive on
  // clone; declaring a different slot (e.g. ide2) would leave the inherited
  // ide3 drive in place and create a SECOND cloud-init drive, which
  // cloudbase-init could read instead of ours.
  initialization {
    datastore_id      = var.disk_storage
    interface         = "ide3"
    user_data_file_id = proxmox_virtual_environment_file.user_data.id
    meta_data_file_id = proxmox_virtual_environment_file.meta_data.id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  lifecycle {
    // meta_data_file_id is ForceNew in bpg — same rationale as the shared
    // module. Ignoring it makes the attribute a create-time-only concern.
    ignore_changes = [
      initialization[0].meta_data_file_id,
    ]
    // NOTE: prevent_destroy is intentionally OMITTED for the spike so this
    // disposable VM can be torn down and recreated freely while iterating.
    // The canonical Phase-2 role re-adds prevent_destroy (ADR-0009 pets).
  }
}
