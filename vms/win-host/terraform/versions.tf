# See modules/proxmox-vm/versions.tf for the rationale on the bpg pin.
#
# SPIKE NOTE: this workspace deliberately does NOT use modules/proxmox-vm
# (that module hardcodes a scsi0 + iothread Linux boot disk and declares no
# efi_disk / tpm_state, neither of which fits a Win11 clone). The spike drives
# a raw proxmox_virtual_environment_vm so we can learn exactly what bpg does
# with EFI/TPM/SATA on a Windows full-clone before we generalize the module
# in Phase 2. See ../SPIKE-NOTES.md.
terraform {
  required_version = ">= 1.7"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}
