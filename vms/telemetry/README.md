# vms/telemetry

Host for a self-contained telemetry stack: an OpenTelemetry Collector
as the single front door, feeding VictoriaMetrics (metrics),
Loki (logs) and Tempo (traces), plus a raw zstd archive of every
record. All four run under Docker Compose on Ubuntu 24.04. Grafana is
**not** here: the existing Grafana on [`vms/monitoring/`](../monitoring/)
queries the three stores as data sources.

Provisioned with OpenTofu, configured with Ansible. Follows the shape
of [`vms/nemoclaw/`](../nemoclaw/) for the Docker install — see
[`docs/deploying-vms.md`](../../docs/deploying-vms.md) for the
cross-cutting workflow.

> **What this VM is for.** Accept telemetry from anything on the LAN
> (OTLP on 4317/4318, or JSONL files rsynced into a landing zone),
> keep a raw copy indefinitely, and serve long-retention stores to
> Grafana. It is a separate failure domain from `vms/monitoring/`,
> which is sized for the lab's own Prometheus and too small to carry
> three more stores.
>
> **What this role does NOT do.** The stack's `compose.yaml`, Collector
> / Loki / Tempo configs and `.env` live in a separate project and are
> copied onto the VM by the operator (see "Deploy the stack" below).
> Pinning them here would fork their source of truth. The role stops at
> a host where `docker compose up -d` Just Works.

## Layout

```text
vms/telemetry/
├── README.md                  this file
├── terraform/                 VM provisioning (clone, size, NIC pin, cloud-init)
├── ansible/                   host prep (Docker, data root, patching)
└── cloud-init/                first-boot identity (hostname, user, SSH key)
```

## Role class: node-pinned on local NVMe

This role **overrides** the cluster-mobile storage default. The boot
disk lands on the target node's `local-lvm` (the LVM-thin pool on its
NVMe) and the cloud-init snippet on that node's `local` store, instead
of the cluster-shared `nas-vms`:

- The stores write continuously (WAL, compaction, the archive), and
  the NAS would become a runtime dependency of every write.
- The stack's data root shares the boot disk, so the whole VM is the
  backup unit (PBS), not a disk on the NAS.

Trade-off: no live migration. Moving the VM to another node means a
`qm move-disk` to shared storage first, or a PBS restore onto the new
node. Same override shape as [`vms/amp-game/`](../amp-game/); the
reasons are recorded in `terraform/variables.tf`.

## Prerequisites

1. **Workstation tooling.** `brew install opentofu just keepassxc ansible`.
   First-time setup in [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md).
2. **Packer base template on the target node.** The role defaults to
   `pve12t2`, whose Ubuntu base is VMID `9103` (per
   [ADR-0006](../../docs/decisions/0006-packer-templates-per-node.md)).
   If missing: `packer/ubuntu-24-04-base/build-pve.sh pve12t2`.
   `just check telemetry` fails early if it isn't there.
3. **`tofu@pve` API token** in KeePassXC at `Homelab/Tofu/proxmox-api-token`.
   See [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md).
4. **SSH to the node with the key in `ssh-agent`.** The `bpg/proxmox`
   provider uploads the cloud-init snippet over SSH, not the HTTP API.
   See [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) section
   **(d)** for the macOS Keychain auto-load pattern.
5. **Snippets content enabled on the node's `local` store.** Preflight
   checks this and prints a cure command if not.

## Deploy

From repo root:

```bash
just ansible-deps telemetry   # one-time per workstation
just hydrate telemetry        # render terraform.tfvars from KeePassXC
just check telemetry          # preflight: ssh, API, template 9103, snippets
just plan telemetry           # review: a fresh deploy is 3 creates, nothing else
just apply telemetry          # create the VM
just inventory telemetry      # write ansible/inventory.yml (waits on guest agent)
just ansible-check telemetry  # OPTIONAL: dry-run the role
just ansible telemetry        # Docker, data root, stack dir, patching
```

Then pin the MAC (next section) before creating the DHCP reservation.

End state: Docker Engine + Compose plugin running, `/srv/telemetry`
with the per-folder ownership the containers expect, an empty
`/opt/telemetry/collector` for the stack's files, and security-only
unattended upgrades. **No containers are running yet** — see
"Deploy the stack".

### Previewing with `--check`

`just ansible-check telemetry` works on a fresh host. The four
repo-bootstrap tasks (apt prereqs, keyrings dir, Docker key, Docker
repo) carry `check_mode: false` and run for real even under `--check`,
because without the repo on disk the `docker-ce` install can't be
dry-run. Same convention as nemoclaw / openclaw / pbs-hosts. Expect two
warnings about UID 10001 having no passwd entry: check mode can't
resolve it, and a real run sets the numeric owner.

## MAC pin

