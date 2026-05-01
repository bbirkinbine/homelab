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

# Belt-and-suspenders: also wait for any apt/dpkg processes to clear.
for i in $(seq 1 120); do
  if ! pgrep -x apt >/dev/null && \
     ! pgrep -x apt-get >/dev/null && \
     ! pgrep -x unattended-upgr >/dev/null && \
     ! pgrep -x dpkg >/dev/null; then
    echo "apt/dpkg idle after ${i}s"
    exit 0
  fi
  sleep 1
done

echo "WARN: apt/dpkg still busy after 120s; continuing anyway."
exit 0
