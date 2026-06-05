# monitoring VM — Prometheus + Grafana stack for the homelab.
#
// Class A (cluster-mobile service VM) per docs/deploying-vms.md. The VM
// runs Prometheus, Grafana, prometheus-pve-exporter, and
// prometheus-pbs-exporter. node_exporter is installed on the monitoring
// VM itself by Ansible; node_exporter on the 3 PVE nodes + pbs01 is
// installed by vms/monitoring/ansible/install-node-exporter.yml — see
// vms/monitoring/README.md for the deploy + operator-ceremony flow.
//
// What this file owns:
//   * Cloning the per-node Ubuntu 24.04 base template to the VM.
//   * Sizing (cores, memory, disk size, balloon).
//   * Cloud-init drive populated with identity data only.
//
// What this file deliberately does NOT own:
//   * Software install / config — that's the Ansible role under
//     vms/monitoring/ansible/roles/monitoring/.
//   * The per-exporter API tokens — operator hand-pastes them on the VM
//     post-Ansible (matches openbao's first-init ceremony pattern).

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

module "monitoring" {
  source = "../../../modules/proxmox-vm"

  name        = "monitoring"
  node_name   = var.proxmox_node
  template_id = local.ubuntu_template_ids[var.proxmox_node]
  vm_id       = 8040 // ADR-0008 services range (8000–8099); deliberate gap above the claw cluster (8032/8033).

  // Sizing rationale:
  //   * cores=2        — Prometheus scrapes are sub-millisecond HTTP fetches; Grafana renders are bursty but light.
  //   * memory_mb=4096 — Prometheus + Grafana steady-state under 1 GiB combined; 4 GiB leaves headroom for a retention bump to 90d.
  //   * balloon_mb=1024 — monitoring tolerates ballooning (unlike openbao which mlocks). Allow the host to reclaim under pressure.
  //   * disk_size_gb=64 — 15-day TSDB at ~5 hosts × 15s scrape sits under 10 GB; 64 GB carries through a 90d retention bump.
  cores        = 2
  memory_mb    = 4096
  balloon_mb   = 1024
  disk_size_gb = 64

  // Storage knobs surfaced per role (see variables.tf "Storage" block).
  // Defaults to nas-vms for cluster-mobility — override to local-lvm
  // (or a dedicated pool like nuc12-fast) if this role is hardware-
  // pinned or has hard I/O-latency requirements.
  disk_storage     = var.disk_storage
  snippets_storage = var.snippets_storage

  tags = ["monitoring", "tofu"]

  // The cloud-init template lives in the role's cloud-init/ subfolder
  // (sibling of terraform/), so `${path.module}` resolves to
  // vms/monitoring/terraform/ and `..` jumps out to the role root.
  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    hostname       = "monitoring"
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
}