The router's DHCP reservation is keyed on the NIC's MAC, so the MAC
must not change when the NIC is recreated. The value is **not** in
`main.tf`: this repo is public and a real MAC is LAN topology. It
lives in `terraform/nic.auto.tfvars`, which is gitignored
(`vms/*/terraform/*.auto.tfvars`), loaded automatically by OpenTofu,
and never rewritten by `just hydrate --force`.

After the first apply (when `nic_mac_address` is unset and bpg
generated a MAC):

```bash
just output telemetry          # prints mac = "BC:24:11:..."
cat > vms/telemetry/terraform/nic.auto.tfvars <<'EOF'
nic_mac_address = "BC:24:11:XX:XX:XX"
EOF
chmod 600 vms/telemetry/terraform/nic.auto.tfvars
just plan telemetry            # must report "No changes"
```

Then reserve that MAC's address on the router.

On a fresh clone of the repo the file is absent. That is harmless for
an existing VM — the provider keeps the MAC already in state and the
plan stays "No changes" — but recreate the file before any change
that would rebuild the NIC.

## Deploy the stack (operator)

The role leaves three things for the operator, all from the stack's
own project and runbook:

1. **Copy the tracked stack files** (compose file and the Collector,
   Loki and Tempo configs, plus `env.example`) into
   `/opt/telemetry/collector` with `scp`. The directory is owned by the
   admin user, so no sudo is needed. Never copy a workstation's `.env`.
2. **Create `.env`** from `env.example` on the VM, with
   `TELEMETRY_ROOT=/srv/telemetry` and `TELEMETRY_BIND_ADDR` set to the
   VM's **reserved LAN address** (every published port binds there,
   and nowhere else).
3. **Start it:** `docker compose up -d` in `/opt/telemetry/collector`.
   Log in again after `just ansible telemetry` first, so the admin
   user's new `docker` group membership applies.

### Data root ownership

The role creates these with the ownership the stack's images need.
Only the top-level folders are managed — no recursion, no deletes —
so re-running the role never touches data.

| Path | Owner | Why |
| --- | --- | --- |
| `/srv/telemetry/archive` | 10001:10001 | Collector writes the raw zstd archive |
| `/srv/telemetry/collector-state` | 10001:10001 | Collector file-tail checkpoints |
| `/srv/telemetry/loki` | 10001:10001 | Loki chunks + index |
| `/srv/telemetry/tempo` | 10001:10001 | Tempo blocks + WAL |
| `/srv/telemetry/victoria` | root:root | VictoriaMetrics runs as root |
| `/srv/telemetry/landing` | admin user, 0755 | rsync target over SSH; the Collector (10001) reads it |

UID 10001 has no passwd entry on the VM, so `ls -l` shows it as a
number (or `stat` as `UNKNOWN`). That is expected.

## Operations

### Stable IP via DHCP reservation

Reserve the pinned MAC's address on the router. The stack binds its
ports to that address, so a lease change would leave the containers
unable to bind after the next reboot — Docker does not retry a failed
bind. `docker.service` already orders itself after
`network-online.target`, which is what makes a reserved address
available in time.

### SSH

