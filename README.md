# homelab

Infrastructure-as-code for a small Proxmox VE homelab. Builds reproducible,
hardened VM templates (Ubuntu Server 24.04 LTS, Windows 11 Pro x64) that
serve as the universal parent images for downstream VMs across a 3-node
Proxmox cluster.

> ## Status
>
> Published as a personal-lab reference, not an actively maintained product.
> Issues and PRs welcome but won't get fast turnaround. The [`docs/`](docs/)
> tree (especially [docs/0-scratch-build-order.md](docs/0-scratch-build-order.md))
> and the per-component runbooks under [`packer/*/README.md`](packer/) and
> [`vms/*/README.md`](vms/) are the parts most likely to be useful to others.
>
> **This repo is in-flight.** Expect shape changes; pin a specific commit
> if you depend on a snapshot. Design rationale for non-obvious choices
> lives in [`docs/decisions/`](docs/decisions/) — start with the index.

## Hardware

### Proxmox nodes

| Node | Model | CPU | RAM | Notable peripherals |
| --- | --- | --- | --- | --- |
| `pve12t` | Intel NUC 12 Tall | i7-1260P (12th gen, 4P+8E / 16T) | 64 GiB | Thunderbolt eGPU enclosure with NVIDIA RTX 3090 (24 GB VRAM) |
| `pve13m` | Intel NUC 13 Pro Mini | i7-1360P (13th gen, 4P+8E / 16T) | 64 GiB | — |
| `pve13t` | ASUS NUC 13 Pro Tall | i7-13620H (13th gen, 6P+4E / 16T) | 64 GiB | — |

The three nodes form a 3-node Proxmox cluster (`homelab`) with corosync
ring0 on the 2.5GbE LAN and ring1 over a Thunderbolt line-topology
overlay for live-migration traffic. Users, tokens, and storage
definitions replicate cluster-wide via pmxcfs. VMs whose disks live on
cluster-shared NFS (`nas-vms` from the Asustor) live-migrate between
nodes; roles pinned to specific hardware (eGPU, USB-HSM) stay node-local.

### Backup target

| Host | Role |
| --- | --- |
| `pbs01` | GMKtec G3 Pro mini-PC running Proxmox Backup Server 4.x — dedicated backup target for the PVE cluster. Bulk datastore lives on NFS from the Asustor. Not part of the corosync cluster. |

Operator-side build hosts (macOS for `proxmox-iso` targets, T480 + Ubuntu for the Windows `virtualbox-iso` target) are described in the Tech stack table below — not lab infrastructure.

## Tech stack

| Layer | Tool | Notes |
| --- | --- | --- |
| Hypervisor | Proxmox VE 9.x | 3-node cluster (`pvecm`), corosync ring0 + ring1 |
| Shared storage | Asustor AS6706T (NFS) | `nas-vms` for cluster-mobile VM disks + snippets |
| VM templates | Packer + cloud-init / Autounattend | Ubuntu 24.04 LTS, Windows 11 Pro x64; hardened, sysprep'd |
| VM provisioning | OpenTofu + `bpg/proxmox` | Clones templates, attaches cloud-init drive, threads role config |
| VM configuration | Ansible | Per-role playbooks under `vms/<role>/ansible/` |
| Task runner | `just` | `just plan openbao`, `just apply openbao`, etc. |
| Host baseline | Ansible role `pve-host` | Brings a fresh PVE 9.x host to cluster-ready state |
| Backup target | Proxmox Backup Server 4.x | Dedicated mini-PC; see [`pbs-hosts/README.md`](pbs-hosts/README.md) for the layer-0 role + tiering shape |
| Bootstrap secrets | KeePassXC + YubiKey HMAC | `scripts/hydrate.sh` resolves `kp://` placeholders in `terraform.tfvars.tpl` at apply time |
| Runtime secrets | OpenBao (Shamir-sealed) | In-cluster KV / PKI store for service-to-service secrets; see [ADR-0002](docs/decisions/0002-openbao-seal-shamir-not-hsm.md) and [`vms/openbao/`](vms/openbao/README.md) |
| AI / LLM | Ollama | Local model serving on the [eGPU RTX 3090](docs/proxmox-gpu-passthrough.md) (24 GB VRAM) attached to `pve12t`; see [`vms/llm/`](vms/llm/README.md) |
| Observability | Prometheus + Grafana | Scrapes `node_exporter` (all hosts) + `prometheus-pve-exporter` (per-VM CPU/RAM/disk-IO) + natrontech `pbs-exporter` (backup health); see [`vms/monitoring/`](vms/monitoring/README.md) |
| Build hosts | macOS / Ubuntu | Mac drives all `proxmox-iso` builds; T480 drives the Windows `virtualbox-iso` target |
| Design rationale | ADRs in [`docs/decisions/`](docs/decisions/) | Append-only records for non-obvious choices |

## Where to look

- **Standing up the lab from bare metal?** [docs/0-scratch-build-order.md](docs/0-scratch-build-order.md) — master walkthrough across four phases.
- **Deploying a VM?** [docs/deploying-vms.md](docs/deploying-vms.md) — role-class chooser and repeatable flow.
- **Template builds?** [packer/ubuntu-24-04-base/README.md](packer/ubuntu-24-04-base/README.md) and [packer/windows-11-base/README.md](packer/windows-11-base/README.md).
- **Building a new role?** [vms/_template/](vms/_template/README.md) — scaffold to copy for a Linux role; [vms/openbao/](vms/openbao/README.md) is a fully-deployed example. For a **Windows host**, copy [vms/win-client/](vms/win-client/README.md) (it uses the [Windows module](modules/proxmox-vm-windows/README.md)).
- **Why we picked X?** [docs/decisions/](docs/decisions/) — read the index for the rationale trail.

## Acknowledgements

This project was developed with the assistance of AI tools.
