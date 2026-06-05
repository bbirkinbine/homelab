# modules/proxmox-vm-windows

Clones the [Windows 11 base template](../../packer/windows-11-base/) into a VM
and attaches a cloud-init drive that `cloudbase-init` reads on first boot to set
the hostname and run a PowerShell user-data script (which creates the admin
account). The Windows counterpart to [`modules/proxmox-vm/`](../proxmox-vm/)
(Linux).

## Why a separate module (not knobs on the Linux module)

Windows guests differ in ways that are **fixed requirements**, not options, and
folding them into the Linux module — shared by 10 live callers, several of them
pet VMs — would mean adding ForceNew VM attributes to those pets (the risk class
behind the 2026-05-21 destructive incident). Keeping a separate module leaves
the battle-tested Linux module untouched. The Windows-specific choices baked in
here:

| Choice | Why |
| --- | --- |
| **JSON meta-data** | Proxmox defaults Windows guests (`ostype win*`) to `citype=configdrive2`; cloudbase-init `json.loads()` the meta-data. NoCloud YAML crashes it before any plugin runs. |
| **q35 + OVMF + TPM 2.0** | Win11 hardware requirements. |
| **SATA boot disk, no iothread** | Win11 24H2 WinPE ships `storahci.sys`, not `vioscsi`; iothread is invalid on SATA. |
| **cloud-init on `ide3`** | Matches the template's existing slot so bpg manages one drive, not two. |
| **virtio NIC** | Safe on the clone (drivers installed post-build); the template build itself used e1000e. |
| **`vga = std`** | Windows needs a framebuffer for the noVNC console (no serial console wired). |

## Inputs

The surface mirrors `modules/proxmox-vm/` (see [variables.tf](variables.tf) for
the full set with defaults). Required: `name`, `node_name`, `vm_id`,
`template_id`, `user_data`. Storage defaults to `local-lvm` (disk/EFI/TPM) +
`local` (snippets) to match the template; switch both to `nas-vms` for a
cluster-mobile host.

The caller's `provider "proxmox"` must set `ssh { agent = true; username = "root" }`
— bpg uploads the cloud-init snippets over SSH.

## Outputs

`vm_id`, `name`, `ipv4_addresses` — same shape as the Linux module.

## Consumers

- [`vms/win-client/`](../../vms/win-client/) — general-purpose Win11 host.

## Related

- [modules/proxmox-vm/](../proxmox-vm/) — the Linux module
- [vms/win-client/README.md](../../vms/win-client/README.md) — operator runbook + the full gotcha list
- [packer/windows-11-base/README.md](../../packer/windows-11-base/README.md) — building the base template
