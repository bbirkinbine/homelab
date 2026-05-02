# llm

VM for running local LLMs (Ollama + optional Open WebUI) on a passthrough
NVIDIA GPU. Cloned at deploy time from the `ubuntu-24-04-base` template;
cloud-init installs the NVIDIA driver, Docker, the NVIDIA container toolkit,
and Ollama, then reboots so the kernel module loads cleanly.

Designed for an RTX 3090 (24 GB VRAM) attached to a Proxmox node via
Thunderbolt eGPU, but works for any NVIDIA card the host has already bound
to `vfio-pci`.

## Prerequisites

Things that must already be true on the Proxmox node before `deploy.sh` will work:

1. **`ubuntu-24-04-base` template exists** (default ID `9100`).
   If not, run `packer/ubuntu-24-04-base/build.sh <node>` first.

2. **GPU passthrough is configured on the host** — IOMMU enabled, the
   GPU bound to `vfio-pci`, conflicting host drivers blacklisted. This
   is a one-time per-host setup; the full runbook is in
   [docs/proxmox-gpu-passthrough.md](../../docs/proxmox-gpu-passthrough.md).
   `deploy.sh` runs the verification check automatically and refuses to
   proceed if the device isn't bound to `vfio-pci`.

3. **Snippets content type enabled on the snippets storage.**
   Datacenter → Storage → `local` (or whichever you use) → Edit →
   under **Content**, check **Snippets**.

4. **SSH access from this Mac to the Proxmox node** as a user that can run
   `qm` and `pvesh` (typically `root`). Test with:
   ```
   ssh root@<proxmox-host> 'qm list | head'
   ```

5. **Target VM ID is free.** `deploy.sh` is fail-fast — it will refuse to
   touch an existing VM. Default ID is `120`; change in `.env` if it
   collides.

## Configuration

```
cp .env.example .env
# edit .env: set PROXMOX_HOST, SSH_PUBLIC_KEY, GPU_PCI_ADDRESS, confirm VM_ID
```

`.env` is gitignored.

To find the GPU's PCI address on the host:
```
ssh root@<proxmox-host> 'lspci -nn | grep -i nvidia'
# example output:
#   3c:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA102 [GeForce RTX 3090] [10de:2204] ...
#   3c:00.1 Audio device [0403]: NVIDIA Corporation GA102 High Definition Audio Controller [10de:1aef] ...
# pass the parent address: GPU_PCI_ADDRESS="3c:00"
```

## Deploy

```
./deploy.sh
```

Runs from your Mac, SSHes to the Proxmox node, and:

1. Verifies template `9100` exists, target `VM_ID` does not, and the GPU
   is bound to `vfio-pci`.
2. Resolves the snippets path on the node via `pvesh`.
3. Renders `cloud-init/user-data.yaml` with values from `.env`.
4. Uploads the rendered snippet to `<storage_path>/snippets/`.
5. `qm clone` (full) → `qm set` (cores/memory/balloon/machine/cpu/hostpci0)
   → `qm resize scsi0` → `qm set --cicustom + --ipconfig0 ip=dhcp` → `qm start`.

The first boot installs the driver stack and reboots automatically. Watch
progress on the serial console (`qm terminal <id>` on the node) or, once
the VM has an IP, tail `/var/log/llm-provision.log`.

## Post-deploy

Once the VM has rebooted and you can SSH in:

