# __ROLE__ VM — provisioning shape only.
#
# This file is a TEMPLATE. Search for `__ROLE__` and `# TODO:` markers to
# find every spot you need to customize for the real role. Once all
# placeholders are resolved, the file follows the canonical role shape
# (compare against vms/openbao/terraform/main.tf for a cluster-mobile
# reference, or vms/rootca/terraform/main.tf for the hardware-pinned
# variant — passthrough, conditional NIC, pinned node).
//
// What this file owns:
//   * Cloning the per-node Ubuntu 24.04 base template to the role's VM.
//   * Sizing (cores, memory, disk size, balloon).
//   * Cloud-init drive populated with identity data only.
//
// What this file deliberately does NOT own:
//   * Software install / config — that's the Ansible role under
//     vms/__ROLE__/ansible/roles/__ROLE__/.
//   * Operator ceremonies (first-time init, channel pairing, key
//     handling) — see vms/__ROLE__/README.md.

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  // Homelab convention: Proxmox API is self-signed until OpenBao's PKI
  // engine produces real certs. Flip to false once that's wired up.
  insecure = true

  // bpg/proxmox uses SSH (not the HTTP API) for cloud-init snippet
  // upload. The agent path means whatever ssh-agent the operator has
  // running at `tofu apply` time supplies the key; the workstation's
  // pubkey must already be in root@${var.proxmox_node}'s
  // authorized_keys. scripts/preflight.sh verifies this before apply.
  ssh {
    agent    = true
    username = "root"
  }
}

// Per-node Ubuntu base template VMIDs. The Packer build produces one
// template per cluster node (VMIDs are cluster-wide unique post-cluster,
// so a single constant VMID doesn't work). See ADR-0006 for the
// rationale and step 11 of docs/0-scratch-build-order.md for the build
// workflow. Every Linux role copying from openbao should carry this
// same map.
locals {
  ubuntu_template_ids = {
    pve12t  = 9100
    pve13m  = 9101
    pve13t  = 9102
    pve12t2 = 9103
  }
}

module "__ROLE__" {
  source = "../../../modules/proxmox-vm"

  name        = "__ROLE__"
  node_name   = var.proxmox_node
  template_id = local.ubuntu_template_ids[var.proxmox_node]
  vm_id       = 8099 # TODO: pick a unique VMID per ADR-0008 (services 8000-8099, workloads 100-399).

  // TODO: replace the sizing rationale below with notes specific to
  // this role's workload. Defaults shown here are deliberately modest
  // service-tier numbers — bump per the role's actual needs.
  //   * cores      — match the workload's concurrency model.
  //   * memory_mb  — leave headroom for OS + agent + service.
  //   * disk_size  — boot disk only; bulk data belongs on a separate
  //                  pool / NFS / Proxmox disk attached via the module.
  //   * balloon    — keep 0 for services that mlock or pin RAM
  //                  (OpenBao, anything with PCIe passthrough). Allow
  //                  ballooning for tolerant workloads.
  cores        = 2
  memory_mb    = 2048
  balloon_mb   = 0
  disk_size_gb = 32

  // Storage knobs surfaced per role (see variables.tf "Storage" block).
  // Defaults to nas-vms for cluster-mobility — override to local-lvm
  // (or a dedicated pool like nuc12-fast) if this role is hardware-
  // pinned or has hard I/O-latency requirements.
  disk_storage     = var.disk_storage
  snippets_storage = var.snippets_storage

  // Pin the NIC MAC so the DHCP lease (and therefore the IP) survives any
  // tofu apply. Without a pin, bpg/proxmox auto-generates a fresh MAC on
  // NIC recreation, which churns the lease and breaks /etc/hosts + ARP
  // caches. Two-step workflow for a new role:
  //   1. Leave this block commented out for the FIRST tofu apply — bpg
  //      will auto-generate a MAC and the VM will boot.
  //   2. After first apply, capture the assigned MAC and pin it:
  //        ssh <node> "qm config <vmid> | awk -F'=|,' '/^net0:/ {print \$2}'"
  //      Then uncomment the block, paste the captured value below, and
  //      re-run tofu apply (will be a no-op for the NIC).
  // network_devices = [
  //   { bridge = "vmbr0", mac_address = "BC:24:11:XX:XX:XX" }
  // ]

  tags = ["__ROLE__", "tofu"]

  // The cloud-init template lives in the role's cloud-init/ subfolder
  // (sibling of terraform/), so `${path.module}` resolves to
  // vms/__ROLE__/terraform/ and `..` jumps out to the role root.
  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    hostname       = "__ROLE__"
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
}
