# vms/monitoring

Prometheus + Grafana + `prometheus-pve-exporter` + `prometheus-pbs-exporter` +
`prometheus-nut-exporter` (HON95, runs as a Docker container — `docker.io` is
installed by this role for that single consumer; future containerized
exporters can reuse the daemon) on Ubuntu 24.04, scraping
`prometheus-node-exporter` on every cluster host. Class A (cluster-mobile)
per [`docs/deploying-vms.md`](../../docs/deploying-vms.md).

The primary use case is **historical per-VM RAM utilization trends** —
the data needed to decide whether RAM allocations are sized right.
Secondary: cluster host temps / fans / disk free, and PBS backup health.
Design context lives in the vault doc `Homelab Monitoring — Prometheus,
Grafana, and the MVP Dashboard.md` (Option A); this role implements §5
steps 1–7 (alerts in §5 step 8 are deferred to a follow-up).

## Layout

```text
vms/monitoring/
├── README.md                          this file
├── terraform/                         VM provisioning
├── ansible/
│   ├── site.yml                       role play (against monitoring_servers)
│   ├── install-node-exporter.yml      sub-playbook for the 3 PVE nodes + pbs01
│   └── roles/monitoring/              install + config
└── cloud-init/                        first-boot identity
```

## Prerequisites

### Credentials checklist (KeePassXC)

Three KeePassXC entries this role reads or has the operator paste.
Confirm they exist before starting; details for creating each are in
the steps below, and the repo-wide index lives at
[`docs/credentials-index.md`](../../docs/credentials-index.md).

| KeePassXC path | Field | What | Created by |
| --- | --- | --- | --- |
| `Homelab/Tofu/proxmox-api-token` | Password | `tofu@pve!apply=<secret>` (provisioning) | already minted (shared with all roles) |
| `Homelab/Prometheus/proxmox-api-token` | Password | `prometheus@pve!exporter=<secret>` (PVE metrics) | step 4 below |
| `Homelab/Prometheus/pbs-api-token` | Password | `prometheus@pbs!exporter:<secret>` (PBS metrics — note `:` separator) | step 5 below |

Workstation SSH pubkey at `Homelab/Tofu/workstation-ssh-pubkey` (Notes
field) is also consumed via the shared tofu hydrate flow — should
already be in place from any prior VM role you've deployed.

### Steps

1. **Workstation tooling.** `brew install opentofu just keepassxc ansible`.
   First-time setup in [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md).
2. **Packer base template.** VM 9100/9101/9102/9103 must exist on the target
   node (per ADR-0006). If not: `packer/ubuntu-24-04-base/build-pve.sh <node>`.
3. **`tofu@pve` API token.** See [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md).
   Stash in KeePassXC at `Homelab/Tofu/proxmox-api-token`.
4. **`prometheus@pve!exporter` API token (read-only).** Mint it per
   [`docs/proxmox-prometheus-permissions.md`](../../docs/proxmox-prometheus-permissions.md)
   and stash the full `prometheus@pve!exporter=<secret>` string in
   KeePassXC at `Homelab/Prometheus/proxmox-api-token`. This is the
   token the running exporter uses to read cluster metrics — separate
   from the `tofu@pve!apply` token that creates the VM.
5. **PBS API token (read-only).** Mint per the **PBS API permissions**
   section of [`docs/proxmox-prometheus-permissions.md`](../../docs/proxmox-prometheus-permissions.md)
   — five `proxmox-backup-manager` commands on pbs01. The walk-through
   includes both the user-create and the **token's own** ACL grant
   (PBS 4.x privsep is intersection-based; forgetting the token-ACL
   step is the most common reason for `pbs_up 0`). Stash the full
   `prometheus@pbs!exporter:<secret>` string in KeePassXC at
   `Homelab/Prometheus/pbs-api-token`.
6. **SSH access to the target node + key loaded into `ssh-agent`.**
   `ssh-copy-id root@pve13m`, then `ssh-add ~/.ssh/id_ed25519`. The
   `bpg/proxmox` provider uploads cloud-init snippets over SSH and
   shells out non-interactively. Preflight verifies it.
7. **PVE + PBS host baselines already applied.** This role assumes
   `pve-hosts` and `pbs-hosts` Ansible roles have run (the
   `install-node-exporter.yml` sub-playbook below targets those hosts'
   inventories).

## Deploy

### Phase 1 — provision the VM (workstation)

