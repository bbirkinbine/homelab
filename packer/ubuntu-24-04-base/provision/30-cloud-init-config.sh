#!/usr/bin/env bash
# 30-cloud-init-config.sh
#
# Lock cloud-init's datasource search to what Proxmox actually provides.
# Without this the VM clone will spend ~2 minutes on first boot probing
# EC2 / OpenStack metadata endpoints that don't exist.
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
echo "==> cloud-init config done"
