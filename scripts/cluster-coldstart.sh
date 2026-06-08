#!/usr/bin/env bash
# scripts/cluster-coldstart.sh — restore and verify the Thunderbolt fabric
# (corosync ring1 + the live-migration path) after a full cluster cold start.
#
# The inverse of cluster-shutdown.sh + cluster-poweroff.sh. Once every node is
# powered back on, the cluster reaches quorum and starts its onboot guests on
# its OWN over ring0 (the 2.5GbE LAN) — so the lab LOOKS healthy while ring1
# and the TB migration path are still down. That's the trap: the `tbnet-*`
# interfaces come up admin-DOWN on every boot (a boot-ordering race — the
# systemd .link files pin the interface NAME, not its up-state, and nothing
# auto-reloads them). Until they're reloaded the cluster runs single-ring on
# the LAN: no corosync redundancy, and live migration over TB is broken.
#
# Two halves:
#   * VERIFY (always, read-only) — per-node corosync ring1 status, the full
#     loopback ping mesh (proves L3 transit forwarding end-to-end, including
#     the multi-hop leaf<->leaf path), and nas-vms shared-storage state.
#   * REMEDIATE (--apply only) — `ifreload -a` on every node, TWICE. A TB link
#     carries traffic only once BOTH ends are admin-up, so pass 1 brings the
#     interfaces up and establishes carriers (its route installs fail with
#     "Nexthop has invalid gateway" — expected, not an error), and pass 2
#     installs the src-hinted routes now that carriers exist. Then it re-runs
#     VERIFY to prove ring1 came back.
#
# Why this is safe to script even though the cluster bring-up doc says "never
# automate" — that rule is about `pvecm create`/`add` and `corosync.conf`
# edits, which are quorum-critical and can fence a node. This touches NEITHER.
# It re-applies already-staged, known-good /etc/network/interfaces after a
# reboot; `vmbr0` (the LAN bridge your SSH rides on) is untouched, so a bad
# reload can't lock you out. ifreload is idempotent — running this when ring1
# is already healthy is a harmless no-op reload that just re-verifies.
#
# Deliberately does NOT start guests: onboot guests come up on their own, and
# amp-game (live Minecraft worlds) is a by-hand start. See cluster-bring-up.md
# Step C6. This script stops at the network + verification boundary.
#
# Run this from a workstation, NOT from a cluster node.
#
# Usage:
#   NODES="10.0.0.12 10.0.0.13 10.0.0.14 10.0.0.15" scripts/cluster-coldstart.sh
#   NODES="..." scripts/cluster-coldstart.sh --apply
#
# Set NODES to your cluster's LAN IPs (space-separated). The defaults below
# are RFC 5737 documentation addresses — they won't route to real hardware;
# override via the env var. Exit status is 0 only when the fabric is healthy,
# so the dry run doubles as a health probe you can branch on.

set -euo pipefail

# RFC 5737 documentation defaults — replace via NODES env var.
read -r -a NODES <<< "${NODES:-192.0.2.12 192.0.2.13 192.0.2.14 192.0.2.15}"

APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *)         echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# BatchMode so a missing key fails fast instead of hanging on a prompt.
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

# ---------------------------------------------------------------------------
# remediate — ifreload -a on every node, twice. Each call is guarded with
# `|| true`: ifreload exits non-zero on pass 1's expected "Nexthop has invalid
# gateway" route failures, and `set -e` would otherwise abort the sweep.
# ---------------------------------------------------------------------------
remediate() {
  local pass ip
  for pass in 1 2; do
    echo "=== ifreload pass $pass (pass 1's route warnings are expected) ==="
    for ip in "${NODES[@]}"; do
      echo "  $ip"
      "${SSH[@]}" root@"$ip" 'ifreload -a' 2>&1 | sed 's/^/    /' || true
    done
  done
  echo
}

