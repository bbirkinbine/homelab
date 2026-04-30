# packer-ubuntu-24-04-base

Packer template that builds a hardened Ubuntu Server 24.04 LTS (Noble) VM
template on a Proxmox VE node. The output is the universal parent template
for every homelab VM role (offline Root CA, OpenBao node, k3s nodes,
services).

Companion design doc: `../../Packer Ubuntu-24.04 Base Image for Proxmox NUCs.md`
in the Obsidian vault. Read that first — it explains *why* the choices below
are what they are.

## Quick start

```bash
# 1. Install packer (macOS)
brew install packer

# 2. Configure local credentials (one per Proxmox node)
cp .env.example .env.pve12   # repeat for each node, e.g. .env.pve13
$EDITOR .env.pve12           # fill in PROXMOX_URL, PROXMOX_TOKEN_*, NODE, etc.

# 3. Initialize the Proxmox plugin (one-time)
packer init .

# 4. Build (pass the node name)
./build.sh pve12             # or: ./build.sh pve13
```

The build takes ~20-30 minutes on an NUC12. When it's done you have a
Proxmox template at VM ID `9100` named `ubuntu-24-04-base`.

## What you need before you start

- **Proxmox VE 8.x or 9.x** running on the target node (NUC12 or NUC13).
- **API token** for a user with role permissions to create VMs, attach ISOs,
  and convert VMs to templates. Recommended: a dedicated `packer@pve!builder`
  token, separate from the Terraform token. The full setup runbook (user,
  role, ACL, token) lives in
  [../../docs/proxmox-permissions.md](../../docs/proxmox-permissions.md) —
  run it once on every Proxmox node before pointing Packer at it.
- **Ubuntu 24.04.x live-server ISO** uploaded to the node's ISO storage pool,
  OR a reachable URL Proxmox can download. The variable `iso_file` controls
  which (default expects an already-uploaded ISO at
  `local:iso/ubuntu-24.04.1-live-server-amd64.iso`).
- **Network reach**: your workstation must be able to reach the Proxmox API
  AND the SSH IP the VM gets during the build (from autoinstall, the VM uses
  DHCP on `vmbr0`). If the build VM ends up on a VLAN you can't route to,
  change the `vlan_tag` variable or use a build network.

## Files

- `versions.pkr.hcl` — pins the Proxmox plugin version
- `variables.pkr.hcl` — input variables (token, node, VM ID, ISO, storage)
- `ubuntu-24-04-base.pkr.hcl` — the `proxmox-iso` source + build block
- `http/user-data` — Ubuntu autoinstall (subiquity) config
- `http/meta-data` — minimal cloud-init meta-data
- `provision/*.sh` — shell provisioner scripts run in numbered order
- `build.sh` — convenience wrapper (sources `.env.<node>`, runs `packer validate` + `packer build`)
- `.env.example` — template for local credentials (do NOT commit a filled-in `.env.<node>`)

## After a successful build

In the Proxmox UI on the target node, you should see VM `9100`:

- Marked as a Template
- 2 cores, 4096 MB RAM, 20 GB disk
- No CD-ROM (live-server ISO unmounted)
- A `cloud-init` drive on the next free IDE slot (typically `ide0` or `ide2`,
  depending on what was free)
- Disk on the configured storage pool, default `local-lvm`
- Serial console + VGA serial output enabled
- `packer-cleanup.service` enabled but not yet run — fires on first boot of a clone

### Template-side verification (no clone needed)

From your workstation:

```bash
source .env.<node>
AUTH="Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"

# Confirm template flag + key config
curl -sk -H "$AUTH" "${PROXMOX_URL}/nodes/${PROXMOX_NODE}/qemu/9100/config" \
  | python3 -m json.tool | grep -E 'template|cores|memory|scsi0|ide[0-9]|vga'
```

Expect `"template": 1`, `cores: 2`, `memory: "4096"`, scsi0 with `size=20G`,
an `ideN` line containing `vm-9100-cloudinit`, `vga: "type=serial0,memory=16"`.

On the Proxmox host, confirm the disk is properly compacted:

```bash
ssh root@<node> 'lvs -a -o lv_name,size,data_percent,origin,pool_lv | grep 9100'
```

Reference output from a clean build (2026-04-30):

```text
  base-9100-disk-0    20.00g               data
  vm-9100-cloudinit    4.00m 9.38          data
```

