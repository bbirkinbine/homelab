#!/usr/bin/env bash
# scripts/cluster-shutdown.sh — graceful ACPI shutdown of every running VM
# across the cluster, for a maintenance window.
#
# Walks each PVE node over SSH and issues `qm shutdown` against every VM
# the node currently reports as running. We drive `qm` locally on each
# node rather than the cluster API from one node: `qm` is always present
# on a PVE host, so there's no `pvesh`/`jq` dependency to assume, and the
# per-node SSH sweep matches the other cluster-*.sh scripts here.
#
# Default is a DRY RUN — it only lists what it *would* shut down. Pass
# --apply to actually send the shutdowns. This is deliberate: an unread
# "would stop N VMs" line is exactly how a maintenance sweep turns into
# an outage you didn't mean to cause.
#
# Graceful shutdown depends on qemu-guest-agent in the guest (the Ubuntu
# base template has it; Windows guests need the QEMU GA installed). With
# --force, anything that misses the ACPI timeout is hard-stopped so the
# sweep always converges; without it, a hung guest is left running for
# you to investigate by hand.
#
# amp-game (the Minecraft host) carries irreplaceable live worlds — set
# EXCLUDE to its VMID and shut it down by hand (in-game save-all + stop)
# so the JVM flushes cleanly before its VM goes down. If any VM is under
# Proxmox HA, the HA manager will restart it after shutdown; check
# `ha-manager status` and park those for the window first.
#
# Usage:
#   NODES="10.0.0.12 10.0.0.13 10.0.0.14" scripts/cluster-shutdown.sh
#   NODES="..." scripts/cluster-shutdown.sh --apply
#   NODES="..." scripts/cluster-shutdown.sh --apply --timeout 180 --force
#   NODES="..." EXCLUDE="110 9000" scripts/cluster-shutdown.sh --apply
#
# Set NODES to your cluster's LAN IPs (space-separated). The defaults
# below are RFC 5737 documentation addresses — they won't route to real
# hardware; override via the env var.

set -euo pipefail

# RFC 5737 documentation defaults — replace via NODES env var.
read -r -a NODES <<< "${NODES:-192.0.2.12 192.0.2.13 192.0.2.14}"

# Space-separated VMIDs to never touch (e.g. amp-game). Empty by default.
EXCLUDE="${EXCLUDE:-}"

APPLY=0
TIMEOUT=120
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)        APPLY=1 ;;
    --force)        FORCE=1 ;;
    --timeout)      TIMEOUT="${2:?--timeout needs a value}"; shift ;;
    --timeout=*)    TIMEOUT="${1#*=}" ;;
    -h|--help)
      sed -n '2,46p' "$0"; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$APPLY" -eq 0 ]; then
  echo "DRY RUN — listing running VMs only. Re-run with --apply to shut them down."
  echo
fi

for ip in "${NODES[@]}"; do
  echo "===== $ip ====="
  # Pass our flags into the remote shell as positional args; heredoc'd
  # bash so we don't fight quoting on the remote side.
  ssh -o ConnectTimeout=5 root@"$ip" 'bash -s' "$APPLY" "$TIMEOUT" "$FORCE" "$EXCLUDE" <<'REMOTE'
apply=$1; timeout=$2; force=$3; exclude=$4
echo "host: $(hostname)"

# Build a lookup of VMIDs to skip.
declare -A skip
for v in $exclude; do skip[$v]=1; done

# `qm list` columns: VMID NAME STATUS MEM(MB) BOOTDISK(GB) PID
qm list | awk 'NR>1 && $3=="running" {print $1, $2}' | while read -r vmid name; do
  if [ -n "${skip[$vmid]:-}" ]; then
    echo "  skip  $vmid ($name) — in EXCLUDE list"
    continue
  fi
  if [ "$apply" -eq 1 ]; then
    echo "  shutdown $vmid ($name) — timeout ${timeout}s force=${force}"
    if [ "$force" -eq 1 ]; then
      qm shutdown "$vmid" --timeout "$timeout" --forceStop 1
    else
      qm shutdown "$vmid" --timeout "$timeout"
    fi
  else
    echo "  would shut down $vmid ($name)"
  fi
done
REMOTE
  echo
done
