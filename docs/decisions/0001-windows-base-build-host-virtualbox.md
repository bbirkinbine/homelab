# 0001 — Windows base build host: VirtualBox on T480, not qemu

**Status:** Accepted
**Date:** 2026-05-08

## Context

The Windows 11 base template Packer pipeline targets two hosts: `proxmox-iso` (runs from the Mac, builds on a NUC) and a Linux-side build that produces a portable qcow2 for libvirt elsewhere. The Linux-side target was originally `qemu` (qemu+OVMF on the T480 directly), but the build kept stalling at Microsoft's `Press any key to boot from CD or DVD…` prompt — VNC keystroke delivery on that early-boot path was not reliable enough to advance the install before the prompt timed out.

## Decision

Replace the `qemu` source with `virtualbox-iso`. VBox 7.0+ executes the Windows install on the T480 and produces a VMDK + OVF + NVRAM under `output-vbox/`, which is converted to qcow2 via `qemu-img convert -f vmdk -O qcow2`.

## Consequences

- VBox sidesteps the bootmgr press-any-key path entirely — the install advances reliably.
- The T480 now needs VirtualBox kernel modules; macOS is rejected up front by `build-vbox.sh`.
- Two distinct wrapper scripts (`build-pve.sh`, `build-vbox.sh`) instead of one — host preconditions diverge sharply (Proxmox API access vs. local VBox >= 7.0).
- Earlier prototype merging both into one `build.sh` with a `BUILDER` variable was ~50% branching code; splitting was cleaner.

## Alternatives considered

- **Stay on qemu+OVMF, tune VNC keystroke delivery** — investigated; the prompt window is too short and the keystroke API doesn't synchronize reliably enough on this hardware.
- **Use a different headless x86 Windows installer (Hyper-V, etc.)** — out of scope; the T480 runs Ubuntu, not a Windows host.
