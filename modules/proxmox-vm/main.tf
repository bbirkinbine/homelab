# Shared Proxmox-VM module: clones a template VM, sizes it, and
# attaches a cloud-init snippets file rendered by the caller.
#
// Two resources only:
//   1. proxmox_virtual_environment_file — uploads the caller's rendered
//      user-data YAML to the node's snippets storage. bpg/proxmox does
//      the upload over SSH (not the HTTP API), so the provider must
//      have `ssh { agent = true; username = "root" }` configured at the
//      caller — see vms/openbao/terraform/main.tf for the pattern.
//   2. proxmox_virtual_environment_vm — clones the template, sizes it,
//      and references the snippet from `initialization.user_data_file_id`.
//
// What this module deliberately does NOT do:
//   - No init/destroy provisioners. Configuration management is
//     Ansible's job; this module owns only the VM shape.
//   - No cluster-side PCI mapping creation. `hostpci_devices`
//     references a cluster-wide mapping by name; the mapping itself
//     is a one-time bring-up step (see variables.tf "PCIe / GPU
//     passthrough" comment for the pvesh / UI flow).

resource "proxmox_virtual_environment_file" "user_data" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.node_name

  source_raw {
    data      = var.user_data
    file_name = "vm-${var.vm_id}-${var.name}-user.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  vm_id     = var.vm_id
  node_name = var.node_name
  tags      = var.tags
  machine   = var.machine
  started   = var.started
  on_boot   = var.on_boot

  // Full clone (not linked) because we want to be able to delete the
  // template without orphaning every dependent VM, and we want the
  // clone's disk to live in the caller-specified `disk_storage` pool
  // rather than wherever the template's backing store is.
  clone {
    vm_id   = var.template_id
    full    = true
    retries = 3
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  // Setting `floating` equal to `dedicated` when balloon_mb=0 disables
  // ballooning (Proxmox semantics: floating==dedicated means no
  // ballooning). When balloon_mb > 0, that becomes the floor and the
  // VM can balloon between balloon_mb and dedicated.
  memory {
    dedicated = var.memory_mb
    floating  = var.balloon_mb == 0 ? var.memory_mb : var.balloon_mb
  }

  disk {
    datastore_id = var.disk_storage
    interface    = "scsi0"
    size         = var.disk_size_gb
    file_format  = "raw"
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  vga {
    type = var.vga_type
  }

  // qemu-guest-agent ships in the Packer base template. Enable it here
  // so the provider can read the VM's DHCP-assigned IPv4 back into the
  // `ipv4_addresses` attribute (-> module output -> Ansible inventory).
  agent {
    enabled = true
    trim    = false
    type    = "virtio"
  }

  // NICs. Default produces one virtio NIC on vmbr0 (matches the Packer
  // base's net0 inheritance). Pass `network_devices = []` from the
  // caller to remove the NIC entirely — used by air-gapped roles after
  // their one-shot Ansible bootstrap. The cloud-init initialization
  // block below still works without a NIC (cloud-init reads from the
  // attached drive, no DHCP request needed), but the VM will get no
  // IP since ip_config below requests DHCP — for air-gapped roles,
  // the ip_config is harmless (no NIC means no request).
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

  // USB passthrough. Pinned by host bus-port (e.g. host="1-2"), NOT
  // by VID:PID — CardLogix HSM tokens enumerate identically and the
  // labeled physical jack is the contract. Default null = no
  // passthrough (openbao, k3s nodes). Used by the Root CA role.
  dynamic "usb" {
    for_each = var.usb_passthrough == null ? [] : [var.usb_passthrough]
    content {
      host = usb.value.host
      usb3 = usb.value.usb3
    }
  }

  // PCIe / GPU passthrough. Devices are referenced by Proxmox cluster-
  // wide PCI resource mapping name (set up once via Datacenter →
  // Resource Mappings → PCI or via pvesh — see variables.tf comment).
  // Default [] = no passthrough. The `device` attribute is auto-assigned
  // from the list index (hostpci0, hostpci1, ...). Used by the LLM role
  // (eGPU passthrough).
  dynamic "hostpci" {
    for_each = var.hostpci_devices
    content {
      device  = "hostpci${hostpci.key}"
      mapping = hostpci.value.mapping
      pcie    = hostpci.value.pcie
      xvga    = hostpci.value.xvga
      mdev    = hostpci.value.mdev
      rombar  = hostpci.value.rombar
    }
  }

  // Cross-variable preconditions for PCIe passthrough — fail at plan
  // time with a useful message instead of a confusing runtime / boot
  // failure. Both constraints come from Proxmox's hardware requirements:
  //   * RAM must be pinned (balloon disabled) — the host can't move
  //     pages out from under a device with DMA access.
  //   * The PCIe topology only exists in q35 — i440fx exposes legacy PCI.
  lifecycle {
    precondition {
      condition     = length(var.hostpci_devices) == 0 || var.balloon_mb == 0
      error_message = "PCIe passthrough (hostpci_devices) requires balloon_mb = 0 — pinned RAM is mandatory for devices with DMA access."
    }
    precondition {
      condition     = length(var.hostpci_devices) == 0 || var.machine == "q35"
      error_message = "PCIe passthrough (hostpci_devices) requires machine = \"q35\" — i440fx exposes only legacy PCI."
    }
  }

  // The Packer base seals a cloud-init drive into the template at
  // build time. On clone, Proxmox inherits that drive at the first
  // free IDE slot but does NOT regenerate its contents from a new
  // cicustom config. With the bpg provider, declaring `initialization
  // {}` here causes the provider to create a fresh cloud-init drive
  // with the right user-data — no manual detach/recreate dance like
  // the legacy shell deploy.sh had to do. If you ever see a stale
  // drive at ide0 surviving the clone, drop a `lifecycle` block
  // that ignore_changes on it, but as of bpg 0.106 the provider
  // handles the recreate cleanly.
  initialization {
    datastore_id      = var.disk_storage
    interface         = "ide2"
    user_data_file_id = proxmox_virtual_environment_file.user_data.id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
}
