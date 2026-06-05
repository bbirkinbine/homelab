# win-client — general-purpose Windows 11 host.
#
# Clones the per-node Windows 11 base template into a usable Win11 VM with a
# named local admin auto-injected on first boot via cloud-init (cloudbase-init).
# Uses the shared Windows module (modules/proxmox-vm-windows/); the Windows-
# specific hardware and the configdrive2 JSON meta-data live there. See
# vms/win-client/README.md for the operator runbook and the gotcha list.

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  // Self-signed Proxmox API until OpenBao PKI is wired up (lab convention).
  insecure = true

  // bpg uploads cloud-init snippets over SSH (not the HTTP API), so the
  // operator's ssh-agent key must be in root@<node>:authorized_keys.
  // scripts/preflight.sh verifies this before apply.
  ssh {
    agent    = true
    username = "root"
  }
}

locals {
  // Per-node Windows 11 base template VMIDs (ADR-0006 — VMIDs are cluster-wide
  // unique post-cluster, so one constant doesn't work). Parallel to the Ubuntu
  // 9100/9101/9102/9103 set; the convention extends +1 per node, so pve12t2 =
  // 9203. Build the target node's template before applying — see README.
  windows_template_ids = {
    pve12t  = 9200
    pve13m  = 9201
    pve13t  = 9202
    pve12t2 = 9203
  }
}

module "win_client" {
  source = "../../../modules/proxmox-vm-windows"

  name        = "win-client"
  node_name   = var.proxmox_node
  template_id = local.windows_template_ids[var.proxmox_node]
  vm_id       = 310 # workload range 100-399 (ADR-0008); confirm free cluster-wide before first apply

  cores        = var.cores
  memory_mb    = var.memory_mb
  disk_size_gb = var.disk_size_gb
  cpu_type     = var.cpu_type

  // Storage knobs surfaced per role (check-role-consistency.sh check 3).
  // Default is local-lvm + local to match the template (same-storage clone).
  // Flip both to nas-vms in terraform.tfvars for cluster-mobility.
  disk_storage     = var.disk_storage
  snippets_storage = var.snippets_storage

  network_devices = [{ bridge = var.vm_bridge }]

  tags = ["win-client", "tofu"]

  // First-boot account provisioning. cloudbase-init runs this #ps1_sysnative
  // PowerShell as SYSTEM: creates the admin, adds it to Administrators, enables
  // RDP. The password is injected base64-encoded so any generated symbol
  // survives templatefile + PowerShell quoting intact.
  user_data = templatefile("${path.module}/../cloud-init/user-data.ps1.tftpl", {
    admin_username     = var.win_admin_username
    admin_password_b64 = base64encode(var.win_admin_password)
  })
}