```bash
just ansible-deps monitoring   # one-time per workstation
just hydrate monitoring        # render terraform.tfvars from KeePassXC
just check monitoring          # preflight: ssh, Proxmox API, template, snippets
just plan monitoring           # review the plan
just apply monitoring          # create the VM
just inventory monitoring      # write ansible/inventory.yml from tofu output
```

### Phase 2 — configure the stack (workstation)

```bash
just ansible monitoring        # installs Prometheus, Grafana, exporters
```

After this finishes, the monitoring stack is up but the two API-token
exporters are **stopped** — the role lays down placeholder configs
intentionally so first deploy doesn't leak a real token through the
repo working directory. Continue to the ceremony.

### Phase 3 — install node_exporter on PVE + PBS hosts (workstation)

```bash
ansible-playbook \
  -i pve-hosts/ansible/inventory.yml \
  -i pbs-hosts/ansible/inventory.yml \
  vms/monitoring/ansible/install-node-exporter.yml
```

Idempotent — re-running on subsequent host additions is safe. The
playbook installs the apt package, enables the service, and opens
port 9100 on each host's firewall (pve-firewall for cluster nodes;
ufw on pbs01).

It also installs `lm-sensors` and pins the hwmon kernel modules
(`sensors_kernel_modules`, default `[coretemp]`) via
`/etc/modules-load.d/lm-sensors.conf`, so node_exporter's hwmon
collector exports `node_hwmon_temp_celsius` / `node_hwmon_fan_rpm` —
this is what feeds the temperature + fan rows of dashboard 1860 and the
lab-local `homelab-physical-hosts-temps` dashboard.

#### One-time per-host sensor discovery

`coretemp` (CPU package/core temps) is the safe baseline and is loaded
on every host with no extra work. **Fan RPM** needs a super-I/O
controller module (`nct6775` / `it87` family) that does not auto-load
and is not guaranteed to exist — many Intel NUCs expose `coretemp`
only. To find out what a host can report, run once per host:

```bash
ssh <host> 'apt-get install -y lm-sensors && sensors-detect --auto'
ssh <host> 'sensors'   # confirm readings; note any fan / super-I/O chip
```

If `sensors` shows a fan reading, note the driver module it loaded and
add it to `sensors_kernel_modules` in inventory, then re-run this play.
If no fan chip is found, that's a hardware limit — the host's temp
panels still populate; its fan panel stays empty.

On this lab's hardware the result is:

- **The four ASUS NUCs** (`pve12t` / `pve13m` / `pve13t` / `pve12t2`)
  expose CPU fan RPM through the ASUS WMI path, NOT a super-I/O chip —
  `sensors-detect` finds no super-I/O controller. The `asus_nb_wmi`
  module instantiates `asus_wmi`, which surfaces `cpu_fan` (hwmon name
  `asus`, `node_hwmon_fan_rpm{chip="platform_asus_nb_wmi"}`). It's set
  as a `pve_hosts` group var, so all four nodes get
  `sensors_kernel_modules: [coretemp, asus_nb_wmi]`.
- **`pbs01`** (GMKtec G3 Pro) has an ITE IT8613E super-I/O chip but no
  mainline Linux driver exists for it, and it's not ASUS — so no fan
  RPM is available; it reports CPU temps (`coretemp`) only.

### Phase 4 — install node_exporter inside guest VMs (workstation)

```bash
ansible-playbook \
  -i vms/openbao/ansible/inventory.yml \
  -i vms/llm/ansible/inventory.yml \
  -i vms/amp-game/ansible/inventory.yml \
  -i vms/openclaw/ansible/inventory.yml \
  -i vms/nemoclaw/ansible/inventory.yml \
  -i vms/hermes/ansible/inventory.yml \
  vms/monitoring/ansible/install-node-exporter-guests.yml
```

Same idempotency; same pattern as Phase 3 but targets the guest VMs
(uniform ufw path, no per-group conditionals). Installs the apt
package, enables the service, opens 9100/tcp on each guest's ufw.
Pairs with the **Lab Rightsizing** dashboard — without this step
that dashboard's panels are empty.

The `rootca` VM is intentionally absent — air-gapped + USB-HSM-pinned,
its security posture trumps observability. Add it back if/when that
calculus changes.

## Operator ceremony — paste exporter tokens (one-time)

