#!/usr/bin/env bash
# scripts/nas-ups-guardian.sh — autonomous, per-node UPS guardian.
#
# Deployed onto each PVE node (by the pve-host role), onto pbs01 (by the
# pbs-host role), and onto pdm01 (by the pdm-host role), where a systemd
# timer runs it every ~20s. Unlike the sibling cluster-*.sh helpers, this
# is NOT operator-run from a workstation — it fires by itself on a power
# event. It lives here, with the other cluster shutdown scripts, so
# there's a single source of truth that `just shell-lint` covers; all
# three roles `copy` it onto the host at /usr/local/sbin/nas-ups-guardian.
#
# Problem it solves: the Asustor NAS is the NUT primary (the UPS is on
# its USB), the NFS server for both nas-vms (VM disks) and the PBS chunk
# store, AND it auto-powers-off when the UPS reaches "low" (its LB flag
# at battery.charge.low=10 / battery.runtime.low=120). If it powers off
# while a node is still writing over NFS, you get hung I/O and a dirty
# guest filesystem or — worse — a corrupted PBS datastore. NUT's
# primary/secondary handshake can't enforce ordering here because the
# Asustor upsd does not wait for network clients. So each node watches
# battery.charge over the network and shuts ITSELF down early, leaving
# the NAS to power off last:
#
#   ~75% charge  pdm01 stops the PDM API daemons, then powers off
#   ~70% charge  pbs01 drains in-flight backup/verify/GC, then powers off
#   ~60% charge  PVE nodes shut down their guests, then power off
#   ~10% charge  NAS reaches its own low-battery cutoff, powers off last
#
# pdm01 is NOT an NFS client and holds no data, so its tier carries no
# data-path ordering constraint — it goes first only because a management
# plane is useless during an outage and shedding it recovers a little
# runtime. The ordering guarantee that matters (NFS writers clearing
# before the NAS) is the charge GAP between each data-path tier's trigger
# and the NAS's 10% cutoff — not a handshake. Shutting the PVE guests
# (the LLM VM especially) also collapses the GPU load and recovers UPS
# runtime, widening the margin further. See pve-hosts/README.md,
# pbs-hosts/README.md and the design vault [[nut-ordered-shutdown-design]].
#
# Read-only `upsc` access is all this needs (no upsd user provisioning
# on the NAS). It acts ONLY when the UPS is on battery AND low; on line
# power every tick is a no-op, so the timer firing during an Ansible
# apply is harmless.
#
# Config comes from the EnvironmentFile /etc/default/nas-ups-guardian,
# rendered by the role from inventory. Required: GUARDIAN_MODE
# (pve|pbs|pdm) and NAS_NUT_TARGET (<upsname>@<host>).

set -euo pipefail

# ----- config (from the EnvironmentFile, with safe fallbacks) ---------
MODE="${GUARDIAN_MODE:-}"
TARGET="${NAS_NUT_TARGET:-}"
CHARGE_THRESHOLD="${CHARGE_THRESHOLD:-50}"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-180}"   # pve: per-guest ACPI timeout (s)
EXCLUDE_VMIDS="${EXCLUDE_VMIDS:-}"            # pve: VMIDs never auto-shut
PBS_DRAIN_GRACE="${PBS_DRAIN_GRACE:-30}"      # pbs: settle window after halting new work (s)
PDM_DRAIN_GRACE="${PDM_DRAIN_GRACE:-10}"      # pdm: settle window after stopping the API daemons (s)
COMMS_LOSS_ACTION="${COMMS_LOSS_ACTION:-log}" # log | shutdown
DRY_RUN="${DRY_RUN:-0}"

TRIGGER_FLAG=/run/nas-ups-guardian.triggered
LOCK_FILE=/run/nas-ups-guardian.lock

log() {
  # Tag for journald; echo too so `systemctl status` / interactive runs show it.
  logger -t nas-ups-guardian -- "$*" 2>/dev/null || true
  echo "nas-ups-guardian: $*"
}

# ----- drain actions --------------------------------------------------
drain_pve() {
  # Graceful ACPI shutdown of every running guest on THIS node, in
  # parallel, each bounded by SHUTDOWN_TIMEOUT; then force any straggler
  # so the node always converges before poweroff.
  local excl=()
  read -r -a excl <<< "$EXCLUDE_VMIDS"
  declare -A skip
  local v
  for v in "${excl[@]}"; do skip["$v"]=1; done

  local vmid name pids=() pid
  while read -r vmid name; do
    if [ -n "${skip[$vmid]:-}" ]; then
      log "skip $vmid ($name) — in EXCLUDE_VMIDS"
      continue
    fi
    if [ "$DRY_RUN" = "1" ]; then
      log "[dry-run] would qm shutdown $vmid ($name)"
      continue
    fi
    log "qm shutdown $vmid ($name) (timeout ${SHUTDOWN_TIMEOUT}s)"
    qm shutdown "$vmid" --timeout "$SHUTDOWN_TIMEOUT" &
    pids+=("$!")
  done < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1, $2}')

  for pid in "${pids[@]:-}"; do
    if [ -n "$pid" ]; then
      wait "$pid" 2>/dev/null || true
    fi
  done

  [ "$DRY_RUN" = "1" ] && return 0

  # Force-stop anything that missed its ACPI window so poweroff converges.
  while read -r vmid name; do
    [ -n "${skip[$vmid]:-}" ] && continue
    log "force-stop straggler $vmid ($name)"
    qm stop "$vmid" 2>/dev/null || true
  done < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1, $2}')
}

