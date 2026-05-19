# openclaw VM — provisioning shape only.
#
// What this file owns:
//   * Cloning the per-node Ubuntu 24.04 base template (9100/9101/9102)
//     to VM 8032.
//   * Sizing (2 vCPU, 4 GiB RAM, 32 GiB disk, balloon disabled by
//     default — see below).
//   * Cloud-init drive populated with identity data only (hostname,
//     admin user, SSH key) — no software install.
//
// What this file deliberately does NOT own:
//   * Node.js install, openclaw npm install, systemd unit. That's
//     vms/openclaw/ansible/.
//   * `openclaw onboard` (channel pairing, model OAuth, daemon
//     registration). That's an operator ceremony — channel auth is
//     interactive (QR scans for WhatsApp/Telegram, OAuth flows for
//     Slack/Discord/Google Chat), so it cannot be automated. See
//     vms/openclaw/README.md "First-onboard ceremony".
//
// Role-class: cluster-mobile service VM (matches openbao). No host
// hardware passthrough, no irreplaceable on-host state — the daemon's
// state lives under /home/openclaw/.openclaw, which is portable across
// nodes once nas-vms NFS storage is wired into module defaults (see
// CLAUDE.md "Active context"). x86-64-v3 module default keeps the
// migration path open.

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
// role copying from openbao carries this same map; openclaw is no
// exception.
locals {
  ubuntu_template_ids = {
    pve12t = 9100
    pve13m = 9101
    pve13t = 9102
  }
}

module "openclaw" {
  source = "../../../modules/proxmox-vm"

  name        = "openclaw"
  node_name   = var.proxmox_node
  template_id = local.ubuntu_template_ids[var.proxmox_node]
  vm_id       = 8032 // Service VMID range — see ADR-0008 (8030=openbao, 8031=rootca)

  // Sizing rationale (matches upstream NemoClaw README "Recommended"
  // tier — 4+ vCPU / 16 GiB / 40 GiB free — applied uniformly to
  // both claw VMs so they compare cleanly against the same baseline.
  // Upstream OpenClaw doesn't publish a sizing matrix; borrowing
  // NemoClaw's is the closest documented anchor):
  //   * 4 vCPU — gateway is mostly an event loop, but headroom for
  //     concurrent agent sessions + sandboxed tool subprocesses
  //     (browser, headless chromium) is cheap. Drop to 2 if RAM/CPU
  //     is the gating constraint and you're not using local tools.
  //   * 16 GiB RAM — generous for a Node 24 daemon; tracks nemoclaw
  //     for symmetry rather than because upstream demands it.
  //   * 64 GiB disk — generous for the workspace (conversation
  //     history, skill bundles, downloads cache); 24 GiB over
  //     upstream NemoClaw's "40 GiB free" anchor leaves predictable
  //     headroom even if a future browser tool starts cacheing
  //     pages locally. Grow with `tofu apply` + `growpart` +
  //     `resize2fs` if it ever fills.
  //   * balloon=0 — Node's V8 heap responds poorly to memory pressure
  //     from the host (GC behavior diverges). Cheap insurance.
  cores        = 4
  memory_mb    = 16384
  balloon_mb   = 0
  disk_size_gb = 64

  tags = ["openclaw", "tofu"]

  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    hostname       = "openclaw"
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
}
