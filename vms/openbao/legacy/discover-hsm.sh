#!/usr/bin/env bash
# vms/openbao/discover-hsm.sh
#
# Scan the Proxmox host for CCID smart-card devices and print recommended
# HSM_USB_* values for pasting into .env. READ-ONLY — does not modify any
# file (not .env, not .env.example, not anything on the Proxmox host).
#
# Usage:
#   ./discover-hsm.sh                  # uses PROXMOX_HOST from ./.env
#   ./discover-hsm.sh pve12t           # explicit host override
#
# Typical workflow:
#   1. cp .env.example .env
#   2. Edit .env: fill in PROXMOX_HOST, SSH_PUBLIC_KEY, ADMIN_USERNAME.
#      Leave HSM_USB_HOST_PORT / HSM_USB_USB3 at the placeholders for now.
#   3. Plug token A into the labeled HSM-A USB jack on the host.
#   4. Run ./discover-hsm.sh — it tells you what to set HSM_USB_* to.
#   5. Paste the suggested HSM_USB_* lines into .env.
#   6. Run ./deploy.sh.
#
# Why this exists rather than auto-populating .env from deploy.sh: the
# *labeled HSM-A jack* is a physical-world contract a script can't see.
# This helper does the parsing work; the operator confirms which device
# is at the labeled jack and pastes the matching values into .env.

set -euo pipefail
cd "$(dirname "$0")"

# Source .env if present, but don't require it — this script may be run
# BEFORE .env is finished (discovery is part of populating .env).
if [[ -f .env ]]; then
  set -o allexport
  # shellcheck disable=SC1091
  source .env
  set +o allexport
fi

# Resolve SSH target. Priority:
#   1. CLI arg ($1) — explicit override, useful when probing a node
#      different from the one .env points at.
#   2. PROXMOX_HOST from .env — the steady-state.
SSH_HOST="${1:-${PROXMOX_HOST:-}}"
if [[ -z "$SSH_HOST" ]]; then
  echo "Usage: $0 <proxmox-host>" >&2
  echo "       (or set PROXMOX_HOST in .env to skip the arg)" >&2
  exit 1
fi
SSH_USER="${SSH_USER:-root}"
SSH_TARGET="${SSH_USER}@${SSH_HOST}"
SSH_OPTS=(-o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=10")

echo "==> SSH'ing to ${SSH_TARGET} and scanning USB tree for CCID smart-card devices"

# Run the enumeration on the host. /sys/bus/usb/devices/ has cleaner
# machine-readable structure than parsing `lsusb -t`'s tree-format ASCII
# art. For each interface with bInterfaceClass=0x0b (USB CCID Smart Card
# class), we walk back to the parent device dir and the bus's root hub
# to read identity + speed.
#
# Output is pipe-delimited:
#   bus-port|vendor|product|root_hub_speed|manufacturer|product_name
#
# Quoted heredoc (<<'REMOTE') means $vars expand on the remote side.
REMOTE_OUT=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" bash -s <<'REMOTE'
set -e
for iface_class in /sys/bus/usb/devices/*/bInterfaceClass; do
  [ -r "$iface_class" ] || continue
  [ "$(cat "$iface_class")" = "0b" ] || continue

  iface_dir=$(dirname "$iface_class")            # /sys/bus/usb/devices/1-2:1.0
  iface_name=$(basename "$iface_dir")            # 1-2:1.0
  bus_port=${iface_name%%:*}                     # 1-2
  bus_num=${bus_port%%-*}                        # 1

  dev_dir="/sys/bus/usb/devices/$bus_port"
  root_dir="/sys/bus/usb/devices/usb${bus_num}"

  vendor=$(cat "$dev_dir/idVendor" 2>/dev/null || echo "?")
  product=$(cat "$dev_dir/idProduct" 2>/dev/null || echo "?")
  manuf=$(cat "$dev_dir/manufacturer" 2>/dev/null || echo "?")
  prodname=$(cat "$dev_dir/product" 2>/dev/null || echo "?")
  # The bus's root hub speed is what determines whether the VM needs an
  # xHCI (USB 3) controller for the passthrough slot. The CCID device
  # itself always negotiates at 12M (USB 1.1) regardless of controller.
  root_speed=$(cat "$root_dir/speed" 2>/dev/null || echo "?")

  echo "${bus_port}|${vendor}|${product}|${root_speed}|${manuf}|${prodname}"
done
REMOTE
)

if [[ -z "$REMOTE_OUT" ]]; then
  echo "" >&2
  echo "ERROR: no CCID smart-card devices found on ${SSH_HOST}." >&2
  echo "       Plug token A into the labeled HSM-A USB jack and re-run." >&2
  echo "       To diagnose by hand:" >&2
  echo "         ssh ${SSH_TARGET} 'lsusb && lsusb -t'" >&2
  exit 1
fi

DEVICE_COUNT=$(printf '%s\n' "$REMOTE_OUT" | wc -l | tr -d ' ')

echo ""
if [[ "$DEVICE_COUNT" -eq 1 ]]; then
  echo "Found 1 CCID smart-card device:"
else
  echo "Found ${DEVICE_COUNT} CCID smart-card devices:"
fi
echo ""

INDEX=0
while IFS='|' read -r bus_port vendor product root_speed manuf prodname; do
  INDEX=$((INDEX + 1))

  # HSM_USB_USB3 recommendation:
  #   480M  -> the bus's root hub is a USB 2 hub (EHCI-equivalent) -> "0"
  #   5000M+ -> the bus's root hub is a USB 3 hub (xHCI SuperSpeed) -> "1"
  # Anything non-numeric or below 5000 falls back to "0" (the safer
  # default — qm without usb3=1 still works for USB 2 devices).
  if [[ "$root_speed" =~ ^[0-9]+$ ]] && [[ "$root_speed" -ge 5000 ]]; then
    USB3_VAL="1"
    SPEED_NOTE="${root_speed}M (USB 3, xHCI)"
  else
    USB3_VAL="0"
    SPEED_NOTE="${root_speed}M (USB 2, EHCI)"
  fi

  bus_num="${bus_port%%-*}"
  port_path="${bus_port#*-}"

  if [[ "$DEVICE_COUNT" -gt 1 ]]; then
    echo "  Option ${INDEX}:"
  fi
  cat <<EOT
  HSM_USB_HOST_PORT="${bus_port}"        # bus ${bus_num}, port ${port_path}
  HSM_USB_USB3="${USB3_VAL}"               # parent bus speed: ${SPEED_NOTE}
  # Device: ${vendor}:${product} ${prodname}
  # Manufacturer: ${manuf}

EOT
done <<< "$REMOTE_OUT"

if [[ "$DEVICE_COUNT" -eq 1 ]]; then
  echo "==> Paste the HSM_USB_* lines above into vms/openbao/.env"
  echo "    (replace the placeholder values that came from .env.example)."
else
  echo "==> ${DEVICE_COUNT} CCID readers found. Pick the one plugged into the"
  echo "    labeled HSM-A jack and paste those HSM_USB_* lines into"
  echo "    vms/openbao/.env (replace the placeholder values)."
fi
