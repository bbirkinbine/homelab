# CLAUDE.md — pve-hosts (layer 0 PVE host bootstrap)

> **Purpose.** Scaffolding spec + persistent context for Claude Code (or any AI tool) implementing the `pve-host` Ansible role under `pve-hosts/ansible/roles/pve-host/`. Read this file fully before generating anything. The folder skeleton already exists; your job is to fill in the role's task/template/handler/var files per this spec, and to verify the result with the acceptance gates at the bottom.

Read the **repo-level** `CLAUDE.md` at the root of this repository first if you haven't — it covers tone, no-emojis style, public-repo hygiene rules, and the secrets-handling philosophy (operator's local credential store, read at invocation time, never embedded). The conventions below extend those, they don't replace them.

---

## Why this folder exists, in one paragraph

The repo's existing Ansible roles all live under `vms/<role>/ansible/` and configure Linux VMs running on Proxmox. `pve-host` is different: it configures the Proxmox hypervisor hosts themselves. The hosts are the substrate that everything in `vms/` runs on top of. We added a TB4 line-topology fabric between the three nodes for live-migration traffic (decision 2026-05-11); that pushed the per-node config past "I can hold it in my head" complexity, and an Ansible role to capture the per-node baseline became the right time-investment. The authoritative network design lives in the project's private design vault; this role implements its templates.

---

## Cluster context

Three Intel NUCs running Proxmox VE 9.x (Debian 13 / trixie base, deb822 repo format):

| Host | Hardware | TB role | Notes |
|---|---|---|---|
| `pve12t` | NUC12 Pro Tall, i7-1260P, 64 GB DDR4, 512 GB NVMe | leaf (1 TB link) | One TB port permanently holds the Razer Core X + RTX 3090 eGPU. Other TB port connects to `pve13m`. |
| `pve13m` | NUC13 Pro slim, i7-1360P, 64 GB DDR4, 1 TB NVMe | **transit** (2 TB links) | Midpoint of the line topology. Forwards `pve12t`↔`pve13t` traffic. Needs `net.ipv4.ip_forward=1`. |
| `pve13t` | NUC13 Pro Tall, i7-13620H, 64 GB DDR4, 1 TB NVMe | leaf (1 TB link) | Highest core count. One TB port to `pve13m`; one TB port spare. |

Network layers:

1. **2.5GbE** — single port per node, carries management, Corosync ring0, NFS to NAS (Asustor AS6706T), VM bridges. All three nodes + NAS sit on the same switched LAN.
2. **TB4 line topology** — `pve12t ── pve13m ── pve13t`. Two TB4 cables total. Carries live migration + Corosync ring1. `pve13m` is the L3 transit (single point of failure for the TB fabric; acceptable because the fabric is purely additive and falls back to 2.5GbE).

No HA. No Ceph. NFS-on-Asustor for shared storage. PCIe passthrough VMs (the LLM on `pve12t`) are node-pinned and can't migrate.

---

## What the role MUST do

The role brings a freshly-installed Proxmox 9.x host to a baseline ready for the manual `pvecm create` / `pvecm add` step. Specifically, in roughly this task-file order:

1. **`repo.yml` — APT repos.** Replace the enterprise sources with the no-subscription set, deb822 format. Two stanzas: Debian base (trixie + trixie-updates + security) and Proxmox no-subscription. Remove `pve-enterprise.list` if present (legacy single-line format). `apt update` only when the source file changes (via handler).

2. **`packages.yml` — base packages.** Install (state: present, not latest): `ifupdown2`, `vim`, `htop`, `iperf3`, `ethtool`, `bridge-utils`, `lldpd`, `chrony`, `tmux`, `curl`, `jq`, `dnsutils`, `tcpdump`, `pciutils`, `usbutils`. Pull the list from `defaults/main.yml` so it's overridable per host.

3. **`time.yml` — chrony / NTP.** Disable + mask `systemd-timesyncd`. Template `/etc/chrony/chrony.conf` from `chrony.conf.j2`. Enable + start chrony. Restart on config change.

4. **`hosts_file.yml` — `/etc/hosts`.** Template the file from inventory: every cluster member's LAN IP + hostname, plus each TB loopback as `<hostname>-tb`, plus the NAS hostname.

