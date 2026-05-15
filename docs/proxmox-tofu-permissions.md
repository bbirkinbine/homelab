# Proxmox API permissions for OpenTofu

This document records how to provision the `tofu@pve` user, the `Tofu`
role, and the API token that [the OpenTofu-driven VM
provisioning](../vms/) (currently just `vms/openbao/`, more roles
landing) uses to talk to a Proxmox host.

Sibling of [`proxmox-permissions.md`](proxmox-permissions.md), which
documents the same shape for Packer. The two roles overlap heavily —
OpenTofu's role is Packer's **minus** `VM.Config.CDROM` and
`VM.Console`, because tofu does not attach an install ISO and does
not send boot commands over VNC.

The three nodes are clustered (`homelab`), so `/etc/pve/user.cfg` is
replicated cluster-wide via pmxcfs. **Run the steps below once on any
node** — SSH into whichever is convenient (`pve12t`, `pve13m`, `pve13t`)
and the user, role, ACL, and token will land on all three.

## TL;DR — cluster-wide setup

SSH in as `root` on any one node and run:

```bash
# 1. Create the user (no shell login — purely an API identity)
pveum user add tofu@pve --comment "OpenTofu provisioning user"

# 2. Create the least-privilege role for VM provisioning + snippet
#    upload. SDN.Use and VM.GuestAgent.Audit are required on PVE 9+.
pveum role add Tofu -privs "VM.Allocate VM.Clone VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Audit VM.PowerMgmt VM.GuestAgent.Audit Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Sys.Audit SDN.Use"

# 3. Grant the role at the datacenter root.
pveum aclmod / -user tofu@pve -role Tofu

# 4. Mint an API token. --privsep 0 lets the token inherit the user's
#    perms; --privsep 1 would require a second ACL on the token itself.
pveum user token add tofu@pve apply --privsep 0
```

The last command prints a one-time `value` field — that's the token
secret. Combine with the token id to form the
`user@realm!tokenid=secret` string that goes into
`vms/<role>/terraform/terraform.tfvars` as `proxmox_api_token`.

Stash that combined string in KeePassXC under `Homelab/Tofu/proxmox-api-token`
so `scripts/hydrate.sh` can pull it on demand — see `docs/opentofu-setup.md`
for the hydration flow.

## SSH access requirement (in addition to the API token)

The `bpg/proxmox` provider uses **SSH** (not the HTTP API) to upload
cloud-init snippet files. The API token alone is not sufficient. The
provider's `ssh { agent = true; username = "root" }` block in
`vms/openbao/terraform/main.tf` means it talks to the node as root
using whatever key your `ssh-agent` is holding.

Ensure the workstation's pubkey is in `root@<node>:~/.ssh/authorized_keys`:

```bash
ssh-copy-id root@pve12t
```

`scripts/preflight.sh` verifies this before every `tofu apply` (it
runs `ssh -o BatchMode=yes root@<host> true`).

If you'd rather not use root for SSH, create a dedicated `tofu` Unix
user on each node with passwordless `sudo qm`/`sudo pvesh`, and set
`ssh.username = "tofu"` in the provider block. The role's docs are
permissive — Brian uses root because the homelab is small and SSH
to root is already the established convention from the Packer side.

## Verifying the token

From your workstation:

```bash
PROXMOX_TOKEN='tofu@pve!apply=<secret-uuid>'
curl -k -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
  "https://pve12t:8006/api2/json/version"
```

Expect `{"data":{"version":"9.x.x", ...}}`. A `401` means the token
ID or secret is wrong; a `403` means the role is missing a privilege
(see *Adding a privilege* below).

## Privilege rationale

Same shape as the Packer doc's table — repeated here so this file
stands alone.

| Privilege | Why tofu needs it |
| --- | --- |
| `VM.Allocate` | Create the cloned VM. |
| `VM.Clone` | Clone from the Packer-built template (9100 = ubuntu-24-04-base). |
| `VM.Config.CPU` | Set `cpu.type`, cores, sockets. |
| `VM.Config.Cloudinit` | Attach the cloud-init drive populated from the snippet. |
| `VM.Config.Disk` | Resize `scsi0` to the role's disk_size_gb. |
| `VM.Config.HWType` | Set machine type (`q35`), scsihw. |
| `VM.Config.Memory` | Set RAM (and balloon=0 floor). |
| `VM.Config.Network` | Configure NIC bridges. |
| `VM.Config.Options` | Set name, tags, agent, onboot. |
| `VM.Audit` | Read VM state — required during plan to detect drift. |
| `VM.PowerMgmt` | Start the VM after create. |
| `VM.GuestAgent.Audit` | **PVE 9+ only.** Read guest-agent network info → populates `proxmox_virtual_environment_vm.this.ipv4_addresses`, which feeds Ansible inventory. |
| `Datastore.Allocate` | Cleanup-side: remove the cloud-init snippet on destroy. |
| `Datastore.AllocateSpace` | Write the clone's disk on `local-lvm`. |
| `Datastore.AllocateTemplate` | Upload the cloud-init snippet to the snippets storage (provider uses this API path). |
| `Datastore.Audit` | Read storage capacity + list snippets. |
| `Sys.Audit` | Read node info — `/nodes/<node>/status` is hit on every plan. |
| `SDN.Use` | **PVE 9+ only.** Attach the NIC to vmbr0 (the implicit `localnetwork` SDN zone). |

**Not granted:** `VM.Config.CDROM` (no ISO attach), `VM.Console` (no
VNC keystroke delivery), `Sys.Modify` / `Sys.Console` (no host
edits), `VM.Migrate`, `VM.Backup`, `VM.Snapshot*`, `Realm.*`,
`User.Modify`, `Permissions.Modify`, `Pool.*`, `Mapping.*`. The
explicit omissions match the Packer doc's rationale — the principle
is "the smallest privilege set that makes the build succeed and no
more."

## Adding a privilege

If a tofu apply fails with `403 Permission check failed (..., <Priv>)`:

```bash
pveum role modify Tofu --append -privs "<NewPriv>"
```

Update this doc when you do. Drift between the doc and the live ACL is
the whole reason the file exists.

## Rotating the token

```bash
pveum user token remove tofu@pve apply
pveum user token add tofu@pve apply --privsep 0
```

Then update the KeePassXC entry `Homelab/Tofu/proxmox-api-token` so
the next `just hydrate openbao` picks up the new value.

## Tearing down

```bash
pveum user token remove tofu@pve apply
pveum aclmod / -user tofu@pve -role Tofu -delete
pveum user delete tofu@pve
pveum role delete Tofu
```

## Web UI equivalent

1. **Datacenter → Permissions → Users** → Add → user `tofu`, realm `pve`.
2. **Datacenter → Permissions → Roles** → Create → name `Tofu`, paste
   the privilege list from the TL;DR.
3. **Datacenter → Permissions** → Add → Path `/`, User `tofu@pve`,
   Role `Tofu`.
4. **Datacenter → Permissions → API Tokens** → Add → user `tofu@pve`,
   token ID `apply`, **uncheck "Privilege Separation"**, copy the
   secret on creation (one-time reveal).

## Coexistence with the Packer user

`packer@pve` and `tofu@pve` are independent users with separate
tokens and ACLs. Nothing requires one to know about the other. If
you ever want a single user to drive both pipelines, grant both
roles to the same user — but keeping them separate is the cleaner
default (smaller blast radius if one token leaks).
