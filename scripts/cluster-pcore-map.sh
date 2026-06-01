#!/usr/bin/env bash
# scripts/cluster-pcore-map.sh — list P-cores per node and which VM (if any)
# each is pinned to.
#
# On hybrid Intel (12th-gen+) the kernel exposes the P-core set at
# /sys/devices/cpu_core/cpus and the E-core set at /sys/devices/cpu_atom/cpus.
# We cross-reference those with the `affinity:` field of every VM config in
# /etc/pve/qemu-server/ (that path is a symlink to this node's per-node
# directory, so we only see local VMs — which is what we want, since pinning
# is a per-host concept anyway). VMs without an `affinity:` line are reported
# as "floating": the scheduler can place their vCPU threads on any logical
# CPU including E-cores.
#
# We also flag any VM pinned to an E-core CPU ID, since on these NUC-class
# hosts that's almost always a misconfiguration.
#
# Usage:
#   NODES="10.0.0.12 10.0.0.13 10.0.0.14" scripts/cluster-pcore-map.sh
#   NODES="10.0.0.12" scripts/cluster-pcore-map.sh                       # one node
#
# RFC 5737 defaults below — override via the env var.

set -euo pipefail

read -r -a NODES <<< "${NODES:-192.0.2.12 192.0.2.13 192.0.2.14}"

for ip in "${NODES[@]}"; do
  echo "===== $ip ====="
  ssh -o ConnectTimeout=5 root@"$ip" 'bash -s' <<'REMOTE'
echo "host: $(hostname)"

# ---- expand a cpuset like "0-3,8,12-15" into space-separated IDs ----
expand_cpuset() {
  local s=$1 out="" p lo hi i
  [ -z "$s" ] && return
  IFS=',' read -ra parts <<< "$s"
  for p in "${parts[@]}"; do
    if [[ $p == *-* ]]; then
      lo=${p%-*}; hi=${p#*-}
      for ((i=lo; i<=hi; i++)); do out+="$i "; done
    else
      out+="$p "
    fi
  done
  echo "$out"
}

pcores_raw=$(cat /sys/devices/cpu_core/cpus 2>/dev/null || true)
ecores_raw=$(cat /sys/devices/cpu_atom/cpus 2>/dev/null || true)

if [ -z "$pcores_raw" ]; then
  echo "  (no hybrid topology — /sys/devices/cpu_core absent; non-hybrid CPU?)"
  exit 0
fi

pcores=$(expand_cpuset "$pcores_raw")
ecores=$(expand_cpuset "$ecores_raw")

echo "  P-cores: $pcores_raw   E-cores: ${ecores_raw:-none}"
echo

# ---- build CPU -> "vmid(name)[state]" map from each VM's affinity ----
declare -A cpu_owner
floating=()

for cfg in /etc/pve/qemu-server/*.conf; do
  [ -e "$cfg" ] || continue
  vmid=$(basename "$cfg" .conf)
  name=$(awk '/^name:/ {print $2; exit}' "$cfg")
  [ -z "$name" ] && name="?"
  aff=$(awk '/^affinity:/ {print $2; exit}' "$cfg")

  state="stopped"
  [ -e "/var/run/qemu-server/$vmid.pid" ] && state="running"

  tag="$vmid($name)[$state]"

  if [ -z "$aff" ]; then
    floating+=("$tag")
    continue
  fi

  for cpu in $(expand_cpuset "$aff"); do
    if [ -n "${cpu_owner[$cpu]:-}" ]; then
      cpu_owner[$cpu]="${cpu_owner[$cpu]}, $tag"
    else
      cpu_owner[$cpu]="$tag"
    fi
  done
done

# ---- one line per P-core ----
echo "  P-core mapping:"
for cpu in $pcores; do
  owner=${cpu_owner[$cpu]:-"(free)"}
  printf "    CPU %3d  %s\n" "$cpu" "$owner"
done

# ---- VMs pinned to E-cores (likely a mistake) ----
ecore_hits=()
for cpu in $ecores; do
  if [ -n "${cpu_owner[$cpu]:-}" ]; then
    ecore_hits+=("CPU $cpu -> ${cpu_owner[$cpu]}")
  fi
done
if [ ${#ecore_hits[@]} -gt 0 ]; then
  echo
  echo "  WARNING: VMs pinned to E-cores:"
  for e in "${ecore_hits[@]}"; do
    echo "    $e"
  done
fi

# ---- floating VMs (no affinity set) ----
echo
if [ ${#floating[@]} -gt 0 ]; then
  echo "  Floating (no affinity; scheduler may place on any core):"
  for v in "${floating[@]}"; do
    echo "    $v"
  done
else
  echo "  (no floating VMs)"
fi
REMOTE
  echo
done
