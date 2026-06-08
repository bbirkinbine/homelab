#!/usr/bin/env bash
# scripts/cluster-poweroff.sh — power off every PVE node in the cluster,
# the host-layer follow-on to cluster-shutdown.sh's VM sweep.
#
# Run this AFTER cluster-shutdown.sh --apply has taken every guest down
# (and after any by-hand stops like amp-game / pbs01). It SSHes each node
# and issues `poweroff`, all in parallel.
#
# On quorum during a full shutdown: there's nothing to avoid. Quorum is a
# split-brain guard for a *running* cluster — it gates whether a node may
# write cluster state while partitioned. When every node is going down,
# the survivors dropping below majority (3 of 4) just flips /etc/pve to
# read-only for the few seconds before they power off. Harmless. You do
# NOT need `pvecm expected 1` (that's for keeping ONE node quorate while
# the rest stay down) and you do NOT need a shutdown order.
#
# The real pre-flight is HA, not quorum: a node that loses quorum while
# still up with HA resources active can self-fence (watchdog reboot).
# Check `ha-manager status` on any node first — if nothing is active (or
# HA isn't configured), there's nothing to fence and parallel poweroff is
# safe. If there ARE active HA resources, park them for the window first.
#
# Default is a DRY RUN — it only lists the nodes it *would* power off.
# Pass --apply to actually send the poweroffs.
#
# Run this from a workstation, NOT from a cluster node — otherwise you
# power off the host your own SSH session is riding on.
#
# Usage:
#   NODES="10.0.0.12 10.0.0.13 10.0.0.14 10.0.0.15" scripts/cluster-poweroff.sh
#   NODES="..." scripts/cluster-poweroff.sh --apply
#
# Set NODES to your cluster's LAN IPs (space-separated). The defaults
# below are RFC 5737 documentation addresses — they won't route to real
# hardware; override via the env var.

set -euo pipefail

# RFC 5737 documentation defaults — replace via NODES env var.
read -r -a NODES <<< "${NODES:-192.0.2.12 192.0.2.13 192.0.2.14 192.0.2.15}"

APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *)         echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$APPLY" -eq 0 ]; then
  echo "DRY RUN — listing nodes only. Re-run with --apply to power them off."
  echo
  for ip in "${NODES[@]}"; do echo "  would power off $ip"; done
  exit 0
fi

# All in parallel: order is irrelevant for a full shutdown, and the loss
# of quorum on the trailing nodes is expected (see header). ssh returns
# non-zero as the host drops the connection mid-poweroff — that's the
# success signal, not a failure, so we don't let it abort the loop.
pids=()
for ip in "${NODES[@]}"; do
  echo "powering off $ip"
  ssh -o ConnectTimeout=5 root@"$ip" 'poweroff' &
  pids+=("$!")
done

for pid in "${pids[@]}"; do
  wait "$pid" || true
done

echo
echo "poweroff sent to all nodes. Give them ~30-60s to drop."
