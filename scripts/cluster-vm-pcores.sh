#!/usr/bin/env bash
# scripts/cluster-vm-pcores.sh — flat list of running VMs across the cluster
# with the count of P-cores each one is pinned to.
#
# Reads /sys/devices/cpu_core/cpus per node to identify the P-core set, then
# intersects each running VM's `affinity:` field with it. VMs with no
# `affinity:` line are reported as "unpinned" — the scheduler can run them
# on any logical CPU, P or E.
#
# Stopped VMs are skipped: the question is what's actually consuming P-cores
# right now.
#
# Usage:
#   NODES="10.0.0.12 10.0.0.13 10.0.0.14" scripts/cluster-vm-pcores.sh
#
# RFC 5737 defaults below — override via the env var.

set -euo pipefail

read -r -a NODES <<< "${NODES:-192.0.2.12 192.0.2.13 192.0.2.14}"

printf "%-10s %-6s %-25s %s\n" "NODE" "VMID" "NAME" "P-CORES"
printf "%-10s %-6s %-25s %s\n" "----" "----" "----" "-------"

for ip in "${NODES[@]}"; do
  ssh -o ConnectTimeout=5 root@"$ip" 'bash -s' <<'REMOTE'
expand_cpuset() {
  local s=$1 p lo hi i
  [ -z "$s" ] && return
  IFS=',' read -ra parts <<< "$s"
  for p in "${parts[@]}"; do
    if [[ $p == *-* ]]; then
      lo=${p%-*}; hi=${p#*-}
      for ((i=lo; i<=hi; i++)); do echo "$i"; done
    else
      echo "$p"
    fi
  done
}

host=$(hostname)
pcores_raw=$(cat /sys/devices/cpu_core/cpus 2>/dev/null || true)
# Build P-core lookup set (one CPU ID per line, then a literal map)
declare -A is_pcore
for c in $(expand_cpuset "$pcores_raw"); do is_pcore[$c]=1; done

for pidfile in /var/run/qemu-server/*.pid; do
  [ -e "$pidfile" ] || continue
  vmid=$(basename "$pidfile" .pid)
  cfg="/etc/pve/qemu-server/${vmid}.conf"
  [ -e "$cfg" ] || continue

  name=$(awk '/^name:/ {print $2; exit}' "$cfg")
  [ -z "$name" ] && name="?"
  aff=$(awk '/^affinity:/ {print $2; exit}' "$cfg")

  if [ -z "$aff" ]; then
    printf "%-10s %-6s %-25s %s\n" "$host" "$vmid" "$name" "unpinned"
    continue
  fi

  count=0
  for c in $(expand_cpuset "$aff"); do
    [ -n "${is_pcore[$c]:-}" ] && count=$((count + 1))
  done
  printf "%-10s %-6s %-25s %s\n" "$host" "$vmid" "$name" "$count"
done
REMOTE
done
