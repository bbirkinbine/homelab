#!/usr/bin/env bash
# scripts/cluster-pcore-snapshot.sh — for each P-core on each node, show which
# running VM currently has a vCPU thread there (or "idle").
#
# This is a MOMENT-IN-TIME observation, not a configuration view. With nothing
# pinned (no `affinity:` in any VM config), the Linux scheduler migrates QEMU
# vCPU threads between cores continuously based on load and Intel Thread
# Director hints. Re-run the script to see how placement shifts.
#
# Mechanism: walk /var/run/qemu-server/*.pid to get each running VM's QEMU
# PID, then `ps -L -o psr= -p <pid>` to list the current CPU for every thread
# of that process. Cross-reference with /sys/devices/cpu_core/cpus.
#
# Usage:
#   NODES="10.0.0.12 10.0.0.13 10.0.0.14" scripts/cluster-pcore-snapshot.sh
#
# RFC 5737 defaults below — override via the env var.

set -euo pipefail

read -r -a NODES <<< "${NODES:-192.0.2.12 192.0.2.13 192.0.2.14}"

for ip in "${NODES[@]}"; do
  echo "===== $ip ====="
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

echo "host: $(hostname)"

pcores_raw=$(cat /sys/devices/cpu_core/cpus 2>/dev/null || true)
if [ -z "$pcores_raw" ]; then
  echo "  (no hybrid topology — /sys/devices/cpu_core absent)"
  exit 0
fi
echo "  P-cores: $pcores_raw"
echo

# pid -> "vmid(name)" map for running VMs
declare -A pid_to_vm
for pidfile in /var/run/qemu-server/*.pid; do
  [ -e "$pidfile" ] || continue
  vmid=$(basename "$pidfile" .pid)
  pid=$(cat "$pidfile" 2>/dev/null) || continue
  name=$(awk '/^name:/ {print $2; exit}' "/etc/pve/qemu-server/${vmid}.conf" 2>/dev/null)
  [ -z "$name" ] && name="?"
  pid_to_vm[$pid]="${vmid}(${name})"
done

# P-core lookup set
declare -A is_pcore
for c in $(expand_cpuset "$pcores_raw"); do is_pcore[$c]=1; done

# CPU -> comma-separated list of vmids currently with a thread on it
declare -A cpu_owners
for pid in "${!pid_to_vm[@]}"; do
  vm=${pid_to_vm[$pid]}
  while read -r cpu; do
    cpu=${cpu// /}
    [ -z "$cpu" ] && continue
    [ -z "${is_pcore[$cpu]:-}" ] && continue
    # de-dupe: each VM appears at most once per CPU even if multiple
    # of its vCPU threads happen to be on the same core in this snapshot
    case ",${cpu_owners[$cpu]:-}," in
      *",$vm,"*) ;;
      *) cpu_owners[$cpu]="${cpu_owners[$cpu]:+${cpu_owners[$cpu]}, }$vm" ;;
    esac
  done < <(ps -L -o psr= -p "$pid" 2>/dev/null)
done

# Per-P-core output, numerically sorted
echo "  P-core   current VM thread(s)"
for cpu in $(expand_cpuset "$pcores_raw" | sort -n); do
  owner=${cpu_owners[$cpu]:-"(idle)"}
  printf "  CPU %3d  %s\n" "$cpu" "$owner"
done
REMOTE
  echo
done