1. Find the VM's IP — see [Find the VM's IP](#find-the-vms-ip) below.

2. Confirm the GPU is visible:
   ```
   ssh llm-admin@<vm-ip> nvidia-smi
   ```
   You should see the 3090 with 24 GB VRAM and driver 570.x. If
   `nvidia-smi` reports "No devices were found", the most common cause
   is that the cloud-init reboot raced the driver build — re-run
   `sudo bash /usr/local/sbin/llm-provision.sh && sudo reboot` and check
   `/var/log/llm-provision.log`.

3. Pull a model and run it:
   ```
   ollama pull llama3.1:8b
   ollama run  llama3.1:8b
   ```
   Ollama listens on `0.0.0.0:11434`, so any LAN client can hit
   `http://<vm-ip>:11434` directly.

4. (Optional) Run Open WebUI as a chat frontend:
   ```
   docker run -d --restart unless-stopped \
     -p 8080:8080 \
     -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
     --add-host=host.docker.internal:host-gateway \
     -v open-webui:/app/backend/data \
     --name open-webui \
     ghcr.io/open-webui/open-webui:main
   ```
   Then open `http://<vm-ip>:8080`.

## Sizing

Default in `.env.example`:

| Resource | Value | Why |
|---|---|---|
| vCPU | 6 | Inference on a passthrough GPU barely uses CPU; 6 of the host's 16 logical cores is plenty and leaves the host healthy |
| RAM | 32 GiB | Lets you mmap any model the 3090 can run (24 GB VRAM ceiling) plus headroom for OS, Docker, vector DB, etc. Drop to 16 GiB on smaller hosts |
| Disk | 300 GB | Models eat space (70B Q4 ≈ 40 GB, plus quants you'll hoard) |
| Balloon | 0 | **Required** for PCIe passthrough — VM RAM must be pinned |
| Machine | q35 | Recommended for PCIe passthrough |
| CPU type | host | Needed for AVX2/AVX-512 paths and any CPU fallback to not be glacial |

Resize-able later via `qm` on the node — see [Operations](#operations).

## Ports

| Port | Protocol | Source | Purpose |
|---|---|---|---|
| 22 | tcp | LAN | SSH (allowed by base template) |
| 11434 | tcp | LAN | Ollama API |
| 8080 | tcp | LAN | Open WebUI (optional, if you run the container above) |

UFW is set inside the VM. Perimeter firewall (router) is what gates external
access — keep this VM LAN-only unless you front it with auth.

## Operations

### Find the VM's IP

DHCP lease, so the IP can change. Three ways to look it up:

**1. qm guest cmd from your Mac (works as long as qemu-guest-agent is running in the VM):**

```bash
ssh root@<proxmox-host> 'qm guest cmd 120 network-get-interfaces' \
  | grep -E '"ip-address" *: *"[0-9]+\.' \
  | grep -v '"127\.0\.0\.1"'
```

If `jq` is installed locally, this is cleaner:

```bash
ssh root@<proxmox-host> 'qm guest cmd 120 network-get-interfaces' \
  | jq -r '.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"'
```

**2. Proxmox Web UI:** open `https://<proxmox-host>:8006`, select VM `120` → Summary
tab.

**3. Router / DHCP server lease table:** look for hostname `llm`. Useful as a
fallback if qemu-guest-agent is broken or the VM hasn't booted far enough yet.

If you want to stop chasing the IP, set a DHCP reservation on your router for
the VM's MAC address (visible via `ssh root@<proxmox-host> 'qm config 120 | grep ^net0'`).

### Resize a running VM

`deploy.sh` will refuse to touch an existing VM. To change sizing on the
running deployment, ssh to the node:

```
qm set 120 --memory 49152 --cores 8
qm resize 120 scsi0 +200G
```

Memory and disk grow live; cores require a reboot to take effect.

### Re-run the provisioner

The cloud-init snippet runs once per `instance-id`. To re-run on next boot:

```
ssh llm-admin@<vm-ip> 'sudo cloud-init clean'
ssh root@<proxmox-host> 'qm reboot 120'
```

To just re-run the LLM stack install (without touching cloud-init's user/ufw
setup), the provision script is idempotent:

```
ssh llm-admin@<vm-ip> 'sudo bash /usr/local/sbin/llm-provision.sh'
```

### Bump the NVIDIA driver

Cloud-init runs `ubuntu-drivers install --gpgpu`, so the VM is on whatever
server-branch driver was current when it was first deployed. To pull a
newer recommended driver later:

```
ssh llm-admin@<vm-ip>
sudo apt update
sudo ubuntu-drivers install --gpgpu   # auto-picks the new recommended version
sudo reboot
```

To pin a specific version instead:

```
sudo apt install -y nvidia-driver-580-server  # or whatever branch you want
sudo reboot
```

### GPU reset / VM reboot quirks

The 3090 occasionally has trouble re-attaching to a VM after a hard reboot
(symptom: VM hangs at start, or `nvidia-smi` reports the GPU is in a bad
state). Workarounds, in order of preference:

1. `qm shutdown 120` (graceful) instead of `qm stop`.
2. If it still misbehaves, reboot the Proxmox host. The eGPU gets fully
   re-enumerated.

### Update the cloud-init snippet on the node

If you edit `cloud-init/user-data.yaml`, the change does NOT propagate to
the running VM automatically. Either re-deploy from scratch or manually
edit the file on the Proxmox node:

```
ssh root@<proxmox-host>
vi /var/lib/vz/snippets/vm-120-llm-user.yaml
qm reboot 120   # only if you want it to take effect now
```

### Destroy and rebuild

```
ssh root@<proxmox-host> 'qm stop 120 && qm destroy 120'
./deploy.sh
```

Pulled models live on the VM's disk, so destroying the VM loses them. If
you want them to survive a rebuild, store the Ollama model directory
(`/usr/share/ollama/.ollama/models`) on a separate Proxmox disk and
re-attach it to the new VM.

## Files

- `.env.example` — committed; documents required vars
- `.env` — gitignored; your real values
- `deploy.sh` — clone + size + GPU attach + start
- `cloud-init/user-data.yaml` — first-boot config (rendered before upload)
