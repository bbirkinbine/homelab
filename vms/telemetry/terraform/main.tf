# telemetry VM — provisioning shape only.
#
# Node-local (NVMe-backed local-lvm) service VM cloned from vms/_template/. Follows the
# canonical role shape (compare against vms/openbao/terraform/main.tf).
//
// What this file owns:
//   * Cloning the per-node Ubuntu 24.04 base template to the role's VM.
//   * Sizing (cores, memory, disk size, balloon).
//   * Cloud-init drive populated with identity data only.
//
// What this file deliberately does NOT own:
//   * Software install / config — that's the Ansible role under
//     vms/telemetry/ansible/roles/telemetry/.
//   * Operator ceremonies (first-time init, channel pairing, key
//     handling) — see vms/telemetry/README.md.

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

module "telemetry" {
  source = "../../../modules/proxmox-vm"

  name        = "telemetry"
  node_name   = var.proxmox_node
  template_id = local.ubuntu_template_ids[var.proxmox_node]
  vm_id       = 8035 // Service VMID range — see ADR-0008 (8030=openbao, 8031=rootca, 8032=openclaw, 8033=nemoclaw, 8034=hermes)

  // Sized to the telemetry stack's design: OTel Collector, VictoriaMetrics,
  // Loki and Tempo under Docker Compose.
  //   * cores      — 4. Four long-running stores/pipelines plus compaction
  //                  (Loki compactor, VictoriaMetrics merges) in parallel.
  //   * memory_mb  — 8 GiB. The Collector's memory_limiter alone is set to
  //                  1500 MiB; the three stores cache aggressively and the
  //                  rest goes to page cache for queries.
  //   * balloon    — 0. Fixed allocation so the stores' caches aren't
  //                  squeezed out from under them by the host.
  //   * disk_size  — 250 GiB, thin on local-lvm, so only written blocks
  //                  consume pool space. The data root (/srv/telemetry:
  //                  raw archive kept forever, landing zone never pruned,
  //                  5y metrics, 2y logs, 90d traces) shares the root
  //                  filesystem with the OS, so headroom here protects the
  //                  OS from a full disk. Grow-only: Proxmox can't shrink.
  cores        = 4
  memory_mb    = 8192
  balloon_mb   = 0
  disk_size_gb = 250

  // Storage knobs surfaced per role (see variables.tf "Storage" block).
  // This role defaults to local-lvm (node NVMe) + `local` snippets,
  // overriding the cluster-mobile nas-vms default — node-pinned.
  disk_storage     = var.disk_storage
  snippets_storage = var.snippets_storage

  // Pin the NIC MAC so the DHCP lease (and therefore the IP) survives any
  // tofu apply. Without a pin, bpg/proxmox auto-generates a fresh MAC on
  // NIC recreation, which churns the lease and breaks /etc/hosts + ARP
  // caches. The router's DHCP reservation for this VM is keyed on it.
  //
  // The value comes from var.nic_mac_address, set in the gitignored
  // terraform/nic.auto.tfvars rather than here: this repo is public and
  // a real MAC is LAN topology. See variables.tf for the capture command
  // and README.md "MAC pin" for the workflow.
  network_devices = [
    { bridge = "vmbr0", mac_address = var.nic_mac_address }
  ]

  tags = ["telemetry", "tofu"]

  // The cloud-init template lives in the role's cloud-init/ subfolder
  // (sibling of terraform/), so `${path.module}` resolves to
  // vms/telemetry/terraform/ and `..` jumps out to the role root.
  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    hostname       = "telemetry"
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
}
