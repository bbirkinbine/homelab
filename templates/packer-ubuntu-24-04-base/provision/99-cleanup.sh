#!/usr/bin/env bash
# 99-cleanup.sh
#
# Final cleanup before Packer converts the VM to a template.
# Goal: nothing identifying or secret persists in the template, and clones
# come up clean on first boot.
#   - SSH host keys removed (cloud-init regenerates on first boot — every
#     clone gets a unique fingerprint)
#   - machine-id reset (likewise — duplicates break DHCP and journald)
#   - apt caches cleared
#   - bash/python history wiped
#   - cloud-init seed cache wiped so cloud-init runs cleanly on first clone boot
#   - build user 'packer' deletion is INSTALLED as a systemd one-shot that
#     fires on first boot of any clone (see the deferred-cleanup section
#     below). Inline deletion would kill our own SSH session.
#
# Templates can't be powered on, only cloned; the brief window where a
# template still holds the packer user is therefore not exposed.
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

echo "==> defer packer user removal to first boot of clone"
# Why deferred: deleting the packer user from inside Packer's own SSH session
# tears down the connection mid-script. The work itself completes (script is
# orphaned to PID 1 and runs to the end), but Packer can't reconnect to clean
# up /tmp/script_*.sh and marks the build failed at StepProvision. Punt the
# user delete into a systemd one-shot that runs on the first boot of any
# clone, then self-disables and removes itself.
#
# Templates are never powered on, so this unit only fires on clones. Ordered
# Before=cloud-init-local.service so the build user is gone before any clone
# networking/sshd comes up — eliminates the "known-password user with sudo
# briefly reachable on a clone" window.

install -m 0755 /dev/stdin /usr/local/sbin/packer-cleanup.sh <<'CLEANUP_EOF'
#!/bin/bash
# Installed by packer-ubuntu-24-04-base/provision/99-cleanup.sh.
# One-shot: removes the build-time packer user on first boot of a clone,
# then self-destructs.
set -e
userdel -r -f packer 2>/dev/null || true
rm -f /etc/sudoers.d/99-packer-build
systemctl disable packer-cleanup.service
rm -f /etc/systemd/system/packer-cleanup.service
rm -f /usr/local/sbin/packer-cleanup.sh
systemctl daemon-reload
CLEANUP_EOF

install -m 0644 /dev/stdin /etc/systemd/system/packer-cleanup.service <<'UNIT_EOF'
[Unit]
Description=Remove packer build user from cloned image (one-shot on first boot)
After=local-fs.target
Before=cloud-init-local.service
ConditionPathExists=/usr/local/sbin/packer-cleanup.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/packer-cleanup.sh

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl enable packer-cleanup.service

echo "==> wipe DHCP leases"
rm -f /var/lib/dhcp/*.leases
rm -f /var/lib/NetworkManager/*.lease 2>/dev/null || true

echo "==> trim free space back to the thin pool"
# The disk is provisioned with discard=on,ssd=1 (see ubuntu-24-04-base.pkr.hcl),
# so fstrim's UNMAP requests propagate through QEMU to the lvm-thin pool and
# actually release blocks. dd-zero-fill would do the opposite here — it would
# force the thin volume to allocate every block before deletion.
fstrim -av || true
sync

echo "==> cleanup done"
