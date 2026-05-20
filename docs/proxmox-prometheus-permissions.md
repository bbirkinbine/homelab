# Proxmox API permissions for `prometheus-pve-exporter`

This document records how to provision the `prometheus@pve` user, the
`PVEAuditor` role grant, and the API token that the
[`prometheus-pve-exporter`](https://github.com/prometheus-pve/prometheus-pve-exporter)
running on [`vms/monitoring/`](../vms/monitoring/) uses to scrape per-VM
and cluster-wide metrics from the Proxmox API.

Sibling of [`proxmox-permissions.md`](proxmox-permissions.md) (Packer)
and [`proxmox-tofu-permissions.md`](proxmox-tofu-permissions.md)
(OpenTofu). Unlike those two — both of which use a custom least-privilege
role because they have *mutation* surface — the monitoring exporter is
strictly read-only, so the built-in `PVEAuditor` role is the natural
fit and matches upstream's recommendation.

The three nodes are clustered (`homelab`), so `/etc/pve/user.cfg` is
replicated cluster-wide via pmxcfs. **Run the steps below once on any
node** — SSH into whichever is convenient (`pve12t`, `pve13m`, `pve13t`)
and the user, ACL, and token will land on all three.

## TL;DR — cluster-wide setup

SSH in as `root` on any one node and run:

```bash
# 1. Create the user (no shell login — purely an API identity)
pveum user add prometheus@pve --comment "prometheus-pve-exporter scrape user"

# 2. Grant the built-in PVEAuditor role at the datacenter root.
#    PVEAuditor is read-only across VMs, containers, storage, nodes,
#    SDN, pools — exactly what the exporter needs and nothing more.
pveum aclmod / -user prometheus@pve -role PVEAuditor

# 3. Mint an API token. --privsep 0 lets the token inherit the user's
#    perms; otherwise you would need a second ACL on the token itself.
pveum user token add prometheus@pve exporter --privsep 0
```

The last command prints a one-time `value` field — that's the token
secret. Combine with the token id to form the
`user@realm!tokenid=secret` string that goes into
`/etc/prometheus/pve.yml` on the monitoring VM as `token_value`.

Stash that combined string in KeePassXC under
`Homelab/Prometheus/proxmox-api-token` so the operator ceremony in
[`vms/monitoring/README.md`](../vms/monitoring/README.md) can paste it.

## Verifying the token

From your workstation:

```bash
PROXMOX_TOKEN='prometheus@pve!exporter=<secret-uuid>'
curl -k -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
  "https://pve12t:8006/api2/json/cluster/resources"
```

Expect a JSON object whose `data` array enumerates every VM, container,
node, and storage pool. `401` → token id/secret wrong. `403` → ACL
missing (re-check the `aclmod` step).

## Why PVEAuditor (not a custom role)

`PVEAuditor` grants `VM.Audit`, `Sys.Audit`, `Datastore.Audit`,
`SDN.Audit`, `Mapping.Audit`, `Permissions.Read`, `Group.Allocate`,
`Pool.Audit` — every `*.Audit` privilege the exporter touches. None of
them carry write capability, so the token's blast radius is `read
everything`.

The custom-role pattern from
[`proxmox-tofu-permissions.md`](proxmox-tofu-permissions.md) exists
because OpenTofu's role *does* mutate state and the operator wants the
narrowest possible privilege list. For a pure-read identity like this
one, the upstream recommendation in the
[`prometheus-pve-exporter` README](https://github.com/prometheus-pve/prometheus-pve-exporter)
is to use `PVEAuditor`, and we follow it.

## Rotating the token

```bash
pveum user token remove prometheus@pve exporter
pveum user token add prometheus@pve exporter --privsep 0
```

Update the KeePassXC entry `Homelab/Prometheus/proxmox-api-token` with
the new value, then on the monitoring VM:

```bash
sudoedit /etc/prometheus/pve.yml          # paste the new token_value
sudo systemctl restart prometheus-pve-exporter
```

## Tearing down

```bash
pveum user token remove prometheus@pve exporter
pveum aclmod / -user prometheus@pve -role PVEAuditor -delete
pveum user delete prometheus@pve
```

## Web UI equivalent

1. **Datacenter → Permissions → Users** → Add → user `prometheus`,
   realm `pve`.
2. **Datacenter → Permissions** → Add → Path `/`, User `prometheus@pve`,
   Role `PVEAuditor`.
3. **Datacenter → Permissions → API Tokens** → Add → user
   `prometheus@pve`, token ID `exporter`, **uncheck "Privilege
   Separation"**, copy the secret on creation (one-time reveal).

## Coexistence with the other Proxmox API users

`packer@pve`, `tofu@pve`, and `prometheus@pve` are independent users
with separate tokens, ACLs, and roles. Nothing requires one to know
about another. Separation keeps the blast radius small if any single
token leaks.

## See also

- [`vms/monitoring/README.md`](../vms/monitoring/README.md) — operator
  flow that consumes this token.
- [`prometheus-pve-exporter` README](https://github.com/prometheus-pve/prometheus-pve-exporter)
  — upstream auth + scrape semantics.
- PBS-side equivalent — the read-only token for
  `prometheus-pbs-exporter` is created in the PBS UI (Configuration →
  Access Control → API Tokens) with role `Audit` at `/`. PBS's token
  string uses `:` as the separator vs PVE's `=`.
