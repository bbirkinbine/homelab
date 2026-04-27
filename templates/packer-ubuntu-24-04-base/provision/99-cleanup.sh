#!/usr/bin/env bash
# 99-cleanup.sh
#
# Final cleanup before Packer converts the VM to a template.
# Goal: nothing identifying or secret persists.
#   - SSH host keys removed (cloud-init regenerates on first boot — every
#     clone gets a unique fingerprint)
#   - machine-id reset (likewise — duplicates break DHCP and journald)
#   - apt caches cleared
#   - bash/python history wiped
#   - the build user 'packer' and its sudoers entry are removed
#   - cloud-init seed cache wiped so cloud-init runs cleanly on first clone boot
#
# After this script runs, the only way back into the template is by cloning
# it and letting cloud-init inject SSH keys for a real user.
set -euo pipefail

echo "==> apt clean"
export DEBIAN_FRONTEND=noninteractive
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "==> truncate logs"
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.[0-9]" -delete
find /var/log -type f -exec truncate -s 0 {} \; || true

echo "==> wipe machine-id (cloud-init regenerates on first boot)"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "==> wipe SSH host keys (cloud-init / sshd regenerates on first boot)"
rm -f /etc/ssh/ssh_host_*

echo "==> wipe shell histories"
rm -f /root/.bash_history
rm -f /home/*/.bash_history
history -c || true

echo "==> wipe cloud-init seed cache"
cloud-init clean --logs --seed || true
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance

echo "==> wipe netplan config artifacts from autoinstall"
# Subiquity writes a generated 50-cloud-init.yaml with the build-time NIC
# config. Roles supply their own ipconfig via Proxmox cloud-init drive, so
# remove the build-time file.
rm -f /etc/netplan/50-cloud-init.yaml
rm -f /etc/netplan/00-installer-config.yaml

echo "==> remove build user 'packer' and its sudoers entry"
pkill -KILL -u packer 2>/dev/null || true
userdel -r -f packer 2>/dev/null || true
rm -f /etc/sudoers.d/99-packer-build

echo "==> wipe DHCP leases"
rm -f /var/lib/dhcp/*.leases
rm -f /var/lib/NetworkManager/*.lease 2>/dev/null || true

echo "==> zero free space (best-effort, don't fail the build if it errors)"
dd if=/dev/zero of=/EMPTY bs=1M status=none 2>/dev/null || true
rm -f /EMPTY
sync

echo "==> cleanup done"