drain_pbs() {
  # Quiesce PBS before the node powers off so the NAS (which serves the
  # chunk store over NFS) never loses a writer mid-operation. PBS is
  # crash-consistent and its GC/verify are resumable, so we do NOT wait
  # for a long task to finish — we stop accepting new work, let in-flight
  # writes settle briefly, then let the orderly poweroff abort the rest
  # and unmount NFS cleanly while the NAS is still up.
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would stop proxmox-backup-proxy, wait ${PBS_DRAIN_GRACE}s, then power off"
    return 0
  fi
  log "stopping proxmox-backup-proxy to halt new backup/verify/GC work"
  systemctl stop proxmox-backup-proxy.service 2>/dev/null || true
  log "grace ${PBS_DRAIN_GRACE}s for in-flight chunk writes to settle"
  sleep "$PBS_DRAIN_GRACE"
  # The subsequent `systemctl poweroff` stops proxmox-backup.service,
  # aborting any still-running task and flushing, then systemd unmounts
  # the NFS datastore — all while the NAS remains powered.
}

drain_pdm() {
  # PDM is a management plane only — no guests, no datastore, not an NFS
  # client — so there is nothing to drain. Stop the API daemons cleanly so
  # in-flight UI/API requests end gracefully, pause briefly, then let the
  # orderly poweroff take the host down. PDM has no data-path ordering
  # constraint against the NAS; sending it early just sheds a
  # useless-during-an-outage service and recovers a little UPS runtime.
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would stop proxmox-datacenter-api(+privileged), wait ${PDM_DRAIN_GRACE}s, then power off"
    return 0
  fi
  log "stopping PDM API daemons"
  systemctl stop proxmox-datacenter-api.service proxmox-datacenter-privileged-api.service 2>/dev/null || true
  log "grace ${PDM_DRAIN_GRACE}s before poweroff"
  sleep "$PDM_DRAIN_GRACE"
}

power_off_node() {
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would power off this node now"
    return 0
  fi
  log "powering off node"
  systemctl poweroff
}

# ----- one-shot commit guard ------------------------------------------
# Once we've decided to shut down, the poweroff is in flight; later ticks
# must not re-enter. /run is tmpfs, so the flag clears on the next boot.
if [ -e "$TRIGGER_FLAG" ]; then
  exit 0
fi

if [ -z "$MODE" ] || [ -z "$TARGET" ]; then
  log "GUARDIAN_MODE and NAS_NUT_TARGET must be set in /etc/default/nas-ups-guardian; nothing to do"
  exit 0
fi

# Single-instance: if a previous tick is still running its drain, skip.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another instance holds the lock; skipping this tick"
  exit 0
fi

# ----- read UPS state -------------------------------------------------
# If upsd is unreachable, decide per COMMS_LOSS_ACTION. Default is
# conservative: a transient network blip must NOT power off the cluster.
# The whole design depends on the NAS (and the LAN switch carrying this
# poll) outlasting the nodes, so a missing upsd usually means "blip".
trigger=0
reason=""

if ! status="$(upsc "$TARGET" ups.status 2>/dev/null)"; then
  if [ "$COMMS_LOSS_ACTION" = "shutdown" ]; then
    trigger=1
    reason="UPS $TARGET unreachable and COMMS_LOSS_ACTION=shutdown"
  else
    log "UPS $TARGET unreachable (COMMS_LOSS_ACTION=$COMMS_LOSS_ACTION) — no action"
    exit 0
  fi
else
  charge_raw="$(upsc "$TARGET" battery.charge 2>/dev/null || echo "")"
  charge="${charge_raw%%.*}"   # strip any fractional part for the integer test

  on_battery=0
  low_battery=0
  case " $status " in
    *" OB "*) on_battery=1 ;;
  esac
  case " $status " in
    *" LB "*) low_battery=1 ;;
  esac

  if [ "$on_battery" -eq 1 ]; then
    if [ "$low_battery" -eq 1 ]; then
      trigger=1
      reason="on battery + UPS low-battery (LB) flag"
    elif [[ "$charge" =~ ^[0-9]+$ ]] && [ "$charge" -le "$CHARGE_THRESHOLD" ]; then
      trigger=1
      reason="on battery, charge ${charge}% <= ${CHARGE_THRESHOLD}%"
    else
      log "on battery, charge ${charge:-unknown}% > ${CHARGE_THRESHOLD}% — holding"
    fi
  fi
  # On line power (OL): nothing to do, even if charge reads low during a
  # post-outage recharge. The OB gate above is what prevents that.
fi

if [ "$trigger" -ne 1 ]; then
  exit 0
fi

# ----- commit ---------------------------------------------------------
# Mark BEFORE acting so a concurrent/next tick no-ops immediately.
: > "$TRIGGER_FLAG"
log "TRIGGER on $(hostname) [mode=$MODE]: $reason"

case "$MODE" in
  pve) drain_pve ;;
  pbs) drain_pbs ;;
  pdm) drain_pdm ;;
  *)   log "unknown GUARDIAN_MODE='$MODE' (expected pve|pbs|pdm) — powering off without a drain" ;;
esac

power_off_node
