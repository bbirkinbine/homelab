# Proxmox GPU passthrough (NVIDIA, including Thunderbolt eGPUs)

Host-side setup required before a Proxmox VM can take over an NVIDIA
GPU via PCIe passthrough. This is the prerequisite for
[`vms/llm/`](../vms/llm/) and any future GPU-bearing role.

The setup is per-host and one-time. The worked example throughout is
`pve12`'s deployed config (Intel NUC i7-1260P with a TB4 port, Razer
Core X TB3 eGPU enclosure, NVIDIA RTX 3090); the recipe applies to
any internal NVIDIA card on any node, with the
[Thunderbolt-specific notes](#thunderbolt-egpu-specifics) only
mattering for an eGPU.

## Precondition

If using a Thunderbolt eGPU, **the enclosure must be powered on and
connected before every host boot.** Hot-plugging an eGPU after the
host is up does not reliably bind through to a VM (more in
[Thunderbolt eGPU specifics](#thunderbolt-egpu-specifics)).

## 1. BIOS / UEFI

Enable in firmware (NUC: F2 at boot):

- **VT-d** — Intel's IOMMU; required.
- **VT-x** — Intel virtualization; required for KVM regardless of GPU.
- **Thunderbolt Security Level → No Security (SL0)** — simplest for a
  homelab. Higher levels (SL1/SL2) require explicit enrollment of the
  enclosure via `boltctl` and silently block the PCIe tunnel until
  you do; if `lspci` doesn't see the GPU after boot, this is the first
  thing to check.
- **Primary Display → iGPU / Internal** — keeps the host booting on
  the Iris Xe and never touching the 3090.
- **Above 4G Decoding → Enabled** — required for the 3090's large BAR
  (24 GB VRAM > 4 GB MMIO window). Boards default this off.
- **Resizable BAR → Enabled** — optional; the 3090 benefits from it.
- **Allow Thunderbolt Boot** — leave default.

NUC BIOSes hide some under "Advanced" / "PCI" / "Boot Configuration".
If the host won't POST after enabling them, clear CMOS and try one at
a time.

## 2. Kernel cmdline (IOMMU on)

Edit `/etc/default/grub` and append to `GRUB_CMDLINE_LINUX_DEFAULT`:

```text
intel_iommu=on iommu=pt
```

Final line on `pve12`:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
```

(AMD hosts: `amd_iommu=on iommu=pt`.) `iommu=pt` (passthrough mode)
skips DMA translation for devices the host itself uses, keeping host
I/O fast — only devices owned by `vfio-pci` go through the IOMMU.

Do **not** add `pcie_acs_override=...` yet; only add it if step 5
shows the GPU sharing an IOMMU group with unrelated devices.

```bash
update-grub
```

## 3. VFIO modules

Have the host load the vfio module stack at boot:

```bash
cat >> /etc/modules <<'EOF'
vfio
vfio_iommu_type1
vfio_pci
EOF
```

Note: `vfio_virqfd` was merged into `vfio-pci` in kernel 5.16+. Do
not add it — it no longer exists as a separate module on PVE 8/9.

## 4. Blacklist host-side NVIDIA / nouveau drivers

If `nouveau` or any `nvidia*` module loads at boot it grabs the GPU
first. Proxmox can detach it at VM start, but the detach is racy and
occasionally fails on Thunderbolt-attached cards. Blacklist all four
current NVIDIA modules plus `nouveau` — leaving any out lets the
others get pulled in indirectly:

```bash
cat > /etc/modprobe.d/blacklist-nvidia.conf <<'EOF'
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidiafb
EOF
```

Do **not** blacklist `snd_hda_intel` — that's the host's general
Intel HDA audio driver, not specific to the GPU's HDMI-audio
function. Proxmox unbinds the GPU's audio function at VM start on
its own.

Reboot:

```bash
update-initramfs -u -k all
reboot
```

The blacklist must be in the initramfs so it takes effect *before*
the root filesystem mounts and before any in-kernel NVIDIA driver
gets a chance to probe the GPU. Skipping `update-initramfs` is the
single most common reason "I followed the guide but it doesn't work."

## 5. Verify IOMMU + find the GPU

```bash
dmesg | grep -e DMAR -e IOMMU | head
# Expect: "DMAR: IOMMU enabled" and Intel VT-d init lines

lspci -nn | grep -iE 'nvidia|vga'
# Expect two NVIDIA entries — VGA and Audio, same bus:dev:
# 3c:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA102 [GeForce RTX 3090] [10de:2204] ...
# 3c:00.1 Audio device [0403]: NVIDIA Corporation GA102 ... [10de:1aef] ...
```

Record the bus address (e.g. `3c:00`) and the two vendor:device IDs
(`10de:2204,10de:1aef`). The bus address varies by which Thunderbolt
root port the enclosure enumerates under and which kernel/firmware
revision is running — use **your** address everywhere `3c:00`
appears below.

If `lspci` doesn't show the 3090, see [Troubleshooting](#troubleshooting).

## 6. Check IOMMU groups — decide on ACS override

```bash
for d in /sys/kernel/iommu_groups/*/devices/*; do
  n=${d#*/iommu_groups/*}; n=${n%%/*};
  printf 'IOMMU Group %s ' "$n"; lspci -nns "${d##*/}";
done | sort -V
```

Find the group containing your 3090.

- **Group contains only the 3090's VGA + audio function** → done with
  groups, skip the ACS override.
- **Group contains other devices you can't pass through** (chipset
  bridge, the TB controller itself, an unrelated NIC, etc.) → add
  the ACS override:

  ```bash
  # Only if the group actually needs to be split. Edit /etc/default/grub:
  GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt pcie_acs_override=downstream,multifunction"
  update-grub && reboot
  # Re-run the group check above; the 3090 should now be isolated.
  ```

ACS override weakens PCI isolation in software. Fine for a homelab,
not for production multi-tenant. Only apply if you actually need it.

## 7. Bind the GPU to vfio-pci at boot

Replace the IDs with what `lspci -nn` returned for your card.

```bash
cat > /etc/modprobe.d/vfio.conf <<'EOF'
options vfio-pci ids=10de:2204,10de:1aef disable_vga=1
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidia_drm pre: vfio-pci
softdep nvidia_modeset pre: vfio-pci
EOF

update-initramfs -u -k all
reboot
```

What each piece does:

- `options vfio-pci ids=...` — at module load, `vfio-pci` claims those
  PCI vendor:device IDs. Cleanest binding when no other host device
  shares those IDs (the 3090's GPU + audio function don't collide
  with anything on a NUC).
- `disable_vga=1` — tells `vfio-pci` not to attempt VGA-arbitration
  emulation. Right for headless inference; the VM doesn't use the
  GPU as its primary display.
- `softdep <driver> pre: vfio-pci` — additional safety. If something
  ever causes one of the NVIDIA modules to load, `vfio-pci` loads
  first so the bind race can't go the wrong way.

In principle Proxmox can also bind `vfio-pci` on demand at VM start
via the `driver_override` interface even without this file. In
practice the deterministic boot-time binding above is what `pve12`
uses, what the canonical Proxmox/Arch wiki recipes recommend, and
what avoids "device busy" races at VM start — especially for
Thunderbolt eGPUs.

## 8. Verify VFIO binding

```bash
lspci -nnk -s 3c:00
# For both 3c:00.0 (VGA) and 3c:00.1 (audio), expect:
#   Kernel driver in use: vfio-pci
#   Kernel modules: nouveau, nvidia (or similar)
```

The "Kernel modules" line lists modules that *could* claim the
device; the "Kernel driver in use" line is the one that *actually
did*. Only the latter matters — it must say `vfio-pci`.

If it says `nouveau` or `nvidia*`, the blacklist or initramfs update
didn't take. Re-check `/etc/modprobe.d/blacklist-nvidia.conf` and
re-run `update-initramfs -u -k all`.

## Per-VM attach

Once the host is set up, each VM that wants the GPU sets `hostpci0`
and a few related flags:

```bash
qm set <vm-id> --hostpci0 <bus:dev>,pcie=1
qm set <vm-id> --machine q35 --cpu host --balloon 0
```

Required:

- `pcie=1` — expose as a PCIe device.
- `q35` machine type — proper PCIe topology.
- `host` CPU type — exposes all CPU features the NVIDIA driver
  wants.
- `--balloon 0` — passthrough requires the VM's RAM to be pinned.

Optional:

- `x-vga=1` — set only if the GPU is the VM's primary display
  (workstation/gaming, not headless inference).

OVMF (UEFI) firmware is recommended for the VM and required for
Windows guests (older NVIDIA Windows drivers refuse to load under
SeaBIOS — Code 43). Linux guests work under SeaBIOS too, which is
what `vms/llm/` currently uses (it clones from the SeaBIOS-built
[`packer/ubuntu-24-04-base/`](../packer/ubuntu-24-04-base/) template).

### Oddity: Proxmox shows memory pegged at 100%

Expected for any VM with `balloon: 0`. Proxmox's "memory used" metric
in the web UI is reported by the **memory balloon driver** inside the
guest. With ballooning disabled (which passthrough requires), the
host has no signal for how much of the allocation the guest is
actually using, so Proxmox falls back to "what's pinned to QEMU" =
the full allocation = 100%.

The truth is inside the VM: `free -h`, `htop`, or the system-RAM bar
in `nvtop` all show real usage. For capacity planning on this homelab,
just assume passthrough VMs always consume their full allocation on
the host — there's no overcommit benefit anyway, since the IOMMU maps
fixed host pages directly into the guest's PCI device address space
and they can't move.

`qemu-guest-agent` (which we run with `agent: 1`) *could* report
accurate memory, but Proxmox's web UI doesn't use it for the memory
metric — only for IP/ping/fsfreeze. No clean fix without a custom
dashboard.

[`vms/llm/deploy.sh`](../vms/llm/deploy.sh) does all of the per-VM
setup automatically and refuses to proceed if any prerequisite is
missing.

## Thunderbolt eGPU specifics

Thunderbolt PCIe enumeration happens *during* host boot, not before
it. Consequences:

1. **The eGPU must be powered on and connected when the host boots.**
   Hot-plugging an eGPU after host boot puts it on the bus but is
   error-prone — Proxmox doesn't always cleanly bind a late-arriving
   passthrough device when the VM later starts. Boot order:
   enclosure on → cable connected → power on the host.

2. **Don't suspend the eGPU enclosure.** Some enclosures (Razer Core
   especially) drop the link when the host suspends. After resume
   the PCI device may re-enumerate at a different bus address,
   breaking any VM config that hardcoded the old one. Either disable
   host suspend or reboot after each disconnect.

3. **PCI bus address may or may not change between TB ports.**
   Conventional wisdom says each Thunderbolt port is its own PCIe
   root port, so the same enclosure plugged into TB1 vs TB2 should
   land on a different `bus:dev`. In practice it depends on the
   SoC's TB topology — the i7-1260P NUC in `pve12` keeps the eGPU
   at the same `3c:00` address on both ports (verified by moving
   the cable). Other hosts/CPUs may not. After any physical change
   (port swap, enclosure swap, host reboot), run
   `lspci -nn | grep -i nvidia` and confirm `GPU_PCI_ADDRESS` in
   `vms/llm/.env` still matches. `deploy.sh` rejects mismatched
   addresses early; for an already-deployed VM, edit
   `/etc/pve/qemu-server/<vm-id>.conf`'s `hostpci0` line and
   reboot the VM.

4. **Link speed ceiling: PCIe 3.0 x4.** Thunderbolt 3/4 tunnels PCIe
   at 4 lanes max; you cannot get x16 over Thunderbolt regardless
   of the card. `nvidia-smi -q | grep "GPU Link Info" -A 4` inside
   the guest will report `8 GT/s x4` — not a bug, that's the TB
   ceiling. The 3090 still inferences at ~85–90% of native for LLM
   workloads.

5. **Resets are flakier than internal PCIe.** The 3090 supports FLR
   (function-level reset) cleanly on PCIe slots, but over Thunderbolt
   the symptom (VM hangs at start, or `nvidia-smi` reports a bad
   state inside the guest) is more frequent. Workarounds:
   `qm shutdown` instead of `qm stop`; reboot the host if the GPU
   gets stuck.

## Troubleshooting

**`lspci` doesn't see the 3090 on the host after boot.**
Thunderbolt link didn't come up. Check, in order:

1. Razer Core X is powered on and the cable is firmly connected.
2. Cable is TB3/TB4-rated, not a plain USB-C charging cable. USB-C
   charging cables silently fall back to USB-only mode and the GPU
   never enumerates.
3. You're using one of the rear TB4 ports. Front USB-C ports on the
   NUC are typically USB-only.
4. TB Security Level isn't blocking the PCIe tunnel:

   ```bash
   apt install -y bolt
   boltctl list
   # If status: unknown / authflags: none, the device isn't authorized.
   cat /sys/bus/thunderbolt/devices/domain0/security
   # "user" = SL1, "none" = SL0
   ```

   Fix by dropping BIOS to **SL0** (simplest) or by enrolling:

   ```bash
   systemctl enable --now bolt
   boltctl enroll --policy auto <uuid-from-boltctl-list>
   ```

   Reboot and re-check `lspci -nn | grep -i nvidia`.

**`lspci` shows the GPU but `Kernel driver in use` is `nouveau` (or `nvidia`).**
The blacklist or initramfs update didn't take. Re-check:

```bash
cat /etc/modprobe.d/blacklist-nvidia.conf
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'vfio|nvidia'
```

Re-run `update-initramfs -u -k all` and reboot.

**Link shows `2.5 GT/s x1` instead of `8 GT/s x4`.**
USB-C port without TB4 wiring, or non-TB cable. See "doesn't see
the 3090" above — same root cause.

**GPU shares an IOMMU group with chipset / root port / NIC.**
Some boards have lazy IOMMU grouping. Workarounds in order of
preference:

1. **Update BIOS** — vendors fix this regularly.
2. `pcie_acs_override=downstream,multifunction` (see step 6 above).
3. Move the card to a different physical slot (internal PCIe only,
   doesn't apply to TB).

**Code 43 inside a Windows guest.**
NVIDIA's older Windows drivers detect the VM and refuse to load.
Add to `/etc/pve/qemu-server/<vm-id>.conf`:

```
args: -cpu host,kvm=off,hv_vendor_id=null
```

Linux guests with the open-source driver branch (570+) are not
affected. **Do not add `kvm=off` for Linux guests** — NVIDIA removed
the anti-virtualization check in driver 465 (2021), and disabling
`kvm` paravirt only hurts performance for no benefit.

**`nvidia-smi` works on the host but not in the VM.**
You forgot to blacklist on the host *or* you're running the host
driver in parallel. The host must have *no* NVIDIA driver loaded —
the GPU exists only as a vfio-pci stub from the host's perspective.

**`ubuntu-drivers install` picks an ancient driver (e.g. 470).**
Kernel headers may be missing. Inside the guest:

```bash
sudo apt install --reinstall linux-headers-$(uname -r)
sudo ubuntu-drivers install
```

## References

- Authoritative source for `pve12`'s build: the Obsidian-vault note
  "NUC12 Proxmox Reinstall — RTX 3090 eGPU Passthrough" (kept by the
  homelab owner, outside this repo).
- Proxmox wiki: <https://pve.proxmox.com/wiki/PCI_Passthrough>
- Arch wiki (more thorough on edge cases):
  <https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF>

## Appendix: pve12 reference configuration

Snapshot of the running `pve12` host. Useful as a rebuild reference
if the host is ever reinstalled. Capture commands at the bottom.

### Hardware

- Intel NUC, i7-1260P (Alder Lake-P, 4P + 8E / 16T)
- 64 GiB RAM
- Intel Iris Xe iGPU at `00:02.0` (`8086:46a6`) — host-only, never passed through
- Razer Core X (TB3 enclosure) connected to a TB4 port on the NUC
  → NVIDIA RTX 3090 (24 GB VRAM)
- Link runs at `40 Gb/s = 2 lanes × 20 Gb/s` per `boltctl list` —
  full TB3 speed, which tunnels PCIe at Gen3 x4 (the link-speed
  ceiling for any TB3/TB4 eGPU)

### `lspci -nn | grep -iE 'nvidia|vga'`

```
00:02.0 VGA compatible controller [0300]: Intel Corporation Alder Lake-P GT2 [Iris Xe Graphics] [8086:46a6] (rev 0c)
3c:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA102 [GeForce RTX 3090] [10de:2204] (rev a1)
3c:00.1 Audio device [0403]: NVIDIA Corporation GA102 High Definition Audio Controller [10de:1aef] (rev a1)
```

The 3090 enumerates at bus `3c:00` over Thunderbolt; this is what
`vms/llm/.env`'s `GPU_PCI_ADDRESS` is set to. On this NUC the bus
address is stable across both TB ports (verified by moving the cable
between TB1 and TB2 — the eGPU stays at `3c:00`). Different hosts
may behave differently; always re-check with `lspci` after any
physical change.

### Thunderbolt enrollment

`pve12`'s BIOS Thunderbolt Security Level is **not** at SL0; the Razer
Core X is permanently enrolled via `boltctl` with `policy: auto`, so
the host re-authorizes the enclosure on every boot from the stored
credential. Equivalent to SL0 in effect, slightly more secure on
paper (only enrolled devices can tunnel PCIe).

```text
● Razer Core X
  ├─ type:          peripheral
  ├─ generation:    Thunderbolt 3
  ├─ status:        authorized
  │  ├─ rx speed:   40 Gb/s = 2 lanes * 20 Gb/s
  │  ├─ tx speed:   40 Gb/s = 2 lanes * 20 Gb/s
  │  └─ authflags:  none
  └─ stored:        2026-04-21
     ├─ policy:     auto
     └─ key:        no
```

If this enclosure is ever swapped or the credential is lost, re-enroll:

```bash
systemctl enable --now bolt
boltctl enroll --policy auto <uuid-from-boltctl-list>
```

### `/etc/default/grub` (relevant line)

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
```

After editing, run `update-grub` and reboot.

### `/etc/modules`

```
vfio
vfio_iommu_type1
vfio_pci
```

### `/etc/modprobe.d/blacklist-nvidia.conf`

```
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidiafb
```

### `/etc/modprobe.d/vfio.conf`

```text
options vfio-pci ids=10de:2204,10de:1aef disable_vga=1
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidia_drm pre: vfio-pci
softdep nvidia_modeset pre: vfio-pci
```

After editing modprobe files, run `update-initramfs -u -k all` and
reboot.

### Capture commands (to refresh this appendix)

```bash
ssh root@pve12.lan 'lspci -nn | grep -iE "nvidia|vga"'
ssh root@pve12.lan 'grep -E "^GRUB_CMDLINE" /etc/default/grub'
ssh root@pve12.lan 'cat /etc/modules'
ssh root@pve12.lan 'cat /etc/modprobe.d/blacklist-nvidia.conf'
ssh root@pve12.lan 'cat /etc/modprobe.d/vfio.conf'
ssh root@pve12.lan 'lspci -nnk -s 3c:00'
ssh root@pve12.lan 'boltctl list'
```
