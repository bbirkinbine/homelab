packer {
  required_version = ">= 1.10.0"

  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = ">= 1.2.0"
    }
    virtualbox = {
      source  = "github.com/hashicorp/virtualbox"
      version = ">= 1.0.0"
    }
    windows-update = {
      # Optional but useful — applies cumulative updates as a provisioner step.
      # Comment out the windows-update provisioner block in build {} if you don't want it.
      source  = "github.com/rgl/windows-update"
      version = ">= 0.16.0"
    }
  }
}
