#!/usr/bin/env bash
# scripts/cluster-fan-speeds.sh — fan RPMs + CPU/NVMe temps for every PVE node.
#
# Walks /sys/class/hwmon over SSH on each cluster member. No lm-sensors
# dependency on the nodes; sysfs is always there if the kernel module
# is loaded. On these ASUS-branded NUC12/NUC13 hosts, fan readings come
# from the `asus` hwmon driver (provided by `asus_wmi`, auto-loaded
# at boot). CPU temps come from `coretemp`. NVMe temp from `nvme`.
# We skip noisy entries (acpitz, iwlwifi_*) that don't matter for
# thermal monitoring.
#
# Usage:
#   scripts/cluster-fan-speeds.sh                # all 3 nodes
#   NODES="192.168.1.227" scripts/cluster-fan-speeds.sh    # one node
#
# IPs default to the lab's three Proxmox nodes (matching
# pve-hosts/ansible/inventory.yml). Override via NODES env var as a
# space-separated list.

set -euo pipefail

# Default to the homelab's three nodes. Override via env var if needed.
read -r -a NODES <<< "${NODES:-192.168.1.227 192.168.1.163 192.168.1.240}"

for ip in "${NODES[@]}"; do
  echo "===== $ip ====="
  # Heredoc'd bash so we don't fight quoting on the remote side.
  ssh -o ConnectTimeout=5 root@"$ip" 'bash -s' <<'REMOTE'
echo "host: $(hostname)"
echo

found_fan=0
found_temp=0

for d in /sys/class/hwmon/*; do
  [ -d "$d" ] || continue
  name=$(cat "$d/name" 2>/dev/null || echo "?")

  # Fans — show all of them, regardless of which hwmon driver.
  for f in "$d"/fan*_input; do
    [ -e "$f" ] || continue
    label_file=${f%_input}_label
    if [ -e "$label_file" ]; then
      label=$(cat "$label_file")
    else
      label=$(basename "$f" _input)
    fi
    rpm=$(cat "$f")
    printf "  fan  %-20s %5d RPM  [%s]\n" "$label" "$rpm" "$name"
    found_fan=1
  done

  # Temps — filter to CPU / NVMe only. Skip acpitz (generic ACPI zone,
  # rarely useful), iwlwifi (WiFi card temp, irrelevant), etc.
  case "$name" in
    coretemp|k10temp|nvme)
      for t in "$d"/temp*_input; do
        [ -e "$t" ] || continue
        label_file=${t%_input}_label
        if [ -e "$label_file" ]; then
          label=$(cat "$label_file")
        else
          label=$(basename "$t" _input)
        fi
        val=$(cat "$t")
        c=$((val / 1000))
        printf "  temp %-20s %3d°C   [%s]\n" "$label" "$c" "$name"
        found_temp=1
      done
      ;;
  esac
done

if [ "$found_fan" -eq 0 ]; then
  echo "  (no fan sensors visible — try: modprobe asus_wmi, or check"
  echo "   /sys/class/hwmon/*/name for the platform's SuperIO driver)"
fi
if [ "$found_temp" -eq 0 ]; then
  echo "  (no CPU/NVMe temps visible — coretemp module should auto-load)"
fi
REMOTE
  echo
done
