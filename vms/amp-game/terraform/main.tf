# amp-game VM — provisioning shape only.
#
// What this file owns:
//   * Cloning the Ubuntu base template (per-node VMID per ADR-0006) to
//     VM 110 on `var.proxmox_node`.
//   * Sizing (default 4 vCPU, 12 GiB RAM, 100 GiB disk, balloon disabled).
//   * Cloud-init drive populated with identity data only (hostname,
//     admin user, SSH key) — no software install.
//
// What this file deliberately does NOT own:
//   * AMP installation. That's vms/amp-game/ansible/ (prerequisites
//     only) + the operator running `bash <(curl -fsSL https://getamp.sh)`
//     for the AMP-specific ceremony (license, dashboard, Standalone mode).
//   * Game-server config inside AMP. That's done via the AMP web UI
//     post-install.
//
// Per ADR-0008, amp-game lives at VMID 110 (workload range). Services
// like openbao (8030) and rootca (8031) are in the 8000-8099 range.
//
// Storage stays on local-lvm (NVMe), NOT nas-vms — game-server I/O
// latency is more important than cluster mobility for this workload.
// Default `proxmox_node = "pve13t"` (newest hardware).

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  // Homelab convention: Proxmox API is self-signed until the PKI engine
  // in OpenBao produces real certs. Flip to false once that's wired up.
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
// so a single constant VMID doesn't work). See ADR-0006 for the rationale
// and step 11 of docs/0-scratch-build-order.md for the build workflow.
// Every Linux role copying from openbao/amp-game should carry this same map.
locals {
  ubuntu_template_ids = {
    pve12t = 9100
    pve13m = 9101
    pve13t = 9102
  }
}

module "amp_game" {
  source = "../../../modules/proxmox-vm"

  name        = "amp-game"
  node_name   = var.proxmox_node
  template_id = local.ubuntu_template_ids[var.proxmox_node]
  vm_id       = 110 // Workload VMID range — see ADR-0008

  // Sizing rationale:
  //   * 4 vCPU default — Minecraft Java is single-threaded for tick
  //     handling but AMP itself + the JVM benefit from multiple cores.
  //     Bump to 6-8 for ARK / Rust / 7DTD or for multiple concurrent
  //     game instances.
  //   * 12 GiB RAM — covers a 6-8 GiB JVM heap for Minecraft + AMP
  //     overhead + headroom for system. Bump to 24-32 GiB for modded
  //     packs or multiple instances.
  //   * 100 GiB disk — AMP install + game installs + world growth +
  //     AMP backups. Game files balloon (modpacks, Steam games);
  //     consider 200+ GiB for a pure Steam-game host.
  //   * balloon=0 — game-server steady-state latency matters; ballooning
  //     would cause memory-pressure stalls during tick-heavy gameplay.
  //   * Storage = local-lvm (NVMe). Brian's explicit choice over nas-vms
  //     (NFS) — game-server I/O latency for world saves and player
  //     joins outweighs the cluster-mobility benefit of shared storage.
  cores            = var.vm_cores
  memory_mb        = var.vm_memory_mb
  balloon_mb       = 0
  disk_size_gb     = var.vm_disk_size_gb
  disk_storage     = var.disk_storage
  snippets_storage = var.snippets_storage

  tags = ["amp-game", "tofu"]

  // The cloud-init template lives in the role's cloud-init/ subfolder
  // (sibling of terraform/), so `${path.module}` resolves to
  // vms/amp-game/terraform/ and `..` jumps out to the role root.
  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    hostname       = "amp-game"
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
}
