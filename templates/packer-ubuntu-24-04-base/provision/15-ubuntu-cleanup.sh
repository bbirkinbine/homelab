#!/usr/bin/env bash
# 15-ubuntu-cleanup.sh
#
# Ubuntu-specific noise removal. Subiquity ships an image with snap, Ubuntu
# Pro nag in apt, and a few cron-y things we don't want phoning home. The
# offline Root CA VM clones from this image — every "checks for updates"
# timer is a potential exfil channel during the brief windows the offline
# VM is powered on.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------------------
# Snap — purge entirely. Roles that want snap can re-install (none in this
# homelab plan to). 'apt-mark hold' prevents re-pull as a recommended dep.
# ----------------------------------------------------------------------------
echo "==> purging snapd"
systemctl stop snapd.socket snapd.service snapd.seeded.service 2>/dev/null || true
apt-get -y purge snapd gnome-software-plugin-snap 2>/dev/null || true
apt-mark hold snapd
rm -rf /snap /var/snap /var/lib/snapd /root/snap
rm -rf /home/*/snap

# ----------------------------------------------------------------------------
# Ubuntu Pro / advantage tools — keep installed (used for ESM if we ever
# enable it) but turn off the apt_news fetcher so plain `apt update` doesn't
# call home.
# ----------------------------------------------------------------------------
echo "==> disabling Ubuntu Pro apt_news"
if command -v pro >/dev/null 2>&1; then
  pro config set apt_news=false || true
fi

# ----------------------------------------------------------------------------
# motd-news — fetches motd from Canonical on every login.
# ----------------------------------------------------------------------------
echo "==> disabling motd-news"
if [[ -f /etc/default/motd-news ]]; then
  sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
fi
systemctl disable --now motd-news.timer motd-news.service 2>/dev/null || true

# ----------------------------------------------------------------------------
# needrestart — Ubuntu's "do you want to restart services?" interactive
# prompt during apt operations. Set to never-prompt; roles can re-enable.
# ----------------------------------------------------------------------------
echo "==> setting needrestart to non-interactive"
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s|^#\\?\\\$nrconf{restart}.*|\\\$nrconf{restart} = 'a';|" /etc/needrestart/needrestart.conf
  sed -i "s|^#\\?\\\$nrconf{kernelhints}.*|\\\$nrconf{kernelhints} = 0;|" /etc/needrestart/needrestart.conf
fi

# ----------------------------------------------------------------------------
# update-notifier — desktop nag we don't need on a server image.
# ----------------------------------------------------------------------------
echo "==> removing update-notifier-common (server image)"
apt-get -y purge update-notifier-common 2>/dev/null || true

echo "==> ubuntu-cleanup done"
