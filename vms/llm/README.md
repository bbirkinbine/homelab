# `vms/llm/` — local LLM serving on a passthrough NVIDIA GPU

VM for running local LLMs (Ollama, optionally Open WebUI as a chat front-end)
on an eGPU-passthrough RTX 3090 attached to `pve12t` via Thunderbolt
(Razer Core X enclosure). Cloned at deploy time from the
`ubuntu-24-04-base` Packer template; Ansible installs the OS-level
prereqs (NVIDIA server-branch driver, Docker, NVIDIA Container Toolkit,
ufw rules, unattended-upgrades) and reboots so the kernel module loads
cleanly. **Ollama itself is installed manually post-role** — same
prereq-only pattern as the openbao / openclaw / nemoclaw roles; see
[Post-deploy](#post-deploy) for the operator steps.

Hardware-pinned to `pve12t`. The Thunderbolt enclosure physically lives
on that node, and the eGPU's PCI mapping references `pve12t`; live
migration is not on the table. If the enclosure ever moves, both the
mapping and `var.proxmox_node` need to follow.

## Layout

```text
vms/llm/
├── README.md                  this file
├── terraform/                 OpenTofu workspace
│   ├── main.tf                provider + module call with hostpci_devices
│   ├── variables.tf           proxmox + sizing + storage + gpu_pci_mapping
│   ├── versions.tf            bpg/proxmox pin
│   ├── outputs.tf             vm_id, ipv4, mac, ansible_inventory_hint
│   ├── terraform.tfvars.tpl   kp:// placeholders (committed)
│   ├── terraform.tfvars.example   manual-fill alternative (committed)
│   ├── terraform.tfvars       resolved values (GITIGNORED)
│   ├── terraform.tfstate      local state (GITIGNORED, chmod 600)
│   └── .terraform.lock.hcl    provider lock (committed)
├── ansible/                   first-boot + ops configuration
│   ├── site.yml               top-level play
│   ├── requirements.yml       Galaxy collections
│   ├── inventory.yml.example  inventory shape (committed)
│   ├── inventory.yml          your IPs (GITIGNORED; written by `just inventory llm`)
│   └── roles/llm/
│       ├── defaults/main.yml  overridable vars (nvtop toggle, ufw ports, reboot toggle)
│       ├── tasks/main.yml     the actual work (driver, Docker, NCT, ufw, unattended-upgrades)
│       ├── handlers/main.yml  restart docker, reload ufw, reboot
│       ├── templates/         empty (.gitkeep)
│       ├── files/             empty (.gitkeep)
│       └── meta/main.yml      Galaxy metadata + collection deps
└── cloud-init/
    └── user-data.yaml.tftpl   identity-only (hostname, admin user, SSH key)
```

## Prerequisites

Things that must already be true before `just apply llm` will work:

1. **Workstation tooling.** `brew install opentofu just keepassxc ansible`.
   First-time setup in [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md).
2. **Packer base template.** VM `9100` (ubuntu-24-04-base) must exist
   on `pve12t`. If not: `packer/ubuntu-24-04-base/build-pve.sh pve12t`.
3. **`tofu@pve` API token.** See [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md).
   Token in KeePassXC at `Homelab/Tofu/proxmox-api-token`.
4. **SSH access to pve12t + key loaded into `ssh-agent`.**
   `ssh-copy-id root@pve12t`, then `ssh-add ~/.ssh/id_ed25519` once per
   shell session. The `bpg/proxmox` provider uploads cloud-init snippets
   over SSH (not the HTTP API). Preflight verifies both.
5. **Snippets storage enabled.** Datacenter → Storage → `local` → Edit
   → tick **Snippets**. Preflight reports a cure command if not.
6. **Host-side GPU passthrough configured on `pve12t`.** IOMMU enabled in
   BIOS, the GPU bound to `vfio-pci`, conflicting host drivers
   (`nouveau`, `nvidia`, `snd_hda_intel`) blacklisted. One-time per-host
   setup — full runbook in [`docs/proxmox-gpu-passthrough.md`](../../docs/proxmox-gpu-passthrough.md).
   Verify with `ssh root@pve12t 'lspci -nnk -s 3c:00 | grep "Kernel driver in use"'`
   — expected output `Kernel driver in use: vfio-pci`.
7. **Cluster-wide PCI mapping exists** — see next section.

### PCI mapping prereq (one-time per cluster)

The module's `hostpci_devices` input references a Proxmox **cluster-wide
PCI resource mapping** by name (NOT a raw PCI address — the raw form
requires root password auth, incompatible with API tokens, see
`modules/proxmox-vm/variables.tf`). The mapping itself lives in
`/etc/pve/` cluster state and is created once via:

**UI path** — Datacenter → Resource Mappings → PCI → Add. Name it
`rtx-3090` (or whatever you set `var.gpu_pci_mapping` to). On the
node-mapping list, add `pve12t` and tick both the GPU function (`.0`)
AND its companion HDMI-audio function (`.1`) — they share an IOMMU
group and Proxmox passes them together.

**CLI path** — `pvesh` from any cluster node:

```bash
ssh root@pve12t 'pvesh create /cluster/mapping/pci \
  --id rtx-3090 \
  --map "node=pve12t,path=0000:3c:00.0,iommugroup=14" \
  --map "node=pve12t,path=0000:3c:00.1,iommugroup=14"'
```

Find the correct PCI address with
`ssh root@pve12t 'lspci -nn | grep -i nvidia'`. The IOMMU group number
varies by host — `for d in /sys/kernel/iommu_groups/*/devices/*; do n=${d#*/iommu_groups/*}; n=${n%/*}; echo "$n ${d##*/}"; done | sort -n` lists every device by group.

If the eGPU enclosure or Thunderbolt port ever changes, update the
**mapping** (not `terraform.tfvars`) so the role config stays stable.

### Tofu token ACL on the mapping

The `tofu@pve` token needs `Mapping.Use` on this mapping path or
`just apply llm` 403s. The base `Tofu` role omits `Mapping.*` by
design — grant it scoped per-mapping:

```bash
ssh root@pve12t 'pveum aclmod /mapping/pci/rtx-3090 \
  -user tofu@pve -role PVEMappingUser'
```

Full rationale in [*Scoped ACLs for resource
mappings*](../../docs/proxmox-tofu-permissions.md#scoped-acls-for-resource-mappings).

## Deploy

From repo root:

```bash
just ansible-deps llm        # one-time per workstation
just hydrate llm             # render terraform.tfvars from KeePassXC
just check llm               # preflight (ssh, Proxmox API, template, snippets)
just plan llm                # review the plan
just apply llm               # create the VM
just inventory llm           # write ansible/inventory.yml from tofu output (waits on guest-agent)
just ansible llm             # install: NVIDIA driver, Docker, NCT, ufw (+ reboot)
```

End state: VM up, NVIDIA driver loaded, Docker + NVIDIA Container
Toolkit running, ufw allowing the LLM-stack ports. **Ollama is not
installed yet** — see Post-deploy step 2.

## Post-deploy

### 1. Confirm the GPU is visible inside the VM

```bash
ssh llm-admin@<vm-ip> nvidia-smi
```

Should show the 3090 with 24 GB VRAM and driver 595.x or newer. If it
reports "No devices were found", the most common cause is that the
post-driver reboot raced something — re-run the playbook
(`just ansible llm`) and check `dmesg | grep -i nvidia` on the VM.
**This must be working before step 2** — see the warning there.

### 2. Install Ollama

Ollama is installed manually, NOT via Ansible. The upstream installer
script (`curl | sh`) has a GPU-detection step that calls `nvidia-smi`
and falls through to installing `cuda-drivers` from NVIDIA's CUDA apt
repo if that call returns non-zero (e.g. transient race with the
post-reboot kernel module init). Those `cuda-drivers` packages conflict
with this role's `ubuntu-drivers --gpgpu` server-branch install and
break dpkg mid-transaction. From a non-interactive Ansible context this
race is hard to avoid; from an interactive operator session post-role
the kernel module is settled and `nvidia-smi` returns cleanly, so the
installer skips its CUDA branch correctly.

> **Confirm `nvidia-smi` from step 1 works before running the installer.**
> If it doesn't, the installer will pull conflicting `cuda-drivers` and
> wedge dpkg. Fix the driver / passthrough first.

```bash
ssh llm-admin@<vm-ip>
curl -fsSL https://ollama.com/install.sh | sh
```

This creates the `ollama` system user (home `/usr/share/ollama`), drops
`/etc/systemd/system/ollama.service`, and enables + starts the service
on port 11434 (loopback by default).

### 3. Expose Ollama to the LAN

By default Ollama listens on `127.0.0.1:11434`. To let Open WebUI on
the same host or other LAN clients reach it:

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
EOF
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

UFW already permits 11434 from the LAN (see the Ports table below).
**Don't expose this beyond LAN without an auth proxy** — the Ollama API
has no built-in authentication.

### 4. Smoke-test with a small model

Pull a small model to confirm end-to-end GPU inference:

```bash
ssh llm-admin@<vm-ip>
ollama pull llama3.2:3b           # ~2 GB
ollama run  llama3.2:3b "say hi"
```

In another SSH session, run `nvtop` during the response — GPU util
should spike and settle back to idle.

After the smoke test, pull whatever you actually want from the
[Ollama library](https://ollama.com/library). The 3090's 24 GB VRAM
fits up to ~70B at Q4 quant; bigger models spill to CPU and slow
dramatically.

### 5. (Optional) Run Open WebUI as a chat frontend

The role adds `llm-admin` to the `docker` group, but group membership
only takes effect on a NEW login session — if you're still in the SSH
session from step 4, `exit` and re-`ssh` before running the docker
command below. Otherwise `docker run` will fail with `permission denied
while trying to connect to the docker API`.

```bash
ssh llm-admin@<vm-ip>
docker run -d --restart unless-stopped \
  -p 8080:8080 \
  -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  --add-host=host.docker.internal:host-gateway \
  -v open-webui:/app/backend/data \
  --name open-webui \
  ghcr.io/open-webui/open-webui:main
```

Then open `http://<vm-ip>:8080` in a browser.

## Operations

### Find the VM's IP

DHCP lease, so the IP can change. Three ways to look it up:

```bash
# 1. qm guest cmd from your Mac (qemu-guest-agent is running in the template)
ssh root@pve12t 'qm guest cmd 120 network-get-interfaces' \
  | jq -r '.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"'

# 2. Tofu output (populated once the guest agent has reported)
just output llm | grep ipv4

# 3. Router DHCP lease table — look for hostname `llm`
```

To stop chasing it, pin a DHCP reservation on your router for the VM's
MAC (visible via `just output llm | grep mac`).

### Re-run the Ansible role

```bash
just ansible-check llm       # --check --diff: drift report, no changes applied
just ansible llm             # apply
```

The tasks are idempotent — apt installs use `state: present`, GPG keys
and apt sources use `creates:` guards. Re-running is safe; it won't
touch Ollama (that's a manual operator step — see Post-deploy).

### Bump the NVIDIA driver

The role pins to whatever `ubuntu-drivers install --gpgpu` picks as
"recommended" at first install. To pull a newer recommended driver
later:

```bash
ssh llm-admin@<vm-ip>
sudo apt update
sudo ubuntu-drivers install --gpgpu   # picks the new recommended version
sudo reboot                           # required to load the new module
```

To pin a specific version instead:

```bash
sudo apt install -y nvidia-driver-580-server
sudo reboot
```

### GPU reset / VM reboot quirks

The 3090 occasionally has trouble re-attaching to a VM after a hard
reboot (symptom: VM hangs at start, or `nvidia-smi` reports the GPU in
a bad state). In order of preference:

1. `qm shutdown 120` (graceful) instead of `qm stop` (hard).
2. If it still misbehaves, reboot `pve12t`. The eGPU gets fully
   re-enumerated and the Thunderbolt link comes back cleanly.

### Models cache backup (optional)

Models live under `/usr/share/ollama/.ollama/models` on the VM's
`nuc12-fast` boot disk. To survive a destroy+rebuild without
re-downloading, either:

- Pull models again after rebuild (fastest; bandwidth permitting).
- Copy the models dir off-box first and restore after.
- Move the models dir to a separate Proxmox disk and re-attach to
  the new VM (requires hand-editing the module call).

## Destroy and rebuild

> **WARNING.** Destroying this VM loses pulled models (unless you
> backed them up — see above) and any Open WebUI conversation history.
> Doesn't lose the host-side GPU passthrough setup or the cluster-wide
> PCI mapping — those persist on `pve12t` / `/etc/pve/`.

```bash
just destroy llm
just apply llm
just inventory llm
just ansible llm
# Then re-pull models per Post-deploy step 2.
```

## Sizing

| Resource | Value | Why |
| --- | --- | --- |
| vCPU | 6 | GPU-bound inference barely uses CPU; bump to 8-10 for CPU-fallback paths |
| RAM | 32 GiB | Models mmap-friendly (24 GB VRAM ceiling on 3090) + OS/Docker headroom |
| Disk | 300 GiB | OS + Docker + models (70B Q4 ~40 GB plus quants); on `nuc12-fast` |
| Balloon | 0 | **Required** for PCIe passthrough — RAM must be pinned for DMA |
| Machine | q35 | **Required** for PCIe (module default; the precondition enforces it) |
| CPU type | host | AVX-512 + VNNI for any CPU-fallback inference path |
| VGA | std | Framebuffer for noVNC debugging (overrides module's serial0 default) |

Defaults live in [`terraform/variables.tf`](terraform/variables.tf);
override per-deployment in `terraform.tfvars`.

## Ports

| Port | Protocol | Source | Purpose |
| --- | --- | --- | --- |
| 22 | tcp | LAN | SSH (allowed by base template) |
| 11434 | tcp | LAN | Ollama API |
| 8080 | tcp | LAN | Open WebUI (only when the container is running) |

UFW gates inside the VM. Perimeter firewall (router) is what gates
external access — **keep this VM LAN-only unless you front it with
auth.** The Ollama API has no built-in authentication.

## Files

- `terraform/` — OpenTofu workspace (provider + module call + tfvars).
- `ansible/roles/llm/` — installs the LLM stack idempotently.
- `cloud-init/user-data.yaml.tftpl` — identity-only first-boot config.
- `README.md` — this file.

## Related

- [`modules/proxmox-vm/`](../../modules/proxmox-vm/) — shared module;
  see its `hostpci_devices` variable for the passthrough plumbing.
- [`docs/proxmox-gpu-passthrough.md`](../../docs/proxmox-gpu-passthrough.md)
  — host-side IOMMU + vfio-pci binding (prereq for this role).
- [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md)
  — Proxmox API token setup.
- [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) — workstation
  flow (KeePassXC + hydrate + SSH).
- [`vms/rootca/`](../rootca/) — sibling hardware-pinned role (USB
  passthrough); cross-reference for the pinning pattern.
- [`CLAUDE.md`](../../CLAUDE.md) — "Storage exceptions that stay
  node-pinned" for the `nuc12-fast` pool rationale.
