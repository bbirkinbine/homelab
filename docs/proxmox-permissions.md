# Proxmox API permissions for Packer

This document records how to provision the `packer@pve` user, the `Packer`
role, and the API token that [the Ubuntu base template
build](../templates/packer-ubuntu-24-04-base/) uses to talk to a Proxmox
host.

The hosts are independent (not clustered), so **run this on every Proxmox
node** Packer will build against (`pve12`, `pve13`, ...). Each node has its
own user database and ACL — the steps don't replicate.

## TL;DR — fresh-node setup

SSH in as `root` on the target Proxmox host and run:

```bash
# 1. Create the user (no shell login — purely an API identity)
pveum user add packer@pve --comment "Packer build user"

# 2. Create the least-privilege role for VM-template builds.
#    SDN.Use and VM.GuestAgent.Audit are required on PVE 9+
#    (NIC attach + guest-agent IP discovery).
pveum role add Packer -privs "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Console VM.Audit VM.PowerMgmt VM.GuestAgent.Audit Datastore.AllocateSpace Datastore.Audit Sys.Audit SDN.Use"

# 3. Grant the role at the datacenter root.
#    Tighten later by scoping to /vms, /storage/<pool>, /sdn/zones/localnetwork.
pveum aclmod / -user packer@pve -role Packer

# 4. Mint an API token. --privsep 0 lets the token inherit the user's perms;
#    --privsep 1 would require a second ACL on the token itself.
pveum user token add packer@pve builder --privsep 0
```

The last command prints a one-time `value` field — that's the token
secret. Paste it into `.env.<node>` as `PROXMOX_TOKEN_SECRET`. Proxmox
will not show it again.

## Verifying the token

From your workstation:

```bash
cd templates/packer-ubuntu-24-04-base
source .env.<node>
curl -k -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "${PROXMOX_URL}/version"
```

Expect `{"data":{"version":"9.x.x", ...}}`. A `401` means the token ID or
secret is wrong; a `403` means the role is missing a privilege (see the
*Adding a privilege* section).

## Privilege rationale

| Privilege | Why Packer needs it |
|---|---|
| `VM.Allocate` | Create the build VM. |
| `VM.Clone` | Convert the build VM to a template (which Proxmox treats as a clone-source operation). |
| `VM.Config.CDROM` | Attach the Ubuntu live-server ISO. |
| `VM.Config.CPU` | Set `cpu: host`, cores, sockets. |
| `VM.Config.Cloudinit` | Attach the cloud-init drive baked into the template. |
| `VM.Config.Disk` | Create the boot disk on `local-lvm`. |
| `VM.Config.HWType` | Set `scsihw: virtio-scsi-single`, machine type, etc. |
| `VM.Config.Memory` | Set RAM. |
| `VM.Config.Network` | Attach the NIC to `vmbr0`. |
| `VM.Config.Options` | Set name, description, agent, ostype, onboot, tags. |
| `VM.Console` | Send the autoinstall boot command via VNC during the build. |
| `VM.Audit` | Read VM state to wait for it to come up. |
| `VM.PowerMgmt` | Start, stop, reset the build VM. |
| `VM.GuestAgent.Audit` | **PVE 9+ only.** Read guest-agent network info — Packer uses this to discover the VM's IP for SSH (`qemu_agent = true` in the build). |
| `Datastore.AllocateSpace` | Write the disk and (if used) the downloaded ISO. |
| `Datastore.Audit` | Read storage capacity / list ISOs. |
| `Sys.Audit` | Read node info (`/nodes/<node>/status`). |
| `SDN.Use` | **PVE 9+ only.** Required to attach to any bridge — even plain Linux bridges live under the implicit `localnetwork` SDN zone now. |

Privileges deliberately *not* granted (and what they'd unlock):

- `Sys.Modify` / `Sys.Console` — host config and shell.
- `VM.Migrate` — move VMs between nodes.
- `VM.Backup`, `VM.Snapshot*` — back up or snapshot existing VMs.
- `Realm.*`, `User.Modify`, `Permissions.Modify` — manage other users/roles.
- `Pool.*`, `Mapping.*` — resource pools, PCI/USB mapping (eGPU passthrough lives here).

## Adding a privilege

If a build fails with `403 Permission check failed (..., <Priv>)`, append
the missing privilege to the role:

```bash
pveum role modify Packer -privs "VM.Allocate VM.Clone ...existing... <NewPriv>"
# or, append-only:
pveum role modify Packer --append -privs "<NewPriv>"
```

The privilege list is overwritten by default, so prefer `--append` for
single additions; use the full list when you want the file to be
self-documenting. **Update this doc** when you do — drift between the doc
and the live ACL is the whole reason this file exists.

## Rotating the token

```bash
pveum user token remove packer@pve builder
pveum user token add packer@pve builder --privsep 0
```

Then update `PROXMOX_TOKEN_SECRET` in the affected `.env.<node>`.

## Tearing down

```bash
pveum user token remove packer@pve builder
pveum aclmod / -user packer@pve -role Packer -delete
pveum user delete packer@pve
pveum role delete Packer
```

## Web UI equivalent

If you'd rather click than type:

1. **Datacenter → Permissions → Users** → Add → user `packer`, realm `pve`.
2. **Datacenter → Permissions → Roles** → Create → name `Packer`,
   privileges as listed above.
3. **Datacenter → Permissions** → Add → Path `/`, User `packer@pve`,
   Role `Packer`.
4. **Datacenter → Permissions → API Tokens** → Add → user `packer@pve`,
   token ID `builder`, **uncheck "Privilege Separation"**, copy the
   secret on creation (one-time reveal).
