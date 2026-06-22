#!/usr/bin/env bash
# scripts/pbs-config-backup.sh — snapshot a PBS host's own configuration
# to the NAS as a plain tarball, so a bare-metal rebuild can restore it.
#
# Deployed to /usr/local/sbin/pbs-config-backup on the PBS host by the
# pbs-host Ansible role (tasks/config_backup.yml), which also renders
# /etc/default/pbs-config-backup and installs a systemd timer so the host
# backs itself up on a schedule with no operator action. It lives here,
# with the other shared host helpers, so `just shell-lint` covers it.
#
# It is also self-contained — every setting has a default, so it runs
# standalone (`pbs-config-backup`, or `DRY_RUN=1 pbs-config-backup` to
# test) on pbs01 even without the role-rendered env file.
#
# Why this exists: Proxmox Backup Server ships nothing to back up its own
# /etc/proxmox-backup — the product backs up clients, not itself (same
# stance as PVE, which doesn't back up /etc/pve). The config is small but
# load-bearing for disaster recovery: datastore.cfg (so a rebuilt host
# can re-attach the existing chunk store), user.cfg / acl.cfg, the
# verify/prune/GC job definitions, node.cfg, AND the auth keys +
# user/token shadows. Restoring authkey.key + the shadow files after a
# rebuild keeps already-issued tokens valid — notably the pveingress
# token the PVE cluster authenticates with — so you don't have to
# re-tokenize the whole cluster.
#
# Why a plain tarball and NOT proxmox-backup-client into the datastore:
# a PBS datastore is a content-addressed chunk store, readable only by a
# running PBS server. A config backup that lives *inside* the datastore
# can't be opened until PBS has been reinstalled and the datastore
# re-attached — backwards for a disaster-recovery artifact (the thing
# that would help you rebuild is locked behind the rebuild). A tarball on
# the NAS is self-contained: `tar xzf` it from anywhere — a rescue USB,
# your laptop, the half-installed box — with no PBS in the loop. The NAS
# also replicates it to the secondary, so it survives a NAS failure too.
#
# Security note: the tarball contains authkey.key (PBS's ticket-signing
# private key), so it is sensitive. It is written mode 0600 into a 0700
# directory, and the NAS export is LAN-only + ACL'd to this host. There
# are no API credentials involved (this never touches the PBS API), so
# nothing secret is persisted on the host for this job.
#
# Settings come from environment variables (all optional, defaults below).
# The role renders them into /etc/default/pbs-config-backup from inventory;
# the systemd unit pulls that in via EnvironmentFile. Knobs:
# PBS_CONFIG_SOURCE, PBS_CONFIG_DEST_DIR, PBS_CONFIG_PREFIX,
# PBS_CONFIG_KEEP_DAYS, DRY_RUN.

set -euo pipefail

# ----- config (env overrides, with safe defaults) --------------------
SOURCE="${PBS_CONFIG_SOURCE:-/etc/proxmox-backup}"
DEST_DIR="${PBS_CONFIG_DEST_DIR:-/mnt/pbs-bulk/host-config}"
PREFIX="${PBS_CONFIG_PREFIX:-$(hostname -s 2>/dev/null || hostname)-config}"
KEEP_DAYS="${PBS_CONFIG_KEEP_DAYS:-30}"
DRY_RUN="${DRY_RUN:-0}"

log() {
  # Tag for journald; echo too so `systemctl status` / interactive runs show it.
  logger -t pbs-config-backup -- "$*" 2>/dev/null || true
  echo "pbs-config-backup: $*"
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
[ -n "$DEST_DIR" ] || die "PBS_CONFIG_DEST_DIR is set but empty"
[ -d "$SOURCE" ] || die "config source $SOURCE does not exist or is not a directory"

# The destination must live on the NAS mount, not the local root fs.
# systemd's RequiresMountsFor on the service unit is the primary guard
# (the oneshot won't start unless the mount is active); this is a
# belt-and-suspenders check for standalone runs. findmnt -T resolves the
# mount backing the path (walking up to the nearest existing ancestor, so
# it works before mkdir): if that resolves to "/" (or nothing), the NAS
# isn't mounted and we'd be writing the private-key tarball to local disk
# — refuse. Override PBS_CONFIG_DEST_DIR to a non-root mount to test
# elsewhere.
dest_mount="$(findmnt -n -o TARGET --target "$DEST_DIR" 2>/dev/null || true)"
if [ -z "$dest_mount" ] || [ "$dest_mount" = "/" ]; then
  die "destination $DEST_DIR is not on a dedicated mount (resolved to '${dest_mount:-none}') — is the NAS mounted? Refusing to write to local disk."
fi

# Harden the destination: the tarball carries a private key, so keep the
# directory root-only. mkdir -p is a safety net under RequiresMountsFor.
mkdir -p -- "$DEST_DIR"
chmod 0700 -- "$DEST_DIR" 2>/dev/null || true

# ----- back up --------------------------------------------------------
# Timestamped name so each run is a distinct, sortable snapshot. Write to
# a .partial name and rename on success so a crashed run never leaves a
# truncated tarball that looks complete. tar with -C so the archive holds
# a clean relative `proxmox-backup/` tree, not absolute paths.
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
  # (a benign race — PBS may rewrite a ticket/shadow file mid-read; the
  # snapshot is still usable), 2+ = fatal. Tolerate 1, fail on >=2.
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