5. **`network.yml` — `/etc/network/interfaces`.** Template the whole file from `interfaces.j2`. The template branches on `tb_role` (see "Template guidance" below). Two key safety notes:
   - **Do NOT auto-reload networking.** Trigger a handler that surfaces the change but does not run `ifreload -a`. Print a clear post-run notice that manual reload is required, ideally from console.
   - Use the host's `pve_lan_iface` var to name the physical NIC for the `vmbr0` bridge.

6. **`thunderbolt.yml` — TB enablement.** Five sub-tasks, in order:
   - **(a) Module load + bolt install.** Install `bolt` package (provides `boltctl` + persistent enrollment daemon). Template `/etc/modules-load.d/thunderbolt.conf` (static — both `thunderbolt` and `thunderbolt_net`). Trigger an immediate `modprobe thunderbolt-net` via handler so the netdevs surface within the same play (the modules-load.d file only fires at next boot).
   - **(b) Enroll peer hosts.** TB domain security on ASUS NUC13 / NUC12 firmware stays at `security=user` (SL1) — the BIOS does not expose a setting to change it. Persistent peer-trust is the role's job. For each entry in `tb_links`, find the TB device under `/sys/bus/thunderbolt/devices/*-1` whose `device_name` matches `link.peer`, capture its `unique_id`. If `boltctl list` does not already show the UUID with `policy: auto`, run `boltctl enroll --policy=auto <uuid>`. Idempotent: re-runs are no-ops. If no matching TB device is present (cable unplugged, peer host down), warn and skip — do not fail the play.
   - **(c) Auto-discover `pci_path`.** Wait briefly for netdevs to enumerate after enrollment, then scan `/sys/class/net/thunderbolt*`. For each netdev, walk to its parent TB device, read `device_name`, match against `tb_links[].peer`, and derive the parent PCIe controller path (the `domain*` device's parent `0000:XX:XX.X` path). Store as a per-link fact (e.g. `tb_links_resolved`) using `set_fact`. This replaces what was previously an `inventory.yml`-declared `pci_path` field.
   - **(d) Render `.link` files.** For each resolved link, template a `/etc/systemd/network/10-tb-<name>.link` file matched on the discovered path. Skip + warn for links where step (c) didn't resolve a path (e.g. cable not yet plugged).
   - **(e) Transit forwarding.** On `pve13m` only (`when: ip_forwarding_enabled | default(false)`), template `/etc/sysctl.d/99-tb-forward.conf` containing `net.ipv4.ip_forward = 1` and trigger `sysctl --system` via handler.

7. **`tuning.yml` — sysctl network tuning.** Template `/etc/sysctl.d/99-pve-host.conf` with high-MTU-friendly buffers (`net.core.rmem_max`, `wmem_max`, `tcp_rmem`, `tcp_wmem`). Conservative defaults; override-friendly via host vars.

8. **`nfs.yml` — NFS mount.** Ensure `/mnt/nas-vms` exists via `ansible.builtin.file`. Use `ansible.posix.mount` to manage the fstab entry with `vers=4.2`, `_netdev`, `noatime`, and mount it. (Proxmox-level NFS storage registration via `pvesh` is NOT this role's job — manual one-time step in the cluster bring-up doc.)

9. **`firewall.yml` — pve-firewall baseline (staged inert).** Stage `cluster.fw` on a regular filesystem (`/root/.cluster.fw.staged`), then `cp` it into `/etc/pve/firewall/cluster.fw`. Two-task pattern is required because Ansible's `template:` module's atomic-move (even with `unsafe_writes: true`) returns EPERM against pmxcfs; plain `cp` works. **CRITICAL:** the destination lives under `/etc/pve/`, which is pmxcfs-replicated. Both tasks scoped via `run_once: true`, `delegate_to: "{{ ansible_play_hosts | first }}"`. Pre-cluster, pmxcfs is single-node so the file only exists on the delegate; the template ships `enable: 0` so the firewall is staged-but-inert and operator flips to `1` after cluster join. Rules:
   - Default policies: `IN DROP`, `OUT ACCEPT`, `FORWARD ACCEPT` (forward needed for pve13m transit).
   - Allow from LAN subnet: SSH (22), Proxmox web UI (8006), Corosync (5404-5405 udp), ICMP echo.
   - Allow NFS loopback (127.0.0.1:2049) — outbound from this host to NAS doesn't need an inbound rule.
   - Allow cluster-internal TB traffic on BOTH the /31 link subnet (`10.10.0.0/24`) and the /32 loopback subnet (`10.10.10.0/24`). Kernel source-IP selection asymmetry between the two means both must pass for diagnostics + production traffic.
   - Log dropped packets (optional, on by default).

10. **`users.yml` — SSH keys.** `ansible.posix.authorized_key` to install `admin_ssh_pubkey` for `root`. No-op if the key is empty (so initial scaffold doesn't break). Do not add new local user accounts; Proxmox uses root + PAM.

Wire all of these into `tasks/main.yml` in order via `ansible.builtin.import_tasks:` (not `include_tasks` — we want static composition so syntax errors surface during a `--syntax-check`).

---

## What the role MUST NOT do

These are deliberately out of scope. Each has quorum, hardware, or operator-state risk that breaks declarative automation:

- **`pvecm create` or `pvecm add`.** Manual, quorum-aware step. Botched re-join can fence a node. Never automate.
- **`/etc/pve/corosync.conf` edits after initial cluster setup.** pmxcfs-replicated; Ansible would race the cluster. If a future need to manage corosync via IaC arises, raise it as a question first.
- **`/etc/pve/storage.cfg` (NFS storage registration).** Same reason as above. Manual one-time `pvesh create /storage` call, documented in the cluster bring-up runbook (vault).
- **VM creation.** That's `vms/<role>/terraform/` + cloud-init's job.
- **PCIe / eGPU passthrough.** Brittle, hardware-specific; lives in `docs/proxmox-gpu-passthrough.md`. Pure manual.
- **GRUB or kernel parameter edits.** Even if a future feature wants `intel_iommu=on`, surface it as a manual-step note in role output and stop. Don't touch GRUB without explicit instruction.
- **Drive partitioning, LVM-thin pool creation, LUKS partitions.** Set up at install time. `nuc12-fast` (LLM cache on `pve12t`'s dedicated 2.5" SATA SSD, VG `nuc12fast_vg`) is sacred ground for this role — assume it exists, don't manage it. The Root CA partition path was retired 2026-05-11 (encryption moved in-VM); no host-side LUKS to manage.
- **Reboots.** If something would normally require one (kernel module loaded that wasn't present at boot, etc.), set `register:` on the task and surface a "Manual reboot recommended" summary at end of play. Don't reboot autonomously.
- **`apt upgrade` / `apt dist-upgrade`.** Package state is `present`, not `latest`. Upgrades are a separate operator decision.

---

## Folder skeleton (already created)

The structure under `pve-hosts/ansible/roles/pve-host/` is in place with `.gitkeep` placeholders. Your job: replace `.gitkeep` with real files. Final layout you should produce:

```
pve-hosts/ansible/roles/pve-host/
├── defaults/
│   └── main.yml                         # overridable defaults (package list, NFS opts, etc.)
├── vars/
│   └── main.yml                         # role-internal constants (rare; mostly empty)
├── tasks/
│   ├── main.yml                         # import_tasks in order
│   ├── repo.yml
│   ├── packages.yml
│   ├── time.yml
│   ├── hosts_file.yml
│   ├── network.yml
│   ├── thunderbolt.yml
│   ├── tuning.yml
│   ├── nfs.yml
│   ├── firewall.yml
│   └── users.yml
├── handlers/
│   └── main.yml                         # restart chrony, sysctl --system, etc.
├── templates/
│   ├── etc/
│   │   ├── apt/
│   │   │   └── sources.list.d/
│   │   │       └── pve-no-subscription.sources.j2
│   │   ├── chrony/
│   │   │   └── chrony.conf.j2
│   │   ├── hosts.j2
│   │   ├── modules-load.d/
│   │   │   └── thunderbolt.conf.j2
│   │   ├── network/
│   │   │   └── interfaces.j2
│   │   ├── pve/
│   │   │   └── firewall/
│   │   │       └── cluster.fw.j2
│   │   ├── sysctl.d/
│   │   │   ├── 99-pve-host.conf.j2
│   │   │   └── 99-tb-forward.conf.j2
│   │   └── systemd/
│   │       └── network/
│   │           └── 10-tb-link.link.j2
├── files/
│   └── (empty unless you find a static file that makes sense)
└── meta/
    └── main.yml                         # galaxy_info: minimal — name, author, supported platforms
```

Mirror `/etc/` substructure inside `templates/` so the relationship between template file and target path is obvious. The convention is borrowed from `vms/openbao/ansible/roles/openbao/templates/openbao.hcl.j2` — flat there because the role only writes one config file, but the parallel structure helps when a role writes many.

---

## Template guidance — the high-leverage ones

### `templates/etc/network/interfaces.j2`

Branches on `tb_role`. Pseudocode:

```jinja
# /etc/network/interfaces — managed by Ansible (pve-host role)
# Do not edit by hand. See pve-hosts/ansible/roles/pve-host/ for source.

auto lo
iface lo inet loopback

# 2.5GbE management — vmbr0 bridge over the physical NIC
auto {{ pve_lan_iface }}
iface {{ pve_lan_iface }} inet manual

auto vmbr0
iface vmbr0 inet static
    address {{ pve_lan_ip }}/{{ pve_lan_subnet | ipaddr('prefix') }}
    gateway {{ pve_lan_gateway }}
    bridge-ports {{ pve_lan_iface }}
    bridge-stp off
    bridge-fd 0
    mtu 1500

{% for link in tb_links %}
# Thunderbolt link to {{ link.peer }}
auto {{ link.name }}
iface {{ link.name }} inet static
    address {{ link.local_addr }}
    mtu 65520
{% endfor %}

# Loopback alias for migration network ({{ pve_tb_migration_subnet }})
auto lo:10
iface lo:10 inet static
    address {{ tb_loopback }}/32

{% if tb_role == 'leaf' %}
# Leaf: all TB peers reachable via the single TB neighbor
{% for peer_name, peer in hostvars.items() if peer_name != inventory_hostname and 'tb_loopback' in peer %}
    post-up ip route add {{ peer.tb_loopback }}/32 via {{ tb_links[0].peer_addr }} dev {{ tb_links[0].name }}
{% endfor %}
{% elif tb_role == 'transit' %}
# Transit: each peer's loopback reachable via its directly-connected TB interface (/31 point-to-point, no next-hop needed)
{% for link in tb_links %}
{% set peer_host = hostvars[link.peer] %}
    post-up ip route add {{ peer_host.tb_loopback }}/32 dev {{ link.name }}
{% endfor %}
{% endif %}
```

This is illustrative — refine the Jinja so it's clean and matches the inventory schema. Use `ansible.utils.ipaddr` (from `ansible.utils` collection — add to `requirements.yml` if you decide to use it) or compute the prefix manually.

### `templates/etc/systemd/network/10-tb-link.link.j2`

Rendered once per entry in `tb_links_resolved` (the fact populated by `thunderbolt.yml` step (c) — NOT directly from inventory's `tb_links`, because the PCI path is discovered at run time). Pin name by PCI path:

```ini
# Pins the TB-net interface for the {{ link.name }} link.
# Without this, interface names depend on enumeration order and can
# flap across reboots — silently breaking /etc/network/interfaces.
# pci_path is auto-discovered by thunderbolt.yml step (c) from
# /sys/class/net/thunderbolt*'s parent TB controller path; it is not
# declared in inventory.yml.

[Match]
Path={{ link.pci_path }}
Driver=thunderbolt-net

[Link]
Name={{ link.name }}
MTUBytes=65520
```

Filename pattern: `10-tb-{{ link.name }}.link` (e.g. `10-tb-tbnet-13m.link`).

### `templates/etc/sysctl.d/99-tb-forward.conf.j2`

Two lines. Only rendered on the transit node.

```
# Enable IPv4 forwarding for the TB transit role.
# Required on pve13m only: pve12t <-> pve13t traffic transits this node.
net.ipv4.ip_forward = 1
```

### `templates/etc/sysctl.d/99-pve-host.conf.j2`

Conservative defaults. Goal: don't strangle high-MTU TB-net flows.

```
# Network buffer tuning for high-MTU TB-net flows (MTU 65520).
# These ceilings are upper bounds, not commitments — the kernel
# autotunes within them.
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.ipv4.tcp_rmem = 4096 87380 268435456
net.ipv4.tcp_wmem = 4096 65536 268435456
```

### `templates/etc/hosts.j2`

```jinja
127.0.0.1   localhost
::1         localhost ip6-localhost ip6-loopback

# Cluster nodes — LAN addresses
{% for h in groups['pve_hosts'] %}
{{ hostvars[h].pve_lan_ip }}   {{ h }}.local {{ h }}
{% endfor %}

# Cluster nodes — TB loopbacks
{% for h in groups['pve_hosts'] %}
{{ hostvars[h].tb_loopback }}   {{ h }}-tb
{% endfor %}

# NAS
{{ nas_ip }}   {{ nas_hostname }}
```

### `templates/etc/apt/sources.list.d/pve-no-subscription.sources.j2`

deb822 format, two stanzas. Reference: https://pve.proxmox.com/wiki/Package_Repositories

```
Types: deb
URIs: http://deb.debian.org/debian
Suites: {{ pve_repo_distribution }} {{ pve_repo_distribution }}-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: {{ pve_repo_distribution }}-security
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: {{ pve_repo_distribution }}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

The `proxmox-archive-keyring.gpg` is shipped by the `proxmox-archive-keyring` package, already present on a stock install. If missing, install it via apt before enabling the repo.

### `templates/etc/pve/firewall/cluster.fw.j2`

`pve-firewall` syntax. The role applies this file once via delegate_to (see firewall.yml task instructions). Document the pmxcfs-replication caveat in a top-of-file comment.

```text
[OPTIONS]
# enable: 0 by default — role drops the rules but doesn't auto-enable.
# Pre-cluster, pmxcfs is single-node so cluster.fw only exists on the
# delegate host; turning it on there alone produces asymmetric state
# (delegate filters, peers don't) which breaks TB transit. Operator
# flips to 1 after `pvecm create` + `pvecm add` lands.
enable: 0
policy_in: DROP
policy_out: ACCEPT
policy_forward: ACCEPT
log_ratelimit: enable=1,rate=1/second,burst=5

[RULES]
# LAN admin access
IN ACCEPT -source {{ pve_lan_subnet }} -p tcp -dport 22 -log nolog # SSH
IN ACCEPT -source {{ pve_lan_subnet }} -p tcp -dport 8006 -log nolog # Proxmox web UI
IN ACCEPT -source {{ pve_lan_subnet }} -p icmp -log nolog # ping

# Corosync (cluster heartbeat) — ring0 on LAN, ring1 on TB subnet
IN ACCEPT -source {{ pve_lan_subnet }} -p udp -dport 5404:5405 -log nolog
IN ACCEPT -source {{ pve_tb_migration_subnet }} -p udp -dport 5404:5405 -log nolog

# TB fabric — accept BOTH the /31 link subnet (diagnostic pings, kernel
# default source-IP selection) and the /32 loopback subnet (migration,
# pvesr, corosync ring1).
IN ACCEPT -source 10.10.0.0/24 -log nolog

# NFS to NAS already restricted by the NAS-side export; allow loopback only
IN ACCEPT -source 127.0.0.1 -p tcp -dport 2049 -log nolog

# TB fabric — all cluster-internal traffic between the loopback addresses
IN ACCEPT -source {{ pve_tb_migration_subnet }} -log nolog
```

If `pve-firewall` syntax fights you, fall back to documenting the rules in a comment block and leaving the cluster.fw template empty. The cluster will still come up with the firewall disabled at the cluster level; nodes won't ship locked-down. Surface the gap clearly in `SCAFFOLD-NOTES.md` if you do this.

---

## Inventory schema (already in `inventory.yml.example`)

The template inventory is at `pve-hosts/ansible/inventory.yml.example`. It defines:

- Three hosts (`pve12t`, `pve13m`, `pve13t`) in the `pve_hosts` group.
- Per-host vars: `pve_lan_iface`, `pve_lan_ip`, `tb_role`, `tb_loopback`, `tb_links` (list of dicts with `name`, `peer`, `local_addr`, `peer_addr`), `ip_forwarding_enabled`. The `pci_path` field is NOT declared in inventory — `thunderbolt.yml` step (c) discovers it from sysfs at run time and stores it as a per-link fact. Operator harvests nothing.
- Group-level vars: `pve_lan_subnet`, `pve_lan_gateway`, `pve_tb_migration_subnet` (fixed: `10.10.10.0/24`), `nas_*`, `pve_repo_distribution` (fixed: `trixie`), `chrony_servers`, `admin_ssh_pubkey`.

When templates need values, pull from `hostvars[inventory_hostname]` or `groups['pve_hosts']` — both already resolve correctly from this layout. Do not require Brian to migrate to `group_vars/host_vars/` split; the inline layout is intentional and matches the convention in `vms/*/ansible/inventory.yml.example`.

---

## Idempotency, safety, style — non-negotiable

1. **Every task must be idempotent.** Re-running on a healthy host must report `changed=0`.
2. **Network changes never auto-apply.** Trigger a handler that prints a clear "Network config staged. Manual `ifreload -a` from console required" message — but do not run the reload. Document this in `tasks/network.yml`'s header comment.
3. **No reboots.** Even if a kernel module addition or sysctl would benefit from one, surface it; don't trigger it.
4. **Fail loudly on missing required vars.** Use `ansible.builtin.assert` early in `tasks/main.yml` to validate `pve_lan_ip`, `tb_loopback`, and `tb_role` are set per host. Empty `admin_ssh_pubkey` is allowed (warn, don't fail) so initial scaffold passes.
5. **Don't touch `/etc/pve/` from multiple hosts.** Files under `/etc/pve/` are pmxcfs-replicated; writing them from N hosts simultaneously is a race. Use `run_once: true` + `delegate_to: "{{ ansible_play_hosts | first }}"` and add an inline comment every single time you do this explaining why.
6. **FQCN everywhere.** Use `ansible.builtin.copy`, `ansible.posix.mount`, `community.general.ufw`, etc. — never bare module names.
7. **Header comments on every file.** Match the openbao role style — what the file does, when it runs, the idempotency story, any quirks. Be substantive; future-Brian (and future-Claude) will read this without context.
8. **No emojis. Avoid the words "genuinely", "straightforward", "actually".** Repo convention from the root CLAUDE.md.
9. **Comments cite vault docs in `[[bracketed-name]]` form.** Same as the existing repo style.

---

## Acceptance gates — before claiming done

Run all of these. None should error.

```bash
# 1. Syntax check
cd pve-hosts/ansible
ansible-playbook -i inventory.yml.example site.yml --syntax-check

# 2. Dry-run / diff (no hosts reachable is fine for this gate — we want
# template resolution + task graph to succeed)
ansible-playbook -i inventory.yml.example site.yml --check --diff \
  --connection=local --inventory-extra-vars 'ansible_check_mode=true' \
  || true   # connection errors expected; look for template/task errors only

# 3. Lint
ansible-lint pve-hosts/ansible/roles/pve-host/

# 4. Render check — per-node template output is sane
# (write a tiny script using ansible's `template` lookup, or use molecule if you wire it up)
```

For each of the three hosts, verify that:

All three hosts render `vmbr0` over `nic0` (the PVE 9.x installer's per-host `.link` file at `/usr/local/lib/systemd/network/50-pmx-nic0.link` renames the management NIC by MAC; verify with `ip link` if `pve_lan_iface` is wrong in inventory).

- **`pve12t`** renders `interfaces.j2` with:
  - `vmbr0` over `nic0` at the LAN IP
  - one TB stanza named `tbnet-13m` at `10.10.0.0/31`, MTU 65520
  - `lo:10` at `10.10.10.12/32`
  - two `post-up ip route` lines pointing `10.10.10.13/32` and `10.10.10.14/32` via `10.10.0.1` on `tbnet-13m`

- **`pve13m`** renders:
  - `vmbr0` over `nic0`
  - two TB stanzas: `tbnet-12t` at `10.10.0.1/31`, `tbnet-13t` at `10.10.0.2/31`
  - `lo:10` at `10.10.10.13/32`
  - two `post-up ip route` lines using `dev` style (no next-hop on /31): `10.10.10.12/32 dev tbnet-12t` and `10.10.10.14/32 dev tbnet-13t`
  - Has `99-tb-forward.conf` rendered (ip_forward=1)

- **`pve13t`** renders:
  - `vmbr0` over `nic0`
  - one TB stanza `tbnet-13m` at `10.10.0.3/31`
  - `lo:10` at `10.10.10.14/32`
  - two `post-up ip route` lines pointing `10.10.10.12/32` and `10.10.10.13/32` via `10.10.0.2` on `tbnet-13m`
  - No `99-tb-forward.conf` (forwarding only on transit node)

If any of these don't match, fix the template and re-verify before signing off.

---

## Things to leave for the operator

These need human input that isn't safe to guess:

- Real LAN subnet + IPs in `inventory.yml` (post-scaffold copy of `.example`).
- Real NAS IP/hostname.
- The operator's SSH pubkey for the `admin_ssh_pubkey` var.
- BIOS settings on each NUC: IOMMU enabled. Document as a manual prereq in the role's README. Note that ASUS NUC13 / NUC12 firmware does NOT expose Thunderbolt security level as a BIOS option (older Intel-branded NUC firmware did) — the domain stays at `security=user` and the role's `thunderbolt.yml` step (b) handles persistent peer-host enrollment via `boltctl`. No operator action required for TB trust on first plug-in beyond running the role.

---

## Justfile integration

Add three recipes to the repo-root `Justfile` once the role is scaffolded. Match the style of the existing `ansible*` recipes (which target `vms/<role>/ansible/`):

```make
# Install pve-host's Galaxy collections.
pve-hosts-deps:
    cd pve-hosts/ansible && ansible-galaxy collection install -r requirements.yml

# Apply pve-host role across all PVE nodes.
pve-hosts:
    cd pve-hosts/ansible && ansible-playbook -i inventory.yml site.yml

# Dry-run / drift check, no changes applied.
pve-hosts-check:
    cd pve-hosts/ansible && ansible-playbook -i inventory.yml site.yml --check --diff
```

Don't try to generalize `just ansible <role>` to work for both `vms/<role>` and `pve-hosts` — the paths and inventory layout are different enough that separate recipes are clearer.

Also append one line to the repo-root `.gitignore` (the `# Ansible` section already covers `vms/*/ansible/inventory.yml`):

```
pve-hosts/ansible/inventory.yml
pve-hosts/ansible/*.retry
pve-hosts/ansible/.ansible_galaxy
```

I've already added these — don't re-add. Verify they're present.

---

## When you're done

Leave a `SCAFFOLD-NOTES.md` at `pve-hosts/ansible/roles/pve-host/SCAFFOLD-NOTES.md` documenting:

- Files you generated (one-line each).
- Any assumptions you made beyond what this CLAUDE.md specified.
- What the operator needs to fill in before the first run (cross-reference "Things to leave for the operator" above).
- Any deviations from this spec, each with a one-paragraph rationale.
- Output of all four acceptance gates (paste the relevant lines, not full logs).

Then update the top-level `README.md` of the repo to mention `pve-hosts/` in the "Quick start" or hardware-section list — keep it to one sentence pointing at `pve-hosts/README.md`. Don't extend the top-level `CLAUDE.md` unless something about this role's existence forces a global rule change.

---

## Design vault (operator-only)

The project's authoritative design docs live in a private vault outside this repo — TB line topology rationale, cluster + NFS architecture, the original role spec, and hardware specifics. If something in this CLAUDE.md is ambiguous and the rationale matters, ask the maintainer for vault access rather than guessing. If you have local access already, the maintainer's working copy is wherever they keep it; this file deliberately doesn't pin the filesystem path.
