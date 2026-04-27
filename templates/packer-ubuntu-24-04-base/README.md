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

# 2. Configure local credentials (one-time)
cp .env.example .env
$EDITOR .env             # fill in PROXMOX_URL, PROXMOX_TOKEN_*, NODE, etc.

# 3. Initialize the Proxmox plugin (one-time)
packer init .

# 4. Build
./build.sh
```

The build takes ~20-30 minutes on an NUC12. When it's done you have a
Proxmox template at VM ID `9100` named `ubuntu-24-04-base`.

## What you need before you start

- **Proxmox VE 8.x** running on the target node (NUC12 or NUC13).
- **API token** for a user with role permissions to create VMs, attach ISOs,
  and convert VMs to templates. Recommended: a dedicated `packer@pve!builder`
  token, separate from the Terraform token. See `.env.example`.
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
- `build.sh` — convenience wrapper (sources `.env`, runs `packer validate` + `packer build`)
- `.env.example` — template for local credentials (do NOT commit a filled-in `.env`)

## After a successful build

In the Proxmox UI on the target node, you should see VM `9100`:

- Marked as a Template
- No CD-ROM attached
- A `cloud-init` drive on `ide2`
- Disk on the configured storage pool, default `local-lvm`
- Serial console + VGA serial output enabled

Verify by cloning it and booting:

```bash
# On the Proxmox host
qm clone 9100 999 --name ubuntu-test --full
qm set 999 --ipconfig0 ip=dhcp --sshkeys ~/.ssh/authorized_keys
qm start 999

# Wait ~30s, find the IP, then:
ssh brian@<vm-ip>

# Inside the VM:
ss -tlnp                                # only sshd listening
ufw status                              # active, allow 22
systemctl is-enabled apt-daily.timer    # masked
systemctl is-active auditd              # active
snap list 2>&1                          # 'command not found' or 'No snaps'
pro config show apt_news                # false

# Tear down the test
qm stop 999 && qm destroy 999
```

## Trust-anchor reminder

This image is the parent for the offline Root CA VM. **Do not** add anything
that reaches out to the network on its own (auto-update timers, telemetry,
package fetchers, snap refresh, motd-news, Ubuntu Pro apt_news). If you're
tempted to add such a thing, layer it on per-role instead. See the design
doc's "Trust-anchor implications" section.

## Updating the Ubuntu point release

1. Bump `iso_file` (and `iso_checksum` if using `iso_url`) in `.env` to the
   newer point release (24.04.2, .3, etc.).
2. Verify the SHA256 against
   <https://releases.ubuntu.com/24.04/SHA256SUMS>.
3. Re-run `./build.sh`. Packer creates a fresh template; if the VM ID is
   unchanged you'll need to delete the old template first.

## Changing the build user / password

The build user `packer` is created by autoinstall using the SHA-512 hash
embedded in `http/user-data`. To change the password:

```bash
python3 -c "import crypt; print(crypt.crypt('NEWPASS', crypt.mksalt(crypt.METHOD_SHA512)))"
```

Replace the `password:` field in `http/user-data`, then update
`BUILD_PASSWORD` in `.env` to the matching plaintext (Packer uses the
plaintext for SSH).

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
