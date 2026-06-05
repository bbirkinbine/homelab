# Proxmox API permissions for the monitoring stack

The monitoring VM (`vms/monitoring/`) needs **two** independent
read-only API tokens — one for each exporter:

| Part | Token | Bootstrap target | Below |
| --- | --- | --- | --- |
| **1** | `prometheus@pve!exporter` for [`prometheus-pve-exporter`](https://github.com/prometheus-pve/prometheus-pve-exporter) | Any one PVE node (replicates cluster-wide via pmxcfs) | [PVE — bootstrap](#part-1--pve-bootstrap) |
| **2** | `prometheus@pbs!exporter` for [`natrontech/pbs-exporter`](https://github.com/natrontech/pbs-exporter) | `pbs01` directly | [PBS — bootstrap](#part-2--pbs-bootstrap) |

Both halves are independent — you can run them in either order, and
the tokens have no awareness of each other. Both go into KeePassXC
under `Homelab/Prometheus/`, then get hand-pasted into the monitoring
VM in the operator ceremony documented at
[`vms/monitoring/README.md`](../vms/monitoring/README.md).

This file is sibling to [`proxmox-permissions.md`](proxmox-permissions.md)
(Packer) and [`proxmox-tofu-permissions.md`](proxmox-tofu-permissions.md)
(OpenTofu). Both of those use custom least-privilege roles because
their tokens *mutate* state; the monitoring exporters are strictly
read-only, so PVEAuditor / Audit (built-in roles) are the right
fit and match upstream's recommendation.

---

## Part 1 — PVE bootstrap

The four nodes are clustered (`homelab`), so `/etc/pve/user.cfg` is
replicated cluster-wide via pmxcfs. **Run the steps below once on any
node** — SSH into whichever is convenient (`pve12t`, `pve13m`, `pve13t`)
and the user, ACL, and token will land on all three.

### TL;DR — cluster-wide setup

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

### Verifying the PVE token

From your workstation:

```bash
PROXMOX_TOKEN='prometheus@pve!exporter=<secret-uuid>'
curl -k -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
  "https://pve12t:8006/api2/json/cluster/resources"
```

Expect a JSON object whose `data` array enumerates every VM, container,
node, and storage pool. `401` → token id/secret wrong. `403` → ACL
missing (re-check the `aclmod` step).

### Why PVEAuditor (not a custom role)

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

### Rotating the PVE token

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

### Tearing down the PVE token

```bash
pveum user token remove prometheus@pve exporter
pveum aclmod / -user prometheus@pve -role PVEAuditor -delete
pveum user delete prometheus@pve
```

### PVE Web UI equivalent

1. **Datacenter → Permissions → Users** → Add → user `prometheus`,
   realm `pve`.
2. **Datacenter → Permissions** → Add → Path `/`, User `prometheus@pve`,
   Role `PVEAuditor`.
3. **Datacenter → Permissions → API Tokens** → Add → user
   `prometheus@pve`, token ID `exporter`, **uncheck "Privilege
   Separation"**, copy the secret on creation (one-time reveal).

### Coexistence with the other PVE API users

`packer@pve`, `tofu@pve`, and `prometheus@pve` are independent users
with separate tokens, ACLs, and roles. Nothing requires one to know
about another. Separation keeps the blast radius small if any single
token leaks. (`prometheus@pbs` lives on a different host and is
unrelated — see Part 2 below.)

---

## Part 2 — PBS bootstrap

Separate token for the PBS-side of the monitoring stack
([natrontech/pbs-exporter](https://github.com/natrontech/pbs-exporter)).
PBS users + tokens are managed independently from PVE — the PBS host
has its own `proxmox-backup-manager` CLI and its own ACL system.

Two PBS-vs-PVE gotchas worth internalizing before running the commands
(both apply per the `project_pbs_token_privsep_intersection` memory):

1. **Token privsep is intersection-based on PBS 4.x.** Effective token
   perms = `(user perms) ∩ (token perms)`. Unlike PVE, granting the
   role to the user alone is NOT enough — the **token also needs its
   own ACL entry**. Both grants are required.
2. **Token auth-header uses `:` as the separator**, not PVE's `=`.
   Header form: `PBSAPIToken=<user>@<realm>!<tokenname>:<secret>`.

### Bootstrap on the PBS host

SSH in as `root` on `pbs01` and run:

```bash
# 1. Create the user. No --password needed — service identity, token auth only.
proxmox-backup-manager user create prometheus@pbs --comment "prometheus-pbs-exporter scrape user"

# 2. Grant Audit on the root path to the user.
proxmox-backup-manager acl update / Audit --auth-id prometheus@pbs

# 3. Mint the token. Output JSON contains the one-time secret as `value`.
proxmox-backup-manager user generate-token prometheus@pbs exporter --comment "PBS exporter token"

# 4. Grant the token its OWN Audit ACL (privsep intersection — step 2 alone
#    is insufficient because the token would intersect with no own grants).
proxmox-backup-manager acl update / Audit --auth-id 'prometheus@pbs!exporter'

# 5. Verify
proxmox-backup-manager user list-tokens prometheus@pbs
proxmox-backup-manager acl list
```

Step 3 prints something like:

```json
{
  "tokenid": "prometheus@pbs!exporter",
  "value": "00000000-0000-0000-0000-000000000000"
}
```

Stash the full `prometheus@pbs!exporter:<value>` string in KeePassXC
under `Homelab/Prometheus/pbs-api-token`. That combined string is what
the operator pastes into `/etc/prometheus/pbs-exporter.env`'s
`PBS_API_TOKEN=...` line on the monitoring VM — the natrontech
exporter concatenates `PBS_USERNAME`, `PBS_API_TOKEN_NAME`, and
`PBS_API_TOKEN` into the auth header using the `:` separator at scrape
time.

### Verifying the PBS token

From the monitoring VM (or any LAN host that can reach `pbs01:8007`):

```bash
TOKEN='prometheus@pbs!exporter:00000000-0000-0000-0000-000000000000'
curl -sk -H "Authorization: PBSAPIToken=$TOKEN" \
  https://pbs01:8007/api2/json/version
```

Expect `{"data":{"version":"4.x.x", ...}}`. `authentication failed` →
the user or token doesn't exist, OR the token's own ACL is missing
(step 4 above).

### Tearing down the PBS token

```bash
proxmox-backup-manager user delete-token prometheus@pbs exporter
proxmox-backup-manager acl delete / Audit --auth-id 'prometheus@pbs!exporter'
proxmox-backup-manager acl delete / Audit --auth-id prometheus@pbs
proxmox-backup-manager user delete prometheus@pbs
```

### PBS Web UI equivalent

If you'd rather click through the PBS UI:

1. **Configuration → Access Control → Users** → Add → user `prometheus`,
   realm `Proxmox Backup authentication server` (the `pbs` realm).
2. **Configuration → Access Control → Permissions** → Add → Path `/`,
   User `prometheus@pbs`, Role `Audit`.
3. **Configuration → Access Control → API Token** → Add → user
   `prometheus@pbs`, token name `exporter`. Copy the secret on creation
   (one-time reveal).
4. **Configuration → Access Control → Permissions** → Add → Path `/`,
   API Token `prometheus@pbs!exporter`, Role `Audit`. (Yes, a separate
   ACL row for the token — see the privsep gotcha above. Forgetting
   this step is the most common reason for `pbs_up 0` in the exporter.)

## See also

- [`vms/monitoring/README.md`](../vms/monitoring/README.md) — operator
  flow that consumes both tokens.
- [`prometheus-pve-exporter` README](https://github.com/prometheus-pve/prometheus-pve-exporter)
  — upstream PVE auth + scrape semantics.
- [`natrontech/pbs-exporter` README](https://github.com/natrontech/pbs-exporter)
  — upstream PBS auth + scrape semantics.
