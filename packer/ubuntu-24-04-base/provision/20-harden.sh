#!/usr/bin/env bash
# 20-harden.sh
#
# Light-touch hardening defaults. NOT a CIS benchmark run.
# Goals:
#   - SSH: key-only, no root, password auth off (cloud-init injects keys at first boot)
#   - ufw: default-deny, allow 22/tcp
#   - sysctl: kernel-info-leak mitigations
#   - unattended-upgrades: package present, timer DISABLED
#     (the offline-root role must never re-enable; other roles may)
set -euo pipefail

# ----------------------------------------------------------------------------
# SSHD
# ----------------------------------------------------------------------------
echo "==> hardening sshd_config"
sshd_drop="/etc/ssh/sshd_config.d/10-homelab.conf"
cat > "${sshd_drop}" <<'EOF'
# Managed by packer-ubuntu-24-04-base provisioner.
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
AllowTcpForwarding yes
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
MaxAuthTries 3
Banner /etc/issue.net
EOF
chmod 0644 "${sshd_drop}"

# Ubuntu 24.04 uses systemd socket activation for ssh. The stock drop-in
# above is read by sshd on every connection. Validate config; don't bounce
# the daemon mid-build (Packer is connected over SSH right now).
sshd -t -f /etc/ssh/sshd_config || {
  echo "ERROR: sshd config validation failed"
  exit 1
}

# ----------------------------------------------------------------------------
# UFW
# ----------------------------------------------------------------------------
echo "==> configuring ufw"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'ssh'
# 'ufw enable' would activate immediately, blocking the running Packer SSH.
# Stage rules + enable ufw service for next boot.
systemctl enable ufw
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf

# ----------------------------------------------------------------------------
# sysctl
# ----------------------------------------------------------------------------
echo "==> sysctl hardening"
cat > /etc/sysctl.d/90-homelab-hardening.conf <<'EOF'
# Managed by packer-ubuntu-24-04-base provisioner.

# Kernel info-leak mitigations
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1

# Network basics
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1

# IPv6 — homelab is dual-stack-aware but we don't accept RAs by default;
# roles that need RA enable per-interface.
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0
EOF

# ----------------------------------------------------------------------------
# unattended-upgrades — INSTALLED but DISABLED in the base image.
#
# Some VMs cloned from this image must never auto-update (locked-down or
# network-restricted workloads). Roles that should auto-update re-enable
# the timer.
# ----------------------------------------------------------------------------
echo "==> disabling unattended-upgrades timer (roles re-enable as appropriate)"
systemctl disable --now apt-daily.timer apt-daily.service \
  apt-daily-upgrade.timer apt-daily-upgrade.service 2>/dev/null || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# Defense-in-depth: even if the timers come back, the periodic config tells
# unattended-upgrades to do nothing.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
EOF

# ----------------------------------------------------------------------------
# auditd
# ----------------------------------------------------------------------------
systemctl enable auditd
systemctl restart auditd || true

# ----------------------------------------------------------------------------
# Login banner
# ----------------------------------------------------------------------------
cat > /etc/issue.net <<'EOF'
Authorized access only. Activity is logged.
EOF
# Banner directive lives in the sshd drop-in file above.

echo "==> hardening done"
