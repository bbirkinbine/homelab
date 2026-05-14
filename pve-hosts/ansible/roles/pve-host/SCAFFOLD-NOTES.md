# pve-host — scaffold notes

Implementation notes for the `pve-host` Ansible role, generated against the spec in `pve-hosts/CLAUDE.md`. Captures what was produced, the assumptions baked in, what Brian still needs to fill in, and the validation outcomes.

Originally written at the first-cut shipping point. Revised when the TB sub-task gained five-step shape (bolt enrollment + auto-discovered `pci_path`) — see `pve-hosts/CLAUDE.md` § `thunderbolt.yml` for the current authoritative spec.

Layer-0 spec lives in `pve-hosts/CLAUDE.md`. The role's user-facing entry point is `pve-hosts/README.md`. Read both first.

---

## Files generated

```text
roles/pve-host/
├── defaults/main.yml                       # overridable knobs (packages, NFS opts, firewall toggle, auto-reload safety)
├── vars/main.yml                           # role-internal constants (lo:10 alias name)
├── meta/main.yml                           # Galaxy metadata + collection deps
├── handlers/main.yml                       # reload-systemd / apt-update / restart-chrony / apply-sysctl / surface-networking-change
├── files/
│   └── tb_topology.py                      # sysfs walker -> JSON, used by thunderbolt.yml for peer + netdev discovery
├── tasks/
│   ├── main.yml                            # asserts + ordered import_tasks pipeline
│   ├── repo.yml                            # remove pve-enterprise.list + write deb822 sources
│   ├── packages.yml                        # baseline package set from defaults (bolt included)
│   ├── time.yml                            # mask timesyncd, install chrony.conf, start chrony
│   ├── hosts_file.yml                      # render /etc/hosts from inventory
│   ├── network.yml                         # STAGE /etc/network/interfaces; never auto-reload by default
│   ├── thunderbolt.yml                     # modules + boltctl enrollment + auto-discovered pci_path + .link pinning + transit ip_forward
│   ├── tuning.yml                          # 99-pve-host.conf sysctl drop-in
│   ├── nfs.yml                             # mount Asustor NFS at /mnt/nas-vms
│   ├── firewall.yml                        # cluster.fw via run_once + delegate_to (pmxcfs race avoidance)
│   └── users.yml                           # operator SSH pubkey for root@<host>
└── templates/etc/
    ├── apt/sources.list.d/pve-no-subscription.sources.j2
    ├── chrony/chrony.conf.j2
    ├── hosts.j2
    ├── modules-load.d/thunderbolt.conf.j2
    ├── network/interfaces.j2
    ├── pve/firewall/cluster.fw.j2
    ├── sysctl.d/99-pve-host.conf.j2
    ├── sysctl.d/99-tb-forward.conf.j2
    └── systemd/network/10-tb-link.link.j2
```

Outside the role itself, the repo-root `Justfile` gained four recipes: `pve-hosts-deps`, `pve-hosts`, `pve-hosts-check`, `pve-hosts-one host=<name>`.

---

## Assumptions beyond the spec

These are choices made where `CLAUDE.md` left a gap or the spec offered a sketch rather than a final shape. Each is small enough to revert without disturbing the rest of the role.