The two API tokens live in KeePassXC only; the repo never sees them.
This is the same trust-anchor pattern openbao's first-init ceremony
uses (the repo provisions everything except the secret material).

On the monitoring VM:

```bash
ssh monitoring-admin@<vm-ip>

# 1. PVE exporter — paste the Token Value from KeePassXC
#    Homelab/Prometheus/proxmox-api-token into the token_value field.
sudoedit /etc/prometheus/pve.yml

# 2. PBS exporter — paste the Token Value into PBS_API_TOKEN.
sudoedit /etc/prometheus/pbs-exporter.env

# 3. Start both services.
sudo systemctl start prometheus-pve-exporter prometheus-pbs-exporter

# 4. Sanity-check.
curl -sf http://127.0.0.1:9221/pve?target=pve13m | head -5
curl -sf http://127.0.0.1:10019/metrics | grep '^pbs_' | head -5
```

Both `curl` outputs should print Prometheus exposition-format text with
real numeric values. If you see `401 Unauthorized` or
`{"errors":{}, "message": ...}`, recheck the token name (`exporter`)
and value, then `systemctl restart` the affected exporter.

Re-running `just ansible monitoring` later will NOT clobber these
hand-edited files — the templates that lay them down use `force: false`.

## Dashboards (provisioned by Ansible)

The role's `dashboards.yml` task does two things on every
`just ansible monitoring`: it fetches the pinned community dashboards
and substitutes `${DS_PROMETHEUS}` for the provisioned datasource name,
and it renders the lab-local Jinja2-templated dashboards (datasource UID
swapped inline). Both land in `/var/lib/grafana/dashboards/`, where
Grafana's file provider re-scans the dir every 30s and loads them — no
UI step needed.

