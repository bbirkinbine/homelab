# openbao VM — provisioning shape only.
#
// What this file owns:
//   * Cloning template 9100 (packer/ubuntu-24-04-base) to VM 130.
//   * Sizing (2 vCPU, 2 GiB RAM, 32 GiB disk, balloon disabled).
//   * Cloud-init drive populated with identity data only (hostname,
//     admin user, SSH key) — no software install.
//
// What this file deliberately does NOT own:
//   * OpenBao install. That's vms/openbao/ansible/.
//   * `bao operator init`. That's an operator ceremony, run by hand
//     against the running VM (5-share Shamir, custody in KeePassXC +
//     paper envelopes). See vms/openbao/README.md "First-init".
//
// Per the 2026-05-10 architecture decision, OpenBao seals with Shamir
// (no HSM). There is NO USB passthrough in this VM. The CardLogix
// HSM moved to the future Root CA VM — see vms/openbao/legacy/README.md
// for the history.

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  // Homelab convention: Proxmox API is self-signed until the PKI engine
  // in this VM produces real certs. Flip to false once that's wired up.
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
// Every Linux role copying from openbao should carry this same map.
locals {
  ubuntu_template_ids = {
    pve12t = 9100
    pve13m = 9101
    pve13t = 9102
  }
}

module "openbao" {
  source = "../../../modules/proxmox-vm"

  name        = "openbao"
  node_name   = var.proxmox_node
  template_id = local.ubuntu_template_ids[var.proxmox_node]
  vm_id       = 130

  // Sizing rationale (matches legacy .env defaults; Shamir-seal OpenBao
  // is a light service):
  //   * 2 vCPU — a few goroutines, KV store, audit log.
  //   * 2 GiB RAM — comfortable for an HA pair eventually.
  //   * 32 GiB disk — for /var/log growth + audit-log retention.
  //   * balloon=0 — OpenBao mlocks; ballooning would interfere.
  cores        = 2
  memory_mb    = 2048
  balloon_mb   = 0
  disk_size_gb = 32

  tags = ["openbao", "tofu"]

  // The cloud-init template lives in the role's cloud-init/ subfolder
  // (sibling of terraform/), so `${path.module}` resolves to
  // vms/openbao/terraform/ and `..` jumps out to the role root.
  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    hostname       = "openbao"
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
}
