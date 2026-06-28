#!/usr/bin/env bash
# scripts/pdm-config-backup.sh — snapshot a Proxmox Datacenter Manager
# host's own configuration to the NAS as a plain tarball, so a bare-metal
# rebuild can restore it.
#
# Deployed to /usr/local/sbin/pdm-config-backup on the PDM host by the
# pdm-host Ansible role (tasks/config_backup.yml), which also renders
# /etc/default/pdm-config-backup and installs a systemd timer so the host
# backs itself up on a schedule with no operator action. It lives here,
# with the other shared host helpers, so `just shell-lint` covers it.
#
# It is also self-contained — every setting has a default, so it runs
# standalone (`pdm-config-backup`, or `DRY_RUN=1 pdm-config-backup` to
# test) on pdm01 even without the role-rendered env file.
#
# Why this exists: Proxmox Datacenter Manager ships nothing to back up its
# own /etc/proxmox-datacenter-manager (same stance as PVE and PBS, which
# don't back up /etc/pve or /etc/proxmox-backup). PDM holds no guest data,
# so the DR value is narrower than the PBS equivalent: the config is the
# list of managed remotes (PVE clusters + PBS), their per-remote API
# tokens + TLS fingerprints, the ACLs, and the local users. Restoring it
# on a rebuilt host skips re-adding every remote by hand and preserves the
# exact ACL/user state. Worst case without it is reinstall-from-ISO + a
# few minutes in the web UI re-adding remotes.
#
# Why a plain tarball and NOT a backup-client snapshot into a datastore:
# the artifact stays self-contained — `tar xzf` it from anywhere (a rescue
# USB, your laptop, the half-installed box) with nothing running. The NAS
# also replicates it to the secondary, so it survives a NAS failure too.
#
# Security note: the tarball contains the per-remote API tokens PDM uses to
# reach its remotes, so it is sensitive. It is written mode 0600 into a
# 0700 directory, and the NAS export is LAN-only + ACL'd to this host.
# There are no extra API credentials involved (this never touches the PDM
# API), so nothing additional secret is persisted on the host for this job.
#
# Settings come from environment variables (all optional, defaults below).
# The role renders them into /etc/default/pdm-config-backup from inventory;
# the systemd unit pulls that in via EnvironmentFile. Knobs:
# PDM_CONFIG_SOURCE, PDM_CONFIG_DEST_DIR, PDM_CONFIG_PREFIX,
# PDM_CONFIG_KEEP_DAYS, DRY_RUN.

set -euo pipefail

# ----- config (env overrides, with safe defaults) --------------------
SOURCE="${PDM_CONFIG_SOURCE:-/etc/proxmox-datacenter-manager}"
DEST_DIR="${PDM_CONFIG_DEST_DIR:-/mnt/pdm-config/host-config}"
PREFIX="${PDM_CONFIG_PREFIX:-$(hostname -s 2>/dev/null || hostname)-config}"
KEEP_DAYS="${PDM_CONFIG_KEEP_DAYS:-30}"
DRY_RUN="${DRY_RUN:-0}"

log() {
  # Tag for journald; echo too so `systemctl status` / interactive runs show it.
  logger -t pdm-config-backup -- "$*" 2>/dev/null || true
  echo "pdm-config-backup: $*"
}
die() {
  log "ERROR: $*"
  exit 1
}

# Treat a non-numeric KEEP_DAYS as "no pruning" rather than letting the
# find -mtime expression choke.
case "$KEEP_DAYS" in
  '' | *[!0-9]*) KEEP_DAYS=0 ;;
esac

# ----- preconditions --------------------------------------------------
[ -n "$DEST_DIR" ] || die "PDM_CONFIG_DEST_DIR is set but empty"
[ -d "$SOURCE" ] || die "config source $SOURCE does not exist or is not a directory"

# The destination must live on the NAS mount, not the local root fs.
# systemd's RequiresMountsFor on the service unit is the primary guard
# (the oneshot won't start unless the mount is active); this is a
# belt-and-suspenders check for standalone runs. findmnt -T resolves the
# mount backing the path (walking up to the nearest existing ancestor, so
# it works before mkdir): if that resolves to "/" (or nothing), the NAS
# isn't mounted and we'd be writing the token-bearing tarball to local
# disk — refuse. Override PDM_CONFIG_DEST_DIR to a non-root mount to test
# elsewhere.
dest_mount="$(findmnt -n -o TARGET --target "$DEST_DIR" 2>/dev/null || true)"
if [ -z "$dest_mount" ] || [ "$dest_mount" = "/" ]; then
  die "destination $DEST_DIR is not on a dedicated mount (resolved to '${dest_mount:-none}') — is the NAS mounted? Refusing to write to local disk."
fi

# Harden the destination: the tarball carries API tokens, so keep the
# directory root-only. mkdir -p is a safety net under RequiresMountsFor.
mkdir -p -- "$DEST_DIR"
chmod 0700 -- "$DEST_DIR" 2>/dev/null || true

# ----- back up --------------------------------------------------------
# Timestamped name so each run is a distinct, sortable snapshot. Write to
# a .partial name and rename on success so a crashed run never leaves a
# truncated tarball that looks complete. tar with -C so the archive holds
# a clean relative `proxmox-datacenter-manager/` tree, not absolute paths.
ts="$(date +%Y%m%dT%H%M%S)"
out="${DEST_DIR}/${PREFIX}-${ts}.tar.gz"
tmp="${out}.partial"
src_parent="$(dirname -- "$SOURCE")"
src_leaf="$(basename -- "$SOURCE")"

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would archive ${SOURCE} -> ${out}"
else
  umask 077
  log "archiving ${SOURCE} -> ${out}"
  # tar exit codes: 0 = ok, 1 = "some files differ / changed as read"
  # (a benign race — PDM may rewrite a state file mid-read; the snapshot
  # is still usable), 2+ = fatal. Tolerate 1, fail on >=2.
  rc=0
  tar -czf "$tmp" -C "$src_parent" "$src_leaf" || rc=$?
  if [ "$rc" -ge 2 ]; then
    rm -f -- "$tmp"
    die "tar failed (exit $rc)"
  fi
  [ "$rc" -eq 1 ] && log "tar reported files changed during read (exit 1) — snapshot still usable"
  chmod 0600 -- "$tmp"
  mv -- "$tmp" "$out"
  log "wrote $out ($(du -h -- "$out" | cut -f1))"
fi

# ----- prune ----------------------------------------------------------
# Age out tarballs older than KEEP_DAYS. Scoped to this host's prefix so
# a shared destination directory never deletes another host's backups.
# KEEP_DAYS=0 disables pruning.
if [ "$KEEP_DAYS" -gt 0 ]; then
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would delete ${PREFIX}-*.tar.gz older than ${KEEP_DAYS} days in ${DEST_DIR}:"
    find "$DEST_DIR" -maxdepth 1 -type f -name "${PREFIX}-*.tar.gz" -mtime "+${KEEP_DAYS}" -print || true
  else
    log "pruning ${PREFIX}-*.tar.gz older than ${KEEP_DAYS} days in ${DEST_DIR}"
    find "$DEST_DIR" -maxdepth 1 -type f -name "${PREFIX}-*.tar.gz" -mtime "+${KEEP_DAYS}" -delete || true
  fi
fi

log "done"
