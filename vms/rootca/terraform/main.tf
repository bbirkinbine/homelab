# Offline Root CA VM — provisioning shape only.
#
// What this file owns:
//   * Cloning template 9100 (packer/ubuntu-24-04-base) to VM 110 on
//     pve12t.
//   * 40 GiB disk on standard `local-lvm` (no host-side encryption —
//     the Ansible role carves a LUKS partition on the back half of
//     this disk at /var/lib/rootca-encrypted for ceremony artifacts).
//   * USB passthrough of the HSM-A physical jack (bus-port 1-2) for
//     the CardLogix SmartCard-HSM 4K.
//   * Conditional NIC: present during bootstrap (enable_network=true)
//     for the one-shot Ansible run, then removed (enable_network=false)
//     to enforce permanent air-gap.
//   * Cloud-init drive populated with identity-only user-data.
//
// What this file deliberately does NOT own:
//   * HSM software install (pcscd, opensc, sc-hsm-embedded, openssl
//     pkcs11 provider). That's vms/rootca/ansible/.
//   * In-VM LUKS partition setup (cryptsetup luksFormat, mkfs, crypttab
//     + fstab with `noauto`, rootca-unlock / rootca-lock helpers).
//     Also vms/rootca/ansible/ — the operator pastes the LUKS
//     passphrase during the first `just ansible rootca` run.
//   * Root CA key generation, DKEK wrap to HSM-B, Intermediate CSR
//     signing. Operator ceremonies — see the canonical vault doc
//     `CardLogix as Offline Root CA.md` and the role README.
//   * `on_boot=true`. This VM does NOT auto-start on host boot —
//     operator decides when to power it up for a ceremony, and the
//     in-VM ceremony partition stays locked until the operator runs
//     `rootca-unlock` at the noVNC console.

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  // Same insecure self-signed posture as openbao; flip once OpenBao's
  // PKI engine produces real certs and the Proxmox UI is fronted by
  // one.
  insecure = true

  ssh {
    agent    = true
    username = "root"
  }
}

module "rootca" {
  source = "../../../modules/proxmox-vm"

  name        = "rootca"
  node_name   = var.proxmox_node
  template_id = 9100 // pve12t-pinned (HSM USB passthrough); template_id stays hardcoded to pve12t's Ubuntu base. Don't generalize to a node-keyed map — rootca will never run on another node.
  vm_id       = 8031 // Service VMID range — see ADR-0008

  // Sizing rationale (per the vault's "Operational VM setup" specs in
  // `CardLogix HSM Receipt Validation and VM Setup`):
  //   * 2 vCPU — HSM is the bottleneck, not the CPU.
  //   * 4 GiB RAM — comfortable for openssl + pkcs11-provider during
  //     ceremonies; small enough that snapshots / backups stay manageable.
  //   * 40 GiB disk — ~8 GiB for the standard Packer 9100 base; the
  //     remainder is partitioned by the Ansible role into a LUKS volume
  //     at /var/lib/rootca-encrypted for ceremony artifacts. Bumped
  //     from 32 GiB on 2026-05-11 with the host-side → in-VM LUKS move.
  cores        = 2
  memory_mb    = 4096
  balloon_mb   = 0
  disk_size_gb = var.disk_size_gb
  disk_storage = var.disk_storage
  // cpu_type omitted — inherits the module's x86-64-v3 default. AES-NI
  // is present on Alder/Raptor Lake; this VM stays pve12t-pinned via
  // USB passthrough but x86-64-v3 keeps the migration path open if the
  // HSM ever moves to a different node.

  // Snippet storage stays on `local` (not on the disk storage above).
  // The cloud-init snippet contains only hostname / admin user / SSH
  // pubkey — identity-only, never the LUKS passphrase.
  snippets_storage = var.snippets_storage

  // Default to powered-off + manual start. The ceremony procedure
  // (vms/rootca/README.md § "Ceremony procedure") starts the VM only
  // when an operator is sitting at the noVNC console with the LUKS
  // passphrase ready. Auto-start on host boot is wrong for an offline
  // CA — even though the encrypted partition is `noauto` and would
  // stay locked, an unattended-up VM with HSM passthrough live is a
  // larger attack surface than necessary.
  started = false
  on_boot = false

  tags = ["rootca", "offline", "tofu"]

  // Air-gap toggle. See variables.tf — bootstrap with true, run
  // Ansible, then flip to false and tofu apply again. Empty list
  // removes the NIC declaratively per bpg/proxmox upstream guidance.
  network_devices = var.enable_network ? [{ bridge = "vmbr0" }] : []

  // USB passthrough — labeled HSM-A jack on the Proxmox host.
  usb_passthrough = {
    host = var.hsm_usb_host_port
    usb3 = var.hsm_usb3
  }

  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    hostname       = "rootca"
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
}