- **`split('/')` for CIDR prefix extraction** — CLAUDE.md left "use `ansible.utils.ipaddr` or compute manually" as the operator's call. Manual `pve_lan_subnet.split('/')[1]` keeps the role free of an extra Galaxy collection (`ansible.utils`). If a future template needs full subnet math, add the collection in one place and rip out the split.
- **`post-down ... || true`** added next to every `post-up ip route add` — pairs each route addition with a teardown that won't error if the route is already gone. Cheap insurance against the operator-driven reload sequence leaving stale routes.
- **`source /etc/network/interfaces.d/*`** at the top of `interfaces.j2` — preserves Proxmox's convention so future `pve-firewall` or `qemu-server` drop-ins still surface.
- **Chrony `allow {{ pve_lan_subnet }}`** — makes the host itself an NTP source for the VMs it carries. Quiet quality-of-life for cluster guests, not in the spec.
- **`failed_when: false`** on `systemd-timesyncd` mask/stop — minimal PVE installs sometimes lack the unit; ignoring the not-found case keeps re-runs clean.
- **Explicit `modprobe` of `thunderbolt` and `thunderbolt_net`** in addition to the `modules-load.d` drop-in — lets `thunderbolt.yml` enroll peers and discover netdevs in the same play, without waiting for a reboot.
- **`repo.yml` removes both `.list` (legacy single-line) AND `.sources` (deb822) enterprise repo files.** PVE 9.x's installer ships deb822-format sources at `/etc/apt/sources.list.d/pve-enterprise.sources` and `ceph.sources`. Without removing these, the `Apt update` handler fails with 401 Unauthorized on `enterprise.proxmox.com`. The role originally only handled the legacy `.list` paths; pve13t's fresh install on 2026-05-12 hit the deb822 variant. pve12t (older install) and pve13m (slightly older installer) didn't have these files so the gap wasn't visible until pve13t came up.
- **`firewall.yml` stages `cluster.fw` on regular FS then `cp`s into pmxcfs** rather than templating directly to `/etc/pve/firewall/cluster.fw`. pmxcfs (the FUSE filesystem mounted at `/etc/pve`) refuses Ansible's atomic-move pattern even with `unsafe_writes: true` — both the temp-rename and shutil.copy-with-metadata-preservation paths return EPERM. Plain `cp` and shell redirect work fine, confirmed via direct testing. The two-task pattern: render template to `/root/.cluster.fw.staged` (regular ext4-on-LVM), then a shell task that `cmp`s and `cp`s only if the staged file differs from what's already in pmxcfs. Idempotent via the cmp short-circuit. Discovered on the 2026-05-12 first-apply.
- **Peer-host authorization via udev rule, NOT `boltctl enroll`.** The role drops `/etc/udev/rules.d/99-thunderbolt-peer-auto-authorize.rules` matching `vendor_name=="Intel Corp."` and writing `1` to the `authorized` attribute on `add`. Broad trust is the correct posture for this lab — the TB fabric is dedicated to inter-node migration. Initial design tried `boltctl enroll --policy=auto` per peer, but boltd's enroll workflow is built for peripherals with factory-burned UUIDs (eGPU enclosures, docks) and refuses TB peer-host connections whose `unique_id` is synthesized by the kernel with a `-ffff-ffffffffffff` suffix. Discovered on the 2026-05-12 first-apply when enrollment errored on pve13m's `306e8780-c0a8-b4ef-ffff-ffffffffffff`. The Razer Core X eGPU (real peripheral, real UUID, `vendor="Razer"`) stays managed by boltd via its policy=auto enrollment from April; the udev rule doesn't touch it.
- **Python helper at `files/tb_topology.py`** instead of inline `command:` + shell loops — sysfs walks, symlink resolution, and PCI-BDF regex extraction are clearer in 30 lines of Python than the equivalent shell pipeline, and the role calls the same helper twice (pre- and post-enrollment).
- **`cluster.fw` ships with `enable: 0`, plus an accept rule for the /31 link subnet (`10.10.0.0/24`).** The role drops the firewall rules but does NOT turn the firewall on. Pre-cluster, pmxcfs is single-node so cluster.fw only exists on the delegate host (pve12t); enabling there alone produces asymmetric state where pve12t filters and pve13m/pve13t don't — which silently breaks TB transit because TB traffic between leaves goes through pve13m's filter-free kernel but hits pve12t's drop rules. After `pvecm create` + `pvecm add`, pmxcfs replicates cluster.fw cluster-wide and operator flips `enable:` to 1 (UI or file edit). The rule set accepts both `10.10.0.0/24` (the /31 link subnet) and `10.10.10.0/24` (loopback subnet) so once enabled, kernel-default source-IP selection on diagnostic pings doesn't drop traffic — corosync ring1 / migration / pvesr use loopback addresses naturally, but ad-hoc tools (ping, ssh) may source from the /31 endpoint. Discovered 2026-05-13 when pve13m → pve12t (`10.10.10.12`) failed because pve12t's PVEFW-HOST-IN had no accept rule for the inbound source `10.10.0.1`.
- **All TB loopback routes carry `src <tb_loopback>` and `via <peer-/31-addr>`** — two deviations from the original vault doc that are both required for transit to work in practice. The `src` hint makes the kernel source loopback-bound traffic from the loopback /32 instead of the outgoing /31 endpoint; without it, when leaf-A pings leaf-B's loopback, the packet sources from leaf-A's /31 endpoint, gets forwarded by the transit, leaf-B replies to that /31 endpoint — but leaf-B's directly-connected /31 only covers its own 2-address subnet, has no route to leaf-A's /31, so the reply falls through to the default gateway (vmbr0 / LAN) and never makes it back. The `via` (not just `dev`) form keeps the kernel ARPing for an address that definitely responds. Both discovered 2026-05-13.

