# Shared Proxmox-VM module — provider + version pins.
#
// Pin to the bpg/proxmox provider's 0.x series. The `~> 0.66` constraint
// is "any version >= 0.66.0 and < 1.0.0" — chosen because (a) the
// migration plan in the vault was written against 0.66 and (b) the
// current head is 0.106.0, which satisfies this range. When 1.x lands,
// re-pin deliberately after reading the release notes for breaking
// changes; the provider has historically shifted attribute names
// between minor releases.
terraform {
  required_version = ">= 1.7"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}
