#!/usr/bin/env bash
# 00-wait-for-cloud-init.sh
#
# Subiquity hands off to a real cloud-init that runs at first boot. Wait for
# it to settle before we touch anything else, otherwise apt/dpkg locks
# collide with the installer's own first-boot package fixup.
set -euo pipefail

if command -v cloud-init >/dev/null 2>&1; then
  echo "==> waiting for cloud-init to finish..."
  cloud-init status --wait || true
fi

# Give unattended-upgrades a chance to actually start before we declare idle.
# Without this, the lock check can race past the cron firing and we'd hit a
# lock contention in the next provisioner.
sleep 15

# Poll the actual lock files apt/dpkg use, not process names. Same mechanism
# apt itself uses to detect contention, so no false positives from orphan
# parent shells and no false negatives from systemd-run wrappers.
LOCKS=(
  /var/lib/dpkg/lock-frontend
  /var/lib/dpkg/lock
  /var/lib/apt/lists/lock
)
TIMEOUT=600

for i in $(seq 1 "$TIMEOUT"); do
  busy=0
  for lock in "${LOCKS[@]}"; do
    if [ -e "$lock" ] && sudo fuser "$lock" >/dev/null 2>&1; then
      busy=1
      break
    fi
  done
  if [ "$busy" -eq 0 ]; then
    echo "apt/dpkg locks free after ${i}s"
    exit 0
  fi
  sleep 1
done

echo "WARN: apt/dpkg locks still held after ${TIMEOUT}s; dumping holders before continuing."
for lock in "${LOCKS[@]}"; do
  [ -e "$lock" ] || continue
  echo "  $lock:"
  sudo fuser -v "$lock" 2>&1 | sed 's/^/    /' || true
done
ps auxf | grep -E 'apt|dpkg|unattended' | grep -v grep | sed 's/^/    /' || true
exit 0
