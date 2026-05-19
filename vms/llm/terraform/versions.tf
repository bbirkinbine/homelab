# See modules/proxmox-vm/versions.tf for the rationale on the 0.66 pin.
terraform {
  required_version = ">= 1.7"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}
