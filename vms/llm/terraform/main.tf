# llm VM — provisioning shape only.
#
// What this file owns:
//   * Cloning template 9100 (packer/ubuntu-24-04-base) to VM 120 on
//     pve12t.
//   * Sizing (6 vCPU, 32 GiB RAM, 300 GiB disk, balloon=0 — PCIe
//     passthrough requires pinned RAM).
//   * eGPU passthrough via the `rtx-3090` cluster-wide PCI mapping
//     (operator one-time setup; see vms/llm/README.md "PCI mapping").
//   * vga=std so noVNC works for GPU-passthrough debugging (the base
//     template ships serial0; we override here).
//   * cpu_type=host so the guest sees the actual silicon's AVX-512 and
//     other instruction extensions — important for any CPU fallback
//     path in Ollama / llama.cpp, even with the GPU doing inference.
//   * Cloud-init drive populated with identity data only.
//
// What this file deliberately does NOT own:
//   * NVIDIA driver, Docker, NVIDIA Container Toolkit, ufw, unattended-
//     upgrades. That's vms/llm/ansible/roles/llm/. Ported from the
//     legacy /usr/local/sbin/llm-provision.sh that used to run from
//     cloud-init runcmd; idempotent re-runs are now Ansible's job.
//   * Ollama install. Operator step post-role — see vms/llm/README.md
//     "Post-deploy" for the rationale (upstream installer's GPU detection
//     races the post-reboot kernel module init under automation).
//   * Cluster-side PCI mapping creation. Lives in /etc/pve/ (cluster
//     state); one-time pvesh / UI step. See README.
//   * Model pulling (`ollama pull`). Operator ceremony — see
//     vms/llm/README.md "Post-deploy".
//
// Role-class: hardware-pinned, NOT cluster-mobile. The eGPU is
// physically attached to pve12t via Thunderbolt; live migration would
// orphan the GPU passthrough. node_name therefore defaults to pve12t
// and template_id is hardcoded to 9100 (the pve12t Ubuntu base), NOT
// looked up via the cluster-wide map — see rootca for the same pattern.

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

module "llm" {
  source = "../../../modules/proxmox-vm"

  name        = "llm"
  node_name   = var.proxmox_node
  template_id = 9100 // pve12t-pinned (eGPU passthrough); template_id stays hardcoded to pve12t's Ubuntu base. Don't generalize to a node-keyed map — llm will never run on another node while the RTX 3090 is on this Thunderbolt enclosure.
  vm_id       = 120  // Workload VMID range — see ADR-0008 (amp-game=110)

  // Sizing rationale:
  //   * 6 vCPU — inference on a passthrough GPU barely uses CPU
  //     (tokenization, sampling, KV-cache bookkeeping, HTTP serving);
  //     6 of the host's 16 logical cores leaves headroom for Proxmox +
  //     other workloads. Bump if running CPU-fallback inference.
  //   * 32 GiB RAM — lets you mmap any model the 3090 can run (24 GB
  //     VRAM ceiling) plus headroom for OS, Docker, optional vector DB.
  //     Drop to 16 GiB if the host needs RAM elsewhere.
  //   * 300 GiB disk — models eat space (70B Q4 ~40 GB, plus quants
  //     you'll hoard). Lives on nuc12-fast (LVM-thin on pve12t's
  //     dedicated SATA SSD) so the NVMe local-lvm stays free for
  //     other VMs.
  //   * balloon=0 — REQUIRED for PCIe passthrough (host can't move
  //     pages out from under a DMA-capable device). The module's
  //     plan-time precondition enforces this when hostpci_devices is
  //     non-empty; explicit here for clarity.
  cores        = var.vm_cores
  memory_mb    = var.vm_memory_mb
  balloon_mb   = 0
  disk_size_gb = var.vm_disk_size_gb

  // Hardware-pinned storage:
  //   * disk_storage = nuc12-fast — LVM-thin on pve12t's dedicated 1TB
  //     SATA SSD, physically separate from the NVMe-backed `pve` VG.
  //     Models cache lives here so the NVMe stays free for cluster-
  //     mobile VMs. See CLAUDE.md "Storage exceptions that stay node-
  //     pinned" for the rationale.
  //   * snippets_storage = local — per-node, fine because the VM is
  //     pinned to pve12t and never live-migrates.
  disk_storage     = var.disk_storage
  snippets_storage = var.snippets_storage

  // cpu_type override: the module default is x86-64-v3 (cluster-mobile
  // baseline). llm is pve12t-pinned; using `host` exposes the actual
  // silicon (Alder Lake i7-1260P P-cores: AVX-512 via VNNI) so any
  // CPU fallback path in Ollama / llama.cpp runs at full speed.
  cpu_type = "host"

  // vga_type override: the module default is serial0 (matches the
  // Packer base's grub+console wiring). llm overrides to `std` so
  // Proxmox's noVNC console shows a framebuffer — essential for
  // debugging GPU passthrough boot issues (Code 43, vfio attach
  // failures, etc.). The serial socket stays attached, so `qm
  // terminal 120` still works alongside.
  vga_type = "std"

  // eGPU passthrough. References the cluster-wide PCI mapping named
  // by var.gpu_pci_mapping (default "rtx-3090"). Operator must create
  // the mapping once via Datacenter -> Resource Mappings -> PCI or
  // via `pvesh create /cluster/mapping/pci ...` — see README. Mapping
  // name decouples this config from the eGPU's physical PCI address,
  // which can shift after Razer Core X enclosure swaps or TB port
  // changes.
  hostpci_devices = [
    {
      mapping = var.gpu_pci_mapping
      pcie    = true  // RTX 3090 requires PCIe (legacy PCI doesn't work for modern GPUs)
      xvga    = false // headless inference — vga=std stays in effect for noVNC debugging
    },
  ]

  tags = ["llm", "gpu", "tofu"]

  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    hostname       = "llm"
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
}
