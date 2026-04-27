#!/usr/bin/env bash
# 10-base-packages.sh
#
# Install everything that belongs in the universal base image.
# NOTHING role-specific here. SoftHSM, OpenBao, YubiHSM SDK, k3s, docker —
# those layer on per-role.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> apt update + full upgrade"
apt-get update -y
apt-get -y -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        full-upgrade

echo "==> base packages"
apt-get install -y --no-install-recommends \
  ca-certificates \
  cloud-init \
  cloud-initramfs-growroot \
  cloud-guest-utils \
  curl \
  chrony \
  qemu-guest-agent \
  openssh-server \
  sudo \
  rsyslog \
  auditd \
  audispd-plugins \
  ufw \
  unattended-upgrades \
  apt-listchanges \
  apt-transport-https \
  gnupg \
  python3 \
  python3-apt \
  jq \
  vim-tiny \
  less \
  htop

echo "==> apt clean"
apt-get autoremove -y --purge
apt-get clean

echo "==> enable services that should run on every role"
systemctl enable --now qemu-guest-agent
systemctl enable --now chrony
systemctl enable --now auditd
systemctl enable --now rsyslog
systemctl enable ssh

echo "==> base packages done"
