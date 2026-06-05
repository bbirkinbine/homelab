# Matches the Linux module's pin (modules/proxmox-vm/versions.tf). bpg's
# efi_disk / tpm_state / initialization blocks used here have been stable since
# well before 0.66; win-client was validated and applied on 0.108.
terraform {
  required_version = ">= 1.7"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}
