#!/usr/bin/env bash
# 30-cloud-init-config.sh
#
# Lock cloud-init's datasource search to what Proxmox actually provides,
# and bound the systemd-networkd-wait-online stall. Without these the VM
# clone will spend ~2 minutes on first boot probing EC2 / OpenStack
# metadata endpoints that don't exist AND another ~2 minutes blocked at
# systemd-networkd-wait-online because Ubuntu 24.04 ships that unit with
# no timeout.
set -euo pipefail

echo "==> restricting cloud-init datasources to NoCloud + ConfigDrive"
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-homelab-datasource.cfg <<'EOF'
# Managed by packer-ubuntu-24-04-base provisioner.
# Proxmox's cloud-init drive shows up as either NoCloud or ConfigDrive
# depending on configuration. None terminates the search instead of
# falling through to network metadata sources.
datasource_list: [ NoCloud, ConfigDrive, None ]

# Don't fight the role layer — let cloud-init manage /etc/hosts so the
# hostname module works cleanly when roles set their own hostname.
manage_etc_hosts: true
preserve_hostname: false
EOF
chmod 0644 /etc/cloud/cloud.cfg.d/99-homelab-datasource.cfg

# Ubuntu 24.04 ships netplan, which cloud-init drives via its 'network'
# module. Make sure that module is enabled (it is by default) so role-layer
# IP config from the Proxmox cloud-init drive actually applies.

echo "==> bounding systemd-networkd-wait-online stall to 30s"
# Ubuntu 24.04's systemd-networkd-wait-online.service ships with no
# timeout — when an interface fails to come online (e.g. transient bridge
# config issues, or the brief window during cloud-init's first run before
# netplan is generated), boot stalls at this unit until manual
# intervention. `bpg/proxmox`'s `tofu apply` then races against its own
# QEMU-agent timeout (~13-15 min) and may fail. The override below caps
# the wait at 30s using `--any --timeout=30`:
#   --any         "succeed as soon as ANY managed interface is online"
#                 (single-NIC server VMs only need one; default --all
#                 requires every managed link to come up).
#   --timeout=30  fails the unit after 30s instead of waiting forever.
# `ExecStart=` (empty) is required before re-specifying ExecStart — drop-ins
# append to ExecStart by default, but for unit replacement you must clear
# the original first. See `man systemd.service` § Examples.
mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d
cat > /etc/systemd/system/systemd-networkd-wait-online.service.d/timeout.conf <<'EOF'
# Managed by packer-ubuntu-24-04-base provisioner.
# Bound the wait-online stall to 30s; --any lets a single-NIC VM proceed
# as soon as that NIC is online. See 30-cloud-init-config.sh for context.
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --any --timeout=30
EOF
chmod 0644 /etc/systemd/system/systemd-networkd-wait-online.service.d/timeout.conf

echo "==> cloud-init config done"