# ---------------------------------------------------------------------------
# verify — ring1 status per node + loopback ping mesh + nas-vms. Returns
# non-zero if anything is unhealthy so the caller (and the exit code) can
# branch on it. Each node's TB loopback is discovered from corosync rather
# than declared here, so the script carries no cluster topology.
# ---------------------------------------------------------------------------
verify() {
  local ip rc=0
  local -a LOOPBACKS=()

  echo "--- corosync ring1 (LINK ID 1 — want every peer 'connected') ---"
  for ip in "${NODES[@]}"; do
    local out block lo bad
    out="$("${SSH[@]}" root@"$ip" 'corosync-cfgtool -s' 2>/dev/null || true)"
    if [ -z "$out" ]; then
      echo "  $ip: UNREACHABLE"; rc=1; continue
    fi
    # Isolate the LINK ID 1 block (everything until the next 'LINK ID' or EOF),
    # pull its local addr (the node's TB loopback), and count disconnected
    # peers. A healthy block has the localhost line + (N-1) connected, 0 down.
    block="$(awk '/LINK ID 1/{f=1;next} /LINK ID/{f=0} f' <<< "$out")"
    lo="$(awk -F'= ' '/addr/{print $2; exit}' <<< "$block" | tr -d '[:space:]')"
    bad="$(grep -c 'disconnected' <<< "$block" || true)"
    [ -n "$lo" ] && LOOPBACKS+=("$lo")
    if [ "$bad" -eq 0 ]; then
      echo "  $ip (lo ${lo:-?}): ring1 UP"
    else
      echo "  $ip (lo ${lo:-?}): ring1 DEGRADED — $bad peer(s) disconnected"; rc=1
    fi
  done

  echo
  echo "--- loopback ping mesh (every node -> every discovered TB loopback) ---"
  if [ "${#LOOPBACKS[@]}" -eq 0 ]; then
    echo "  no loopbacks discovered — skipping mesh"; rc=1
  else
    for ip in "${NODES[@]}"; do
      local res
      res="$("${SSH[@]}" root@"$ip" "for lo in ${LOOPBACKS[*]}; do ping -c1 -W1 \$lo >/dev/null 2>&1 && echo \"\$lo OK\" || echo \"\$lo FAIL\"; done" 2>/dev/null || true)"
      if [ -z "$res" ]; then
        echo "  from $ip: UNREACHABLE"; rc=1
      elif grep -q FAIL <<< "$res"; then
        echo "  from $ip: $(tr '\n' ' ' <<< "$res")"; rc=1
      else
        echo "  from $ip: all ${#LOOPBACKS[@]} loopbacks OK"
      fi
    done
  fi

  echo
  echo "--- nas-vms shared storage (want active on every node) ---"
  for ip in "${NODES[@]}"; do
    local st
    st="$("${SSH[@]}" root@"$ip" "pvesm status 2>/dev/null | awk '/^nas-vms/{print \$3}'" 2>/dev/null || true)"
    case "$st" in
      active) echo "  $ip: nas-vms active" ;;
      "")     echo "  $ip: nas-vms NOT FOUND / unreachable"; rc=1 ;;
      *)      echo "  $ip: nas-vms $st"; rc=1 ;;
    esac
  done

  return "$rc"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
if [ "$APPLY" -eq 0 ]; then
  echo "DRY RUN — verification only. Re-run with --apply to ifreload the TB"
  echo "fabric (brings the tbnet-* interfaces up; vmbr0 is untouched)."
  echo
  if verify; then
    echo; echo "Cold-start TB fabric: HEALTHY."
  else
    echo; echo "Cold-start TB fabric: DEGRADED — re-run with --apply (or investigate)."
    exit 1
  fi
  exit 0
fi

echo "APPLY — reloading the TB fabric on every node, then verifying."
echo
remediate
echo "=== post-ifreload verification ==="
if verify; then
  echo; echo "Cold-start TB fabric: HEALTHY."
else
  echo
  echo "Cold-start TB fabric: STILL DEGRADED after --apply — investigate by hand"
  echo "(cabling, boltctl enroll, or the udevadm rename fix). See"
  echo "docs/cluster-bring-up.md Step C3 + 'Common failures'."
  exit 1
fi