| Source (pinned) | What it shows |
| --- | --- |
| [grafana.com 1860](https://grafana.com/grafana/dashboards/1860) (Node Exporter Full) | CPU/RAM/disk/network/fans/temps for every `node_exporter` target. The "Hardware Temperature Monitor" / "Hardware Fan Speed" rows populate once Phase 3's `lm-sensors` + pinned hwmon modules are in place; fan rows depend on the host exposing a fan chip (see Phase 3 discovery) |
| [grafana.com 10347](https://grafana.com/grafana/dashboards/10347) (Proxmox via Prometheus) | **Per-VM CPU/RAM/disk-IO** — the dashboard that answers the RAM-trend question |
| [natrontech/pbs-exporter `grafana-dashboard/pbs-exporter.json`](https://github.com/natrontech/pbs-exporter/tree/main/grafana-dashboard) | Datastore usage, last-backup ages, verify status — pinned to the same tag as the exporter binary |
| [grafana.com 12239](https://grafana.com/grafana/dashboards/12239) (NVIDIA DCGM Exporter) | GPU util/memory/power/temp/clocks from the llm VM's 3090 — only populated when `monitoring_dcgm_target` is set AND the DCGM container is running on the llm VM (see [`vms/llm/README.md`](../llm/README.md) "Expose GPU metrics to Prometheus"). Authored for K8s deployments; K8s-label-filtered panels (namespace/pod) will be empty on this single-host setup |
| [grafana.com 14371](https://grafana.com/grafana/dashboards/14371) (Prometheus NUT Exporter, HON95) | UPS metrics — battery charge/runtime, input voltage, load %, status (OL/OB), temp. Populated when `monitoring_nut_target` is set AND the NUT server on the Asustor NAS accepts remote reads (ADM → Services → UPS → enable network UPS). Multi-target via `?target=` (relabel pattern); the `ups` dashboard dropdown auto-populates from whatever NUT reports |
| `homelab-ups-power` (lab-local — `templates/dashboards/ups-power.json.j2`) | UPS power & energy derived from `nut_load × nut_real_power_nominal_watts` (CyberPower BR-series doesn't expose `ups.realpower` directly — HON95 emits the metric but the underlying driver doesn't surface the variable on BR1000MS / BR1500MS2). Stat panels for current watts / UPS load / rated capacity / 24h kWh / 7d avg kWh, plus a time-series with the nominal-capacity ceiling overlaid. Pairs with the `nut_real_power_derived_watts` recording rule (see [Recording rules](#recording-rules)). |
| `homelab-rightsizing` (lab-local — `templates/dashboards/rightsizing.json.j2`) | Per-VM CPU/memory pressure for right-sizing decisions. Four signals plotted as instant stats + trend lines: CPU PSI rate (`node_pressure_cpu_waiting_seconds_total`), Memory PSI rate (`node_pressure_memory_waiting_seconds_total`), MemAvailable% (`node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes`), and Load1 / vCPUs. Hypervisor-view metrics from `pve-exporter` can't surface guest-internal memory pressure (page cache hides it) or runqueue depth — PSI inside the guest is the honest signal. Thresholds use a deutan-safe orange→purple ramp instead of red/yellow/green. VM dropdown defaults to All. Empty when guest node_exporter isn't running (Phase 4 not yet applied). |
| `homelab-physical-hosts-temps` (lab-local — `templates/dashboards/physical-hosts-temps.json.j2`) | Per-host CPU package / per-core / NVMe / board temps + fan RPM, from the `node_exporter` hwmon collector (`node_hwmon_temp_celsius`, `node_hwmon_fan_rpm`). All-hosts overview on top — CPU temp, fan RPM, and a **hottest-NVMe-per-host** stat strip + NVMe trend so a hot drive on any host is visible without drilling in — then a collapsed per-host drill-down row (driven by the `Host` dropdown) with per-core temps joined to `node_hwmon_sensor_label` for friendly names, per-drive NVMe, and board/ACPI temps. A focused alternative to digging through 1860's "Hardware Temperature" panel, whose 100 C lines are mostly crit-threshold series rather than live temps. CPU temp thresholds use the deutan-safe neutral→orange→purple ramp at 90 C / 100 C TjMax; **NVMe panels use NVMe-appropriate 70 C (watch) / 80 C (throttle) thresholds** — a drive sitting orange/purple, or whose baseline creeps up over weeks, is the cue to re-check its heatsink / thermal-pad contact; fans use a blue ramp with no threshold (high RPM is the cooling working, not a fault). Same prerequisites as 1860's hardware rows (Phase 3 `lm-sensors` + pinned hwmon modules); hosts with no exposed fan chip (e.g. pbs01) render empty fan panels. |

To pick up a newer revision, edit `monitoring_dashboards[].url` in
[ansible/roles/monitoring/defaults/main.yml](ansible/roles/monitoring/defaults/main.yml)
(look up the latest grafana.com revision with
`curl -sf https://grafana.com/api/dashboards/<id> | jq .revision`)
and re-run `just ansible monitoring`. The PBS dashboard URL templates
on `monitoring_pbs_exporter_version`, so bumping the exporter version
also tracks its dashboard.

Operators can ALSO import additional dashboards via the UI — Grafana
writes those to the same dir (`allowUiUpdates: true`) and they
coexist with the role-managed ones.

## Recording rules

Prometheus recording rules live in `/etc/prometheus/rules/homelab.yml`
(rendered from
[`templates/prometheus-rules.yml.j2`](ansible/roles/monitoring/templates/prometheus-rules.yml.j2)).
Today the file declares one rule:

| Recorded metric | Expression | Why |
| --- | --- | --- |
| `nut_real_power_derived_watts` | `nut_load * nut_real_power_nominal_watts` | CyberPower BR-series UPSes (BR1000MS, BR1500MS2, …) don't expose `ups.realpower` over USB — the `usbhid-ups` driver only surfaces `ups.load` (fraction) and `ups.realpower.nominal` (rated W). HON95 emits both as Prometheus metrics; multiplying gives watts. Materializing it as a recording rule means dashboards / future alerts can reference a single primitive and queries don't recompute the multiply at panel time. |

The expression references `nut_real_power_nominal_watts`, not a hardcoded
wattage — swapping the UPS (e.g. BR1000MS → BR1500MS2, 600W → 900W) is
picked up automatically on the first scrape after the new unit comes
online. No role re-deploy needed.

To add a new rule, edit `prometheus-rules.yml.j2` and re-run
`just ansible monitoring` — `promtool check rules` runs as a validate
step on the template task, so a syntactically bad rule won't land on
disk.

## Verify (end-to-end)

The user-facing goal of this role is per-VM RAM trends. Verify in
this order:

1. **`http://<vm-ip>:9090/classic/targets`** — every target reports `UP`.
   The Debian/Ubuntu prometheus 2.x package serves the legacy UI under
   `/classic/`, not at the root (the bare `/targets` route 404s). Expect
   15 endpoints across 4 always-on jobs, plus 1 endpoint each for the
   two optional jobs (`dcgm-exporter`, `nut-exporter`) when their
   corresponding `monitoring_<x>_target` variables are non-empty AND the
   upstream services (DCGM container on llm VM, network UPS in ADM)
   are actually up. Guest VMs in the `node_exporter` count report DOWN
   until Phase 4 (install-node-exporter-guests.yml) is applied for them:

   | Job | Targets |
   | --- | --- |
   | `node_exporter` | 12 — monitoring, pve12t, pve13m, pve13t, pve12t2, pbs01, openbao, llm, amp-game, openclaw, nemoclaw, hermes (6 host targets always; 6 guest targets after Phase 4 runs against them) |
   | `pve` | 4 — pve12t, pve13m, pve13t, pve12t2 (scraped via the pve-exporter multi-target relabel) |
   | `pbs-exporter` | 1 — pbs01 (job name matches natrontech's dashboard convention; see prometheus.yml.j2 header) |
   | `dcgm-exporter` | 1 — llm (only if `monitoring_dcgm_target` is non-empty AND the DCGM container is up on the llm VM; will report DOWN otherwise) |
   | `nut-exporter` | 1 — nas (only if `monitoring_nut_target` is non-empty AND the Asustor NAS has network UPS enabled in ADM; multi-target via `?target=` relabel — the exporter itself runs locally on the monitoring VM at 127.0.0.1:9995, scraping the NAS's `upsd` on port 3493) |
   | `prometheus` | 1 — self-scrape on localhost:9090 |

2. **`http://<vm-ip>:3000`** — Grafana loads (initial login `admin` /
   the bootstrap password set in `Homelab/Prometheus/grafana-admin`).
   Connections → Data sources shows **Prometheus** healthy with
   `uid: prometheus` (pinned in the provisioner so community dashboards
   that hardcode that UID work without rewriting).
3. **Day 0 — primary-goal smoke test.** In Grafana Explore, query
   `pve_memory_usage_bytes{id=~"qemu/.*"}` — confirm one series per
   running cluster VM with a numeric value below the matching
   `pve_memory_size_bytes` series. The ratio over a few minutes is
   that VM's working set as a fraction of its assigned RAM.
4. **Day 1+ — trend verification.** Open the imported Proxmox dashboard
   after 24h. Per-VM memory panels should show a continuous time series.
   `pve_memory_usage_bytes / pve_memory_size_bytes` consistently below
   ~50% over a week is the signal that a VM is over-provisioned.

5. **(If nut-exporter is up)** Grafana Explore: query
   `nut_load{ups="asustor"}` — single series with the UPS load %. Watch
   during sustained GPU inference (`ollama run` on a large model) to
   correlate against `nut_input_voltage_volts` and `DCGM_FI_DEV_POWER_USAGE`
   from the llm-VM scrape. This is the cross-stack data Brian set the
   role up for in the first place — see the design-doc rationale in
   `Homelab Inventory.md` § UPS for what the BR1000MS's 600W ceiling
   means against the lab's worst-case draw.
6. **(If nut-exporter is up)** Confirm the derived-watts recording rule
   is materializing: in Grafana Explore, query
   `nut_real_power_derived_watts{ups="asustor"}` — single series, in
   watts, equal to `nut_load * nut_real_power_nominal_watts`. Then open
   the **UPS Power & Energy (homelab)** dashboard. After ~24h of
   uptime the "Energy consumed (last 24h)" stat reflects the lab's
   actual daily kWh; before that it's just an extrapolation of the
   shorter window.
7. **(If Phase 4 guest node_exporters are up)** In Grafana Explore,
   query `rate(node_pressure_cpu_waiting_seconds_total[5m])` — one series
   per guest VM (plus the 6 host targets). Values near 0 = sized right;
   sustained values above ~0.05 = CPU starvation worth bumping. Then
   open the **Lab Rightsizing** dashboard — stat panels at the top
   show current values across all VMs, time-series below show trend.
   VMs without node_exporter just don't appear (panels filter by
   `instance` label).

## Operations

### Re-run Ansible after a config tweak

```bash
just ansible-check monitoring   # dry-run with --diff
just ansible monitoring         # apply
```

Adjustments that fit the existing variable surface (scrape interval,
retention, target list additions, exporter version bumps) edit
[`vms/monitoring/ansible/roles/monitoring/defaults/main.yml`](ansible/roles/monitoring/defaults/main.yml)
and re-run. Handlers restart the affected services.

### Stable IP via DHCP reservation (on the LAN router)

`just output monitoring` reports the MAC of the VM's NIC. Pin a DHCP
reservation so the Grafana URL doesn't rotate.

### Bump Prometheus retention

Edit `monitoring_prometheus_retention_time` in
`ansible/roles/monitoring/defaults/main.yml`, then re-run
`just ansible monitoring`. Disk-cost-wise: 90d at this scrape rate is
under 30 GB on the 64 GB boot disk.

### Rotate the exporter tokens

Mint a new token via `pveum` (PVE) or the PBS UI; stash in KeePassXC;
update the corresponding file on the VM (`/etc/prometheus/pve.yml` or
`/etc/prometheus/pbs-exporter.env`); `sudo systemctl restart
prometheus-pve-exporter` (or `prometheus-pbs-exporter`). The repo
working tree never sees the new value.

## Destroy and rebuild

```bash
just destroy monitoring   # wipes the Prometheus TSDB + Grafana SQLite
just apply monitoring
just ansible monitoring
# then re-run the operator ceremony to paste tokens
```

TSDB history is local-only — destroying means losing whatever historical
trend data was captured. For long-running trend data, either back up
`/var/lib/prometheus/` periodically, or accept that the monitoring VM
is rebuildable but its history is not.

## Sizing

| Resource | Value | Why |
| --- | --- | --- |
| vCPU | 2 | Prometheus scrapes are sub-millisecond HTTP fetches; Grafana renders are bursty but light. |
| RAM | 4 GiB | Prom + Grafana steady-state under 1 GiB; 4 GiB leaves headroom for a 90d retention bump. |
| Disk | 64 GiB | 15-day TSDB at ~5 hosts × 15s scrape sits under 10 GB; 64 GiB carries a 90d bump comfortably. |
| Balloon | 1 GiB | Monitoring tolerates ballooning — unlike openbao which mlocks. Let the host reclaim under pressure. |
| Machine | q35 | Matches the rest of the homelab. |
| CPU type | x86-64-v3 | Common baseline across the cluster's NUCs — supports live migration. |

Override in [`vms/monitoring/terraform/main.tf`](terraform/main.tf)'s
`module "monitoring"` call.

## Ports

| Port | Protocol | Source | Purpose |
| --- | --- | --- | --- |
| 22 | tcp | LAN | SSH (opened by Packer base) |
| 3000 | tcp | LAN | Grafana UI |
| 9090 | tcp | LAN | Prometheus UI / API |
| 9100 | tcp | LAN | node_exporter (also opened on each PVE/PBS host) |
| 9221 | tcp | LAN | prometheus-pve-exporter |
| 10019 | tcp | LAN | prometheus-pbs-exporter |

UFW inside the VM; perimeter is the LAN router. Keep LAN-only unless
you front Grafana with mTLS at a reverse proxy.

## Files

- `terraform/main.tf` — provider + module call (sizing, cloud-init).
- `terraform/variables.tf` — six inputs (endpoint, token, node, user, key, storage).
- `terraform/terraform.tfvars.tpl` — committed, kp:// placeholders.
- `terraform/terraform.tfvars.example` — committed, manual-fill alternative.
- `cloud-init/user-data.yaml.tftpl` — identity only.
- `ansible/site.yml` — top-level play.
- `ansible/install-node-exporter.yml` — sub-playbook for the cluster hosts + pbs01.
- `ansible/roles/monitoring/` — install + config (tasks split into `repos`, `packages`, `pve_exporter`, `pbs_exporter`, `config`, `firewall`).

## Related

- [`docs/deploying-vms.md`](../../docs/deploying-vms.md) — role-class chooser + the canonical 7-step flow.
- [`docs/proxmox-prometheus-permissions.md`](../../docs/proxmox-prometheus-permissions.md) — `prometheus@pve!exporter` token setup.
- [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md) — `tofu@pve!apply` (provisioning) token.
- `modules/proxmox-vm/` — shared module.
- Vault doc `Homelab Monitoring — Prometheus, Grafana, and the MVP Dashboard.md` — design context.
- Upstream: [prometheus-pve/prometheus-pve-exporter](https://github.com/prometheus-pve/prometheus-pve-exporter),
  [natrontech/pbs-exporter](https://github.com/natrontech/pbs-exporter),
  [Grafana docs](https://grafana.com/docs/grafana/latest/setup-grafana/installation/debian/).
