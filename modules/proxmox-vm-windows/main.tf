# Shared Windows-VM module: clones the Windows 11 base template, sizes it, and
# attaches a cloud-init drive that cloudbase-init reads on first boot to set the
# hostname and create the admin account.
#
# Why this exists separately from modules/proxmox-vm/ (the Linux module):
# Windows guests differ in ways that are fixed requirements, not knobs —
//
//   * Proxmox defaults Windows guests (ostype win*) to citype=configdrive2, so
//     the cloud-init meta-data MUST be JSON (cloudbase-init json.loads it). A
//     NoCloud YAML meta-data file crashes cloudbase-init before any plugin runs.
//   * Win11 requires UEFI (OVMF) + a TPM 2.0 + q35.
//   * The boot disk is SATA (Win11 24H2 WinPE ships storahci.sys but not
//     vioscsi); iothread is invalid on SATA.
//   * The base template's cloud-init drive sits on ide3 — matching it keeps bpg
//     managing one drive instead of creating a second.
//   * Account creation is a #ps1_sysnative PowerShell user-data script, not a
//     cloud-config users: list.
//
// Folding all of that into the Linux module (shared by 10 live callers) would
// mean adding ForceNew VM attributes to pet VMs — the risk class behind the
// 2026-05-21 destructive incident. A separate module keeps that module pristine.

# Upload the rendered PowerShell user-data. bpg uploads over SSH (not the HTTP
# API), so the caller's provider must set ssh { agent = true; username = "root" }.
resource "proxmox_virtual_environment_file" "user_data" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.node_name

  source_raw {
    data      = var.user_data
    file_name = "vm-${var.vm_id}-${var.name}-user.ps1"
  }
}

# Pinned cloud-init meta-data, as JSON (configdrive2 — see header). cloudbase-
# init reads `uuid` as the instance-id and `hostname` for SetHostNamePlugin.
# Pinning the uuid to iid-<name>-<vmid> keeps cloud-init's "have I run on this
# instance" state stable across reboots/migration so first-boot provisioning is
# a once-only event (same rationale as the Linux module's meta-data pin).
resource "proxmox_virtual_environment_file" "meta_data" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.node_name

  source_raw {
    data = jsonencode({
      uuid     = "iid-${var.name}-${var.vm_id}"
      hostname = var.name
    })
    file_name = "vm-${var.vm_id}-${var.name}-meta.json"
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  vm_id     = var.vm_id
  node_name = var.node_name
  tags      = var.tags
  started   = var.started
  on_boot   = var.on_boot

  // Win11 hardware gates (fixed, not knobs).
  machine = "q35"
  bios    = "ovmf"

  operating_system {
    type = "win11"
  }

  // Full clone so the template can be deleted without orphaning dependents and
  // so the disk lands in the caller's disk_storage pool.
  clone {
    vm_id   = var.template_id
    full    = true
    retries = 3
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  // floating == dedicated (balloon_mb = 0) disables ballooning.
  memory {
    dedicated = var.memory_mb
    floating  = var.balloon_mb == 0 ? var.memory_mb : var.balloon_mb
  }

  // Boot disk on SATA (AHCI) — see header. iothread is intentionally absent
  // (invalid on SATA). The virtio-scsi drivers ARE registered in the template,
  // so a future variant could switch to scsi0 + iothread for perf.
  disk {
    datastore_id = var.disk_storage
    interface    = "sata0"
    size         = var.disk_size_gb
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  // UEFI var store + TPM. On a full clone the template carries both; declaring
  // them keeps bpg managing them on the same storage as the boot disk.
  efi_disk {
    datastore_id      = var.disk_storage
    type              = "4m"
    pre_enrolled_keys = false
  }

  tpm_state {
    datastore_id = var.disk_storage
    version      = "v2.0"
  }

  vga {
    type = var.vga_type
  }

  // qemu-guest-agent ships in the template; enabling it lets bpg read the
  // clone's DHCP IPv4 back into ipv4_addresses for the outputs/inventory.
  agent {
    enabled = true
    trim    = false
    type    = "virtio"
  }

  dynamic "network_device" {
    for_each = var.network_devices
    content {
      bridge      = network_device.value.bridge
      model       = network_device.value.model
      firewall    = network_device.value.firewall
      mac_address = network_device.value.mac_address
      vlan_id     = network_device.value.vlan_id
    }
  }

  // cloud-init drive on ide3 to match the template's existing slot (see header).
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
    // Pet protection (ADR-0009): refuse plan-time destroys so a bpg ForceNew
    // change (e.g. meta_data_file_id) fails loudly instead of silently
    // recreating the VM. A deliberate rebuild removes this line in its own PR.
    prevent_destroy = true

    // meta_data_file_id is ForceNew in bpg. Ignoring drift makes it a
    // create-time-only concern; existing VMs are migrated out-of-band via
    // `qm set --cicustom` if the pinned meta ever needs to change.
    ignore_changes = [
      initialization[0].meta_data_file_id,
    ]
  }
}
