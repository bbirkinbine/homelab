#!/usr/bin/env bash
# 12-serial-console.sh
#
# Configure the *installed* system's GRUB + kernel to emit console output on
# both VGA (tty1) and serial (ttyS0). The template is built with
# `vga: serial0` in the Proxmox config (see ubuntu-24-04-base.pkr.hcl), which
# clones inherit. Without this script, clones would boot to a blank serial
# console because the default Ubuntu 24.04 kernel cmdline only writes to
# tty1 — not viewable when VGA is redirected to a serial port.
#
# After this runs, both Proxmox web consoles work on clones:
#   - xterm.js (preferred, attaches to ttyS0)
#   - noVNC (still functional via vga=serial0 redirection)
#
# Listing both `console=` keeps boot messages visible if a clone is later
# reconfigured with `qm set <id> --vga std`.
set -euo pipefail

GRUB_DEFAULT=/etc/default/grub
DESIRED='console=tty1 console=ttyS0,115200'

echo "==> configure serial console on installed system"

# Strip any existing console= entries to avoid duplicates / conflicts, then
# prepend the desired pair. Preserves whatever else curtin put in the
# default cmdline (e.g. quiet, splash on desktop installs).
python3 - "$GRUB_DEFAULT" "$DESIRED" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
desired = sys.argv[2]
text = path.read_text()
def fix(line: str) -> str:
    m = re.match(r'^(GRUB_CMDLINE_LINUX_DEFAULT=)"(.*)"\s*$', line)
    if not m:
        return line
    cmdline = m.group(2)
    cmdline = re.sub(r'\bconsole=\S+\s*', '', cmdline).strip()
    cmdline = (desired + ' ' + cmdline).strip()
    return f'{m.group(1)}"{cmdline}"\n'
new = ''.join(fix(l) if l.startswith('GRUB_CMDLINE_LINUX_DEFAULT=') else l
              for l in text.splitlines(keepends=True))
if not any(l.startswith('GRUB_CMDLINE_LINUX_DEFAULT=') for l in new.splitlines()):
    new += f'GRUB_CMDLINE_LINUX_DEFAULT="{desired}"\n'
path.write_text(new)
PY

# Also enable the GRUB serial terminal so the GRUB *menu* itself is visible
# over serial — useful when troubleshooting failed boots on a clone.
if ! grep -q '^GRUB_TERMINAL=' "$GRUB_DEFAULT"; then
  echo 'GRUB_TERMINAL="console serial"' >> "$GRUB_DEFAULT"
  echo 'GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"' >> "$GRUB_DEFAULT"
fi

echo "==> regenerate grub config"
update-grub

# Enable a getty on ttyS0 so login works on the serial console even after
# cloud-init has done its thing on a clone.
echo "==> enable serial-getty@ttyS0"
systemctl enable serial-getty@ttyS0.service

echo "==> serial console configured"