`data_percent` on `base-*-disk-0` displays blank — that's expected for a
template's read-only origin volume; the percentage column doesn't track for
thin-snapshot origins. To inspect actual allocation, look at the pool itself
(`lvs <pool> --units g`) or the build log line `==> trim free space ...`
which prints how many GiB were trimmed (clean build trimmed 13.4 GiB, so
real allocation on the pool is ~3-4 GB out of the 20 GB virtual size).

### Clone-side verification

The build defers the `packer` user deletion to a one-shot systemd unit that
runs on first boot of any clone (see [provision/99-cleanup.sh](provision/99-cleanup.sh)
and the design note inline). Validate by cloning:

```bash
# On the Proxmox host
qm clone 9100 9101 --name test-clone --full
qm set 9101 --ipconfig0 ip=dhcp --sshkeys ~/.ssh/authorized_keys
qm start 9101

# Wait ~30s for first boot to settle, then run via guest agent
qm guest exec 9101 -- /usr/bin/getent passwd packer
#   exitcode=2, no stdout — packer user gone

qm guest exec 9101 -- /usr/bin/systemctl is-enabled packer-cleanup.service
#   exitcode=1, stdout="disabled" — unit ran and self-disabled

qm guest exec 9101 -- /bin/ls /etc/systemd/system/packer-cleanup.service
#   exitcode=2 — unit file removed by self-destruct

qm guest exec 9101 -- /bin/ls /usr/local/sbin/packer-cleanup.sh
#   exitcode=2 — script removed by self-destruct
```

Once your SSH key is injected (via `--sshkeys`), the rest of the
inside-VM checks:

```bash
ssh <youruser>@<vm-ip>
ss -tlnp                                # only sshd listening
ufw status                              # active, allow 22
systemctl is-enabled apt-daily.timer    # masked
systemctl is-active auditd              # active
snap list 2>&1                          # 'command not found' or 'No snaps'
pro config show apt_news                # false

# Tear down the test
exit
qm stop 9101 && qm destroy 9101
```

## Trust-anchor reminder

This image is the parent for the offline Root CA VM. **Do not** add anything
that reaches out to the network on its own (auto-update timers, telemetry,
package fetchers, snap refresh, motd-news, Ubuntu Pro apt_news). If you're
tempted to add such a thing, layer it on per-role instead. See the design
doc's "Trust-anchor implications" section.

## Updating the Ubuntu point release

1. Bump `iso_file` (and `iso_checksum` if using `iso_url`) in each
   `.env.<node>` to the newer point release (24.04.2, .3, etc.).
2. Verify the SHA256 against
   <https://releases.ubuntu.com/24.04/SHA256SUMS>.
3. Re-run `./build.sh <node>` for each Proxmox host. Packer creates a fresh
   template; if the VM ID is unchanged you'll need to delete the old
   template first.

## Changing the build user / password

The build user `packer` is created by autoinstall using the SHA-512 hash
embedded in `http/user-data`. To change the password:

```bash
python3 -c "import crypt; print(crypt.crypt('NEWPASS', crypt.mksalt(crypt.METHOD_SHA512)))"
```

Replace the `password:` field in `http/user-data`, then update
`BUILD_PASSWORD` in each `.env.<node>` to the matching plaintext (Packer
uses the plaintext for SSH).

## Troubleshooting

- **`packer init` fails to download the plugin** — check workstation network;
  the plugin comes from the HashiCorp registry over HTTPS.
- **Build hangs at "Waiting for SSH"** — autoinstall takes 15-25 minutes on
  a slow mirror, or the VM didn't get a DHCP lease, or you can't route to
  it. Look at the VM's serial console in the Proxmox UI.
- **Autoinstall asks "Continue with autoinstall? (yes|no)"** — your
  `user-data` has interactive sections. The default config in this repo has
  none; if you customized, add `interactive-sections: []` under
  `autoinstall:`.
- **GRUB boot menu times out before our boot_command lands** — increase
  `boot_wait` in `ubuntu-24-04-base.pkr.hcl` (default is 5s).
- **"VM ID 9100 already exists"** — delete the old template first
  (`qm destroy 9100`) or bump the `vm_id` variable.
- **Snap reappears after first boot** — `apt-mark hold snapd` should
  prevent that, but check `apt-mark showhold`. If something else
  (`recommends` of a meta-package?) re-installed it, add to the purge list
  in `15-ubuntu-cleanup.sh`.
