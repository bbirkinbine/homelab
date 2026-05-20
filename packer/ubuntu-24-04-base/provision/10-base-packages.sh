#!/usr/bin/env bash
# 10-base-packages.sh
#
# Install everything that belongs in the universal base image.
# NOTHING role-specific here. k3s, container runtimes, databases,
# application stacks — those layer on per-role.
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

# Set vim.tiny as the system-wide default editor. Without this,
# /usr/bin/editor (used by sudoedit, visudo, crontab -e, debian-style
# git config defaults, etc.) lands on nano — auto mode picks nano on
# its priority 40, ahead of vim.tiny's 15. vim.tiny is plenty for the
# occasional config edit and we already ship it; not pulling in the
# full vim package (~50 MB) for every VM in the lab. On any role that
# wants vim.basic instead, install `vim` and re-run
# `update-alternatives --set editor /usr/bin/vim.basic`. Flip back to
# nano with `update-alternatives --auto editor` if ever needed.
echo "==> set vim.tiny as the default editor"
update-alternatives --set editor /usr/bin/vim.tiny

echo "==> enable services that should run on every role"
systemctl enable --now qemu-guest-agent
systemctl enable --now chrony
systemctl enable --now auditd
systemctl enable --now rsyslog
systemctl enable ssh

echo "==> base packages done"
