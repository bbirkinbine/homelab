# nemoclaw VM — provisioning shape only.
#
// What this file owns:
//   * Cloning the per-node Ubuntu 24.04 base template (9100/9101/9102)
//     to VM 8033.
//   * Sizing (4 vCPU, 16 GiB RAM, 64 GiB disk, balloon disabled).
//   * Cloud-init drive populated with identity data only (hostname,
//     admin user, SSH key) — no software install.
//
// What this file deliberately does NOT own:
//   * Docker install, Node install, service-user setup,
//     docker-group membership, linger, ufw rules. That's
//     vms/nemoclaw/ansible/.
//   * The nemoclaw binary install (upstream's curl|bash, npm-global,
//     etc.). The role stops at prereqs; the operator runs upstream's
//     installer. See vms/nemoclaw/README.md "Install nemoclaw".
//   * `nemoclaw onboard` (sandbox creation, model-provider auth,
//     channel pairing). That's an operator ceremony — see
//     vms/nemoclaw/README.md "First-onboard ceremony".
//   * NVIDIA Endpoints API key custody. Lives in KeePassXC + provided
//     by the operator at onboard time; never committed.
//
// Role-class: cluster-mobile service VM. Sized heavier than openclaw
// because the NemoClaw stack is (Docker + k3s + OpenShell gateway +
// OpenClaw inside a sandbox) instead of (Node + openclaw binary). No
// GPU passthrough — inference defaults to NVIDIA's cloud Endpoints
// API; local Ollama would need a hardware-pinned variant of this role.

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  // Same insecure self-signed posture as the other roles — flip once
  // OpenBao's PKI engine fronts the Proxmox UI.
  insecure = true

  ssh {
    agent    = true
    username = "root"
  }
}

// Per-node Ubuntu base template VMIDs — see ADR-0006. Every Linux
// role copying from openbao carries this same map.
locals {
  ubuntu_template_ids = {
    pve12t = 9100
    pve13m = 9101
    pve13t = 9102
  }
}

module "nemoclaw" {
  source = "../../../modules/proxmox-vm"

  name        = "nemoclaw"
  node_name   = var.proxmox_node
  template_id = local.ubuntu_template_ids[var.proxmox_node]
  vm_id       = 8033 // Service VMID range — see ADR-0008 (8030=openbao, 8031=rootca, 8032=openclaw)

  // Sizing rationale (upstream NemoClaw README "Recommended":
  // 4+ vCPU / 16 GiB / 40 GiB free):
  //   * 4 vCPU — Docker daemon + k3s control-plane + OpenShell
  //     gateway + sandbox container all share the box; 2 cores
  //     starves k3s under load.
  //   * 16 GiB RAM — sandbox image is ~2.4 GiB compressed and the
  //     gateway + k3s + Docker combine to push past 8 GiB during
  //     image push (per upstream's OOM warning). 16 GiB is upstream's
  //     "Recommended" tier; 8 GiB is the documented minimum if RAM
  //     becomes the gating constraint.
  //   * 64 GiB disk — upstream's "40 GiB free" recommendation refers
  //     to free space after the OS + container runtime install. On
  //     the VM, Ubuntu base + Docker + k3s + sandbox image cache eat
  //     ~20-25 GiB; 64 GiB total leaves ~40 GiB free at idle, matching
  //     upstream's "free" tier in practice. Cluster has plenty of
  //     spare disk so the extra headroom is free insurance against
  //     heavy image push or additional sandbox images.
  //   * balloon=0 — Docker + k3s + Node behave badly under host
  //     memory pressure; the gateway needs predictable headroom for
  //     sandbox spawns and image pulls.
  cores        = 4
  memory_mb    = 16384
  balloon_mb   = 0
  disk_size_gb = 64

  disk_storage     = var.disk_storage
  snippets_storage = var.snippets_storage

  tags = ["nemoclaw", "tofu"]

  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    hostname       = "nemoclaw"
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
}