- **Transit-node loopback routes use `via <peer-/31-addr> dev <link>`, not just `dev <link>`** — deviation from the original vault doc's `dev`-only form. With `dev`-only routes the kernel ARPs for the destination loopback /32 on the link, and that turned out to be asymmetric in practice on PVE 9.x: on one TB cable the far end replied to ARP for its loopback, on another cable it didn't, despite identical config. Routing via the peer's /31 address (which always responds to ARP — we verified with direct adjacency pings) sidesteps the loopback-ARP question entirely. Discovered on the 2026-05-13 first-light when pve13m → pve13t worked but pve13m → pve12t didn't.
- **`.link` `Path=` is an EXACT match `pci-<bdf>`**, not a glob `pci-<bdf>-*`. The kernel's `ID_PATH` for a `thunderbolt-net` netdev is exactly `pci-<bdf>` with no suffix. The `-*` form initially used by the template silently failed to match — 99-default.link won the priority race and interfaces stayed as kernel-assigned `thunderbolt0` / `thunderbolt1`, breaking the ifup of `tbnet-<peer>` stanzas in `/etc/network/interfaces`. Discovered on the 2026-05-12 post-baseline reboot when no `tbnet-X` interfaces came up across any host despite all the prerequisite tasks reporting success. The `Driver=thunderbolt-net` filter pairs with the exact Path to lock the match to a specific TB controller (so `pve13m`'s two TB ports get distinct `.link` files).
- **Two TB topology snapshots per run** — first pre-enrollment to harvest UUIDs, second post-enrollment to harvest the now-visible TB-net netdevs. The second is `when: bolt_enroll.changed` so steady-state re-runs skip it.
- **`hosts_file.yml` writes `/etc/machine-info` and immediately `flush_handlers`** to reload `thunderbolt_net` before `thunderbolt.yml` runs. PVE 9.x's installer doesn't create `/etc/machine-info`; without `PRETTY_HOSTNAME` populated there, the TB driver advertises an empty name to peers, who then read `device_name="(none)"` in sysfs. The role's `thunderbolt.yml` step (c) resolves `tb_links[].peer` (`"pve12t"`, `"pve13m"`, ...) by matching against that sysfs `device_name`, so an empty name breaks the resolution chain and forces a re-run. Writing the file + flushing handlers up front lets first-time apply converge in a single pass. Caught during dry-run on 2026-05-12 when all three peer entries surfaced as `(none)` to one or more neighbors.
(The `bolt`-related troubleshooting tasks — boltd restart, `boltctl list` query — were removed when peer-host authorization moved from boltctl to a udev rule. See the prior bullet on udev for the design that replaced them. `bolt` stays in the package list because the Razer Core X eGPU on pve12t still uses it.)
- **Symmetric "remove `99-tb-forward.conf` when `ip_forwarding_enabled: false`"** — wasn't in the spec, but keeps the role idempotent if a node is ever demoted from transit to leaf.
- **`exclusive: false`** on the `authorized_key` task — never clobber existing root keys. Spec said "install" not "manage exclusively"; conservative default.

No deviation from the spec required hand-waving past a rule; all of "What this role MUST NOT do" stayed out-of-bounds.

---

## What Brian needs to fill in before the first run

Mirrors `pve-hosts/CLAUDE.md` § "Things to leave for Brian" — restated here so this file is self-contained when the time comes.

1. **`pve-hosts/ansible/inventory.yml`** — copy from `inventory.yml.example`, replace every `# TODO`:
   - Real LAN subnet + gateway + per-node LAN IPs
   - `pve_lan_iface` per host (PVE 9 installs typically show `nic0`; older or non-PVE installs show `enpXsY` or `enoX` — verify with `ip link`)
   - NAS IP + hostname + export path
   - `admin_ssh_pubkey` — paste the workstation's ed25519 public key

   TB `pci_path` is **not** declared in inventory — the role discovers it from sysfs at run time. See `thunderbolt.yml` step (c).

2. **BIOS prereqs** (per node, one-time, not automatable):
   - IOMMU (VT-d) enabled
   - Secure Boot disabled
   - Boot order: NVMe-first after install completes

   Thunderbolt Security Level is **not** a manual prereq. ASUS NUC13 / NUC12 firmware doesn't expose it; the kernel reports `security=user` by default. The role's `thunderbolt.yml` step (b) handles persistent peer trust via `boltctl enroll --policy=auto`.

3. **Cluster join ceremony** — manual after the role applies. `pvecm create` on the first node, `pvecm add <first-node-ip>` on the others. See vault doc `[[VM Mobility — 3-Node Cluster on 2.5GbE]]`.

4. **NFS storage registration in Proxmox** — one-time `pvesh create /storage` (or via the UI) after the cluster is up. The role only mounts the share at the filesystem level.

5. **Manual `ifreload -a`** — fire from console after the role reports `/etc/network/interfaces` changed. The role deliberately does not reload networking; the "Surface networking change" handler prints a reminder.

