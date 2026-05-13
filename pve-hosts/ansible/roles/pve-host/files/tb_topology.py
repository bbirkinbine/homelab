#!/usr/bin/env python3
# Emits a JSON snapshot of the live Thunderbolt topology, used by
# tasks/thunderbolt.yml steps (b) + (c) for peer enrollment and
# pci_path discovery. Stdout-only; any exception falls through to
# Ansible's script module as a non-zero exit.
#
# Output schema:
#   {
#     "peers":   [{sysfs_id, device_name, unique_id, authorized, pci_bdf}, ...],
#     "netdevs": [{iface, pci_bdf, device_id, device_name}, ...]
#   }
#
# Peer-host entries under /sys/bus/thunderbolt/devices match X-1
# (where X is the domain index). Adapters/retimers are X-Y:N.N and
# the local-host pseudo-device is X-0; both are filtered out. Only
# Intel-Corp peers are reported (the Razer Core X eGPU on pve12t
# shows up as vendor "Razer" and is correctly ignored here).

import json
import os
import re


PCI_BDF_RE = re.compile(r"/(\d{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f])/domain\d+/")


def read_attr(directory, name):
    try:
        with open(os.path.join(directory, name)) as f:
            return f.read().strip()
    except OSError:
        return ""


def find_peer_dir(start):
    """Walk up the parent chain from `start` until we find a directory
    containing both `device_name` and `vendor_name` — that's the TB
    peer host device. Used because thunderbolt-net netdevs' `device`
    symlink resolves to a service entry one level under the peer host
    (e.g. `.../0-1/0-1.0`), not the peer host itself."""
    cur = start
    while cur and cur != "/":
        if os.path.exists(os.path.join(cur, "device_name")) and \
           os.path.exists(os.path.join(cur, "vendor_name")):
            return cur
        cur = os.path.dirname(cur)
    return None


def collect_peers():
    peers = []
    tb_dev_dir = "/sys/bus/thunderbolt/devices"
    if not os.path.isdir(tb_dev_dir):
        return peers
    for entry in sorted(os.listdir(tb_dev_dir)):
        # Peer hosts are X-Y where Y >= 1. X-0 is the local-host
        # pseudo-device for domain X; entries with `:` are retimers /
        # adapters. We accept any X-Y (Y>=1) on the off chance a
        # daisy-chain ever exposes X-2, etc.
        if not re.match(r"^\d+-[1-9]\d*$", entry):
            continue
        devpath = os.path.realpath(os.path.join(tb_dev_dir, entry))
        if read_attr(devpath, "vendor_name") != "Intel Corp.":
            continue
        m = PCI_BDF_RE.search(devpath)
        peers.append({
            "sysfs_id": entry,
            "device_name": read_attr(devpath, "device_name"),
            "unique_id": read_attr(devpath, "unique_id"),
            "authorized": read_attr(devpath, "authorized"),
            "pci_bdf": m.group(1) if m else "",
        })
    return peers


def collect_netdevs():
    netdevs = []
    net_dir = "/sys/class/net"
    if not os.path.isdir(net_dir):
        return netdevs
    for entry in sorted(os.listdir(net_dir)):
        if not entry.startswith("thunderbolt"):
            continue
        # Resolve the netdev's `device` symlink, then walk up to the
        # actual peer host directory. The realpath typically lands at
        # the thunderbolt-net service entry one level deeper.
        netpath = os.path.realpath(os.path.join(net_dir, entry, "device"))
        peer_path = find_peer_dir(netpath)
        if not peer_path:
            continue
        # PCI BDF from the path; device_id is the peer directory's basename.
        # Using basename instead of regex back-tracking avoids the
        # lazy-vs-greedy gotcha where `.*?(\d+-\d+)` would match the first
        # X-Y (the local-host `0-0`) instead of the peer (`0-1`).
        bdf_match = PCI_BDF_RE.search(peer_path)
        if not bdf_match:
            continue
        netdevs.append({
            "iface": entry,
            "pci_bdf": bdf_match.group(1),
            "device_id": os.path.basename(peer_path),
            "device_name": read_attr(peer_path, "device_name"),
        })
    return netdevs


if __name__ == "__main__":
    print(json.dumps({"peers": collect_peers(), "netdevs": collect_netdevs()}))