```text
Host telemetry <reserved-LAN-IP>
  HostName <reserved-LAN-IP>
  User telemetry-admin
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

Keep the IP in the `Host` line as well as the alias: jobs that ship
files to the landing zone connect by address. `IdentitiesOnly yes`
matters because the base image allows three auth attempts
(`MaxAuthTries 3`).

### Container logs

The stack's compose file sets no logging limits, so the role sets a
daemon-wide default in `/etc/docker/daemon.json`: `json-file`, 3 files
of 50 MiB per container (`telemetry_docker_log_max_*` in the role
defaults). It only applies to containers created after it is set; after
changing it on a live VM, run `docker compose up -d --force-recreate`.

### Patching and Docker upgrades

Unattended upgrades are on for the Ubuntu security pockets only.
Docker's repo is **not** in the allowed origins, so `docker-ce` and
`containerd.io` never upgrade underneath a running stack. Upgrade them
deliberately (`sudo apt upgrade`), then check `docker compose ps`.

### Growing the disk

Thin-provisioned, so only written blocks consume the node's pool.
To grow: raise `disk_size_gb` in `terraform/main.tf`, `just plan` /
`just apply telemetry`, then on the VM
`sudo growpart /dev/sda 2 && sudo resize2fs /dev/sda2`. Proxmox
cannot shrink a disk.

### Re-run the role

```bash
just ansible telemetry         # idempotent: a clean re-run reports changed=0
```

## Backup

- **PBS** backs up the whole VM, which includes the data root.
- **The archive** under `/srv/telemetry/archive` is the stack's
  irreplaceable record (the stores can be rebuilt from it). Sync it
  off the VM as well, for example to the NAS. Its files are `0600` for
  UID 10001, so the sync job runs as root.

## Destroy and rebuild

> **WARNING.** The data root lives on the boot disk.
> `just destroy telemetry` deletes the archive, the landing zone and
> every store. Restore from PBS instead of rebuilding, or confirm the
> archive has an off-VM copy first.

```bash
just destroy telemetry     # only with an off-VM copy of the archive
just apply telemetry
just ansible telemetry
# then restore the archive, re-copy the stack files and recreate .env
```

## Sizing

| Resource | Value | Why |
| --- | --- | --- |
| vCPU | 4 | Collector + three stores, plus Loki compaction and VictoriaMetrics merges running in parallel |
| RAM | 8 GiB | The Collector's `memory_limiter` alone is 1500 MiB; the stores cache heavily; the rest is page cache for queries |
| Balloon | 0 | Fixed allocation so the stores' caches aren't squeezed by host memory pressure |
| Disk | 250 GiB thin | Archive kept indefinitely, landing zone never pruned, 5y metrics, 2y logs, 90d traces — on the same filesystem as the OS, so headroom protects the OS from a full disk |
| Storage | `local-lvm` | Node NVMe; see "Role class" above |
| CPU type | x86-64-v3 | Module default; the stack's images publish `linux/amd64` |

Override in `terraform/main.tf`'s `module "telemetry"` call.

## Ports

| Port | Protocol | Bound by | Purpose |
| --- | --- | --- | --- |
| 22 | tcp | sshd (ufw allow) | SSH |
| 4317 | tcp | Docker, LAN IP only | OTLP gRPC into the Collector |
| 4318 | tcp | Docker, LAN IP only | OTLP HTTP into the Collector |
| 13133 | tcp | Docker, LAN IP only | Collector health check |
| 8428 | tcp | Docker, LAN IP only | VictoriaMetrics (Grafana data source, Prometheus API) |
| 3100 | tcp | Docker, LAN IP only | Loki (Grafana data source) |
| 3200 | tcp | Docker, LAN IP only | Tempo (Grafana data source) |
| 9100 | tcp | node_exporter, if wired into monitoring | Host metrics for the Lab Rightsizing dashboard |

## Security notes

- **Docker bypasses ufw.** Published container ports go through
  Docker's own iptables chains, so `ufw` rules neither open nor close
  them; the role adds none. Exposure is controlled by binding every
  published port to the VM's LAN address (`TELEMETRY_BIND_ADDR`), and
  should be verified from a host outside the LAN, not inferred from
  `ufw status`. Leave Docker's iptables handling on: disabling it
  breaks publishing on the LAN address.
- **No authentication on the stack.** The OTLP intake and the three
  stores' APIs are unauthenticated, including VictoriaMetrics' admin
  API. LAN-only exposure is the control; never port-forward them.
- **`docker` group is root-equivalent.** The admin user is added to
  it for convenience; it already has NOPASSWD sudo from cloud-init, so
  this doesn't widen access. Set `telemetry_admin_docker_group: false`
  to opt out.
- **The archive and landing zone can hold sensitive content.** The
  Collector redacts common secret shapes, but treat backups and NAS
  copies of `/srv/telemetry` as sensitive.
- **The MAC stays out of the repo** (see "MAC pin").

## Wire into monitoring (optional)

node_exporter and the Lab Rightsizing dashboard are not auto-wired.
Follow [`vms/_template/README.md`](../_template/README.md) "Wire into
monitoring (post-deploy)": add the VM to
`monitoring_node_exporter_targets` and `monitoring_guest_inventory_groups`,
list `vms/telemetry/ansible/inventory.yml` in
`vms/monitoring/ansible/.extra-inventories`, run
`install-node-exporter-guests.yml` against it, then
`just ansible monitoring`.

## Files

- `terraform/main.tf` — provider + module call (sizing, NIC pin, cloud-init).
- `terraform/variables.tf` — endpoint, token, node, admin user, SSH key,
  `nic_mac_address`, and the two storage knobs (`disk_storage`,
  `snippets_storage`) with the node-local override rationale.
- `terraform/terraform.tfvars.tpl` — committed, kp:// placeholders.
- `terraform/terraform.tfvars.example` — committed, manual-fill alternative.
- `terraform/nic.auto.tfvars` — **gitignored**, the pinned MAC.
- `cloud-init/user-data.yaml.tftpl` — identity only.
- `ansible/site.yml` + `roles/telemetry/` — Docker from Docker's apt
  repo, daemon log rotation, data root + stack directory, patching.

## Related

- [`docs/deploying-vms.md`](../../docs/deploying-vms.md) — role-class chooser, repeatable deploy flow.
- [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) — workstation setup, hydrate flow, state.
- [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md) — API token + role.
- `modules/proxmox-vm/` — the shared module this role calls.
- `packer/ubuntu-24-04-base/` — produces the Ubuntu base template.
- [`vms/monitoring/`](../monitoring/) — Grafana that queries this VM's stores.
- [`vms/nemoclaw/`](../nemoclaw/) — the other role that installs Docker from Docker's apt repo.
- [`vms/amp-game/`](../amp-game/) — the other node-local storage override.