6. **Re-run on first-time TB bring-up** — if a node applies the role before its TB peers have applied theirs, the peers' `device_name` may still be `(none)` and the resolution step's debug output will show `<unresolved>` for affected links. Re-run the role across all three nodes after the first pass; `boltctl` has by then published hostnames and the second snapshot resolves everything.

---

## Acceptance gates — outputs

Gates from `pve-hosts/CLAUDE.md` § "Acceptance gates". Each was re-run after the final implementation.

### 1. `ansible-playbook --syntax-check`

```console
$ cd pve-hosts/ansible && cp inventory.yml.example inventory.yml
$ ansible-playbook -i inventory.yml site.yml --syntax-check
playbook: site.yml
```

Clean — no errors.

### 2. Template render against the example inventory (all three hosts)

Used a tiny playbook with `connection: local` to invoke the role's `template` module against the example inventory's placeholders (192.0.2.0/24 LAN, RFC 5737 docs range), writing renders to `/tmp/pve-host-render/`. Verified per-host expectations from CLAUDE.md § "Acceptance gates":

- **pve12t** — `vmbr0` over `nic0` at the host's LAN IP; one TB stanza `tbnet-13m` at `10.10.0.0/31` MTU 65520; `lo:10` at `10.10.10.12/32`; two `post-up ip route` lines for `10.10.10.13/32` and `10.10.10.14/32` via `10.10.0.1` on `tbnet-13m`. ✓
- **pve13m** — `vmbr0` over `nic0`; two TB stanzas (`tbnet-12t` at `10.10.0.1/31`, `tbnet-13t` at `10.10.0.2/31`); `lo:10` at `10.10.10.13/32`; two `dev`-style `post-up ip route` lines (no next-hop on /31): `10.10.10.12/32 dev tbnet-12t` and `10.10.10.14/32 dev tbnet-13t`. `99-tb-forward.conf` rendered. ✓
- **pve13t** — `vmbr0` over `nic0`; one TB stanza `tbnet-13m` at `10.10.0.3/31`; `lo:10` at `10.10.10.14/32`; two `post-up ip route` lines for `10.10.10.12/32` and `10.10.10.13/32` via `10.10.0.2` on `tbnet-13m`. No `99-tb-forward.conf`. ✓

NIC name `nic0` reflects the PVE 9.x installer's per-host `.link` file at `/usr/local/lib/systemd/network/50-pmx-nic0.link`, which renames the management NIC by MAC. Inventory's `pve_lan_iface` is parameterized, so any name works if Brian's hardware shows something different (`ip link` to confirm).

### 3. `ansible-lint`

`Passed: 0 failure(s), 0 warning(s)` at the `production` profile (strictest) after:

- installing collections into the user-level path so ansible-lint can find them, since it ships with its own ansible-core that doesn't share search paths with brew's ansible:

  ```bash
  ansible-galaxy collection install -r pve-hosts/ansible/requirements.yml \
      --collections-path ~/.ansible/collections --force
  ```

- two inline `# noqa: no-handler` annotations on `thunderbolt.yml`'s post-enrollment wait + re-snapshot tasks (those must run synchronously between enrollment and resolution; handlers fire end-of-play and would be the wrong sequence point).

### 4. `yamllint`

Not run as a separate gate — `--syntax-check` covers the parser-level concerns and ansible-lint subsumes most YAML style rules. Worth running pre-merge if a future commit adds non-trivial multi-document YAML.

---

## Operational notes worth surfacing

- **Why `serial: 1`** — `site.yml` is set to one host at a time. A network template change that goes wrong takes one node off the air, not three. Override with `--forks` only when you've validated the change against a single node first.
- **Storage prereqs at install time** (assumed by the role, never managed by it):
  - `nuc12-fast` LVM-thin pool on pve12t for the LLM models cache — carve during the PVE installer
  - Per-node ISO library — created at install
  - No host-side LUKS partition on pve12t for the Root CA VM. That architecture changed 2026-05-11; encryption now lives inside the Root CA guest, so pve12t's storage layout for this role is just stock `local-lvm` + the LLM cache pool. See `vms/rootca/README.md` § "How the air-gap is enforced".
- **`pve_host_auto_reload_networking`** is an explicit escape hatch (default false). Flip it to true in inventory only for ephemeral lab contexts where you've decoupled the play host from the target's networking — never on a live cluster member you're SSH'd into.
- **The `firewall.yml` `run_once: true` + `delegate_to: ansible_play_hosts | first`** intentionally writes from the first host in the play. Because of `serial: 1`, that host is whichever node is being processed first in each batch — fine, because pmxcfs replicates and the file content is identical across nodes.
- **No automatic reboots** — if a future change adds something that benefits from one (kernel module addition surfacing only at boot, etc.), surface it via a `debug` task at the end of the play and stop. Brian reboots manually.
