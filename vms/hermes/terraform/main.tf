# hermes VM — provisioning shape only.
#
// What this file owns:
//   * Cloning the per-node Ubuntu 24.04 base template (9100/9101/9102)
//     to VM 8034.
//   * Sizing (4 vCPU, 16 GiB RAM, 64 GiB disk, balloon disabled).
//   * Cloud-init drive populated with identity data only (hostname,
//     admin user, SSH key) — no software install.
//
// What this file deliberately does NOT own:
//   * System prereqs (ripgrep, ffmpeg, git, build tools, service user,
//     ufw, optional NOPASSWD sudo). That's vms/hermes/ansible/.
//   * The hermes-agent install (curl|bash, which bootstraps uv +
//     Python 3.11 + a Node tarball into ~/.hermes/ itself). The role
//     stops at prereqs so the operator runs upstream's installer
//     manually — see vms/hermes/README.md "Install hermes-agent".
//   * `hermes setup` / `hermes model` / `hermes gateway setup`
//     ceremonies — interactive provider auth + (optional) channel
//     pairing for Telegram/Discord/Slack/etc. cannot be automated.
//     See vms/hermes/README.md "First-setup ceremony".
//
// Role-class: cluster-mobile service VM (matches openclaw / nemoclaw).
// No host hardware passthrough, no irreplaceable on-host state — the
// agent's state lives under /home/hermes/.hermes. With the role's
// default disk_storage = "nas-vms" (see variables.tf "Storage"), a
// freshly applied hermes is portable across cluster nodes. No
// pre-flip storage pin — hermes is deployed AFTER nas-vms became the
// role default, so the first apply lands on nas-vms directly.
// x86-64-v3 module default keeps the migration path open.

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

// Per-node Ubuntu base template VMIDs — see ADR-0006. Every Linux
// role copying from openbao carries this same map; hermes is no
// exception.
locals {
  ubuntu_template_ids = {
    pve12t = 9100
    pve13m = 9101
    pve13t = 9102
  }
}

module "hermes" {
  source = "../../../modules/proxmox-vm"

  name        = "hermes"
  node_name   = var.proxmox_node
  template_id = local.ubuntu_template_ids[var.proxmox_node]
  vm_id       = 8034 // Service VMID range — see ADR-0008 (8030=openbao, 8031=rootca, 8032=openclaw, 8033=nemoclaw)

  // Sizing rationale (tracks openclaw / nemoclaw for cross-agent
  // comparability — Hermes Agent is in the same "personal AI agent +
  // optional messaging gateway" class as both claws, and upstream
  // publishes no hard sizing matrix beyond "runs on a $5 VPS"):
  //   * 4 vCPU — agent is mostly I/O-bound (HTTPS to LLM providers,
  //     optional Playwright browser tool). Headroom for parallel
  //     skill subprocesses + ffmpeg transcodes (image_cache /
  //     audio_cache live under ~/.hermes/).
  //   * 16 GiB RAM — generous. The Python 3.11 venv + the bundled
  //     Node.js + an optional Playwright/Chromium browser tool all
  //     want headroom; matches openclaw / nemoclaw so the three
  //     agent VMs compare cleanly against the same baseline.
  //   * 64 GiB disk — boot + ~/.hermes/ (sessions / logs / cron +
  //     image_cache + audio_cache) + the hermes-agent git checkout +
  //     venv + ~/.hermes/node/ (~120 MB Node tarball). 64 GiB leaves
  //     predictable headroom even with a Playwright browser install
  //     (~400 MB).
  //   * balloon=0 — same Node V8 / Python GC pressure rationale as
  //     the claws; cheap insurance against host-side memory pressure
  //     surprising the agent runtime.
  cores        = 4
  memory_mb    = 16384
  balloon_mb   = 0
  disk_size_gb = 64

  // Storage knobs surfaced per role (see variables.tf "Storage" block).
  // Defaults to nas-vms for cluster-mobility — override to local-lvm
  // (or a dedicated pool) only if a hermes deployment grows a hard
  // I/O-latency requirement.
  disk_storage     = var.disk_storage
  snippets_storage = var.snippets_storage

  tags = ["hermes", "tofu"]

  // The cloud-init template lives in the role's cloud-init/ subfolder
  // (sibling of terraform/), so `${path.module}` resolves to
  // vms/hermes/terraform/ and `..` jumps out to the role root.
  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    hostname       = "hermes"
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
}
