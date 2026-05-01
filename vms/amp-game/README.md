# amp-game

VM running [CubeCoders AMP](https://cubecoders.com/AMP) for hosting game servers
(Minecraft initially). Cloned at deploy time from the `ubuntu-24-04-base`
template; cloud-init lays down the admin user, ufw rules, and unattended-upgrades.
AMP itself is installed manually after first boot — see [Post-deploy](#post-deploy).

## Prerequisites

Things that must already be true on the Proxmox node before `deploy.sh` will work:

1. **`ubuntu-24-04-base` template exists** (default ID `9100`).
   If not, run `packer/ubuntu-24-04-base/build.sh <node>` first.

2. **Snippets content type enabled on the snippets storage.**
   Datacenter → Storage → `local` (or whichever you use) → Edit →
   under **Content**, check **Snippets**. Without this, `deploy.sh` will
   fail at the snippet upload step.

3. **SSH access from this Mac to the Proxmox node** as a user that can run
   `qm` and `pvesh` (typically `root`). Test with:
   ```
   ssh root@<proxmox-host> 'qm list | head'
   ```

4. **Target VM ID is free.** `deploy.sh` is fail-fast — it will refuse to
   touch an existing VM (protects saved games). Default ID is `110`;
   change in `.env` if it collides.

## Configuration

```
cp .env.example .env
# edit .env: set PROXMOX_HOST, SSH_PUBLIC_KEY, confirm VM_ID
```

`.env` is gitignored.

## Deploy

```
./deploy.sh
```

Runs from your Mac, SSHes to the Proxmox node, and:

1. Verifies template `9100` exists and target `VM_ID` does not.
2. Resolves the snippets path on the node via `pvesh`.
3. Renders `cloud-init/user-data.yaml` with values from `.env`.
4. `scp`s the rendered snippet to `<storage_path>/snippets/`.
5. `qm clone` (full) → `qm set` (cores/memory/balloon) → `qm resize scsi0`
   → `qm set --cicustom + --ipconfig0 ip=dhcp` → `qm start`.

The script prints next-step instructions on success.

## Post-deploy

Once the VM is up and reachable:

1. Find the VM's IP — see [Find the VM's IP](#find-the-vms-ip) below.

2. SSH in and run the AMP installer:
   ```
   ssh amp-admin@<vm-ip>
   sudo su -
   bash <(curl -fsSL https://getamp.sh)
   ```
   `https://getamp.sh` is CubeCoders' canonical short URL — at the time
   of writing it 302-redirects to `https://cdn-downloads.c7rs.com/getamp.sh`
   (their Cloudflare-fronted CDN). The short URL is the documented entrypoint;
   prefer it over hardcoding the CDN URL so future CDN changes don't break.

   Installer prompts:
   - Dashboard username + password: your choice
   - "Run Docker?": **n** — vanilla MC doesn't benefit from container
     isolation. Answer **y** only if you add Steam-based games (ARK, Rust,
     7DTD) where Docker isolates library/glibc conflicts.
   - "Configure HTTPS?": **n** (LAN-only)

3. Open `http://<vm-ip>:<port shown by installer>` (default 8080), paste
   your AMP license key, choose **Standalone** mode.

After this, day-to-day admin is via the AMP web UI — no Linux access required.

## Sizing

Default in `.env.example`:

| Resource | Value | Why |
|---|---|---|
| vCPU | 4 | MC's main thread is single-threaded; 4 cores covers AMP + JVM GC + a 2nd instance later |
| RAM | 12288 MB | ~8 GB JVM heap + headroom for AMP/OS/page cache; well past the 8 GB rpi5 baseline |
| Disk | 100 GB | Game installs + AMP backups + world growth; thin-provisioned |

Resize-able later via `qm` on the node — see [Operations](#operations).

## Ports

| Port | Protocol | Source | Purpose |
|---|---|---|---|
| 22 | tcp | LAN | SSH (allowed by base template) |
| 8080 | tcp | LAN | AMP web UI (default; installer may pick a different port) |
| 25565 | tcp/udp | LAN | Minecraft Java / Bedrock |

UFW is set inside the VM. Perimeter firewall (router) is what gates external
access — port-forward only when guests need to connect from outside the LAN.

## Operations

### Find the VM's IP

DHCP lease, so the IP can change. Three ways to look it up:

**1. qm guest cmd from your Mac (works as long as qemu-guest-agent is running in the VM):**

```bash
ssh root@<proxmox-host> 'qm guest cmd 110 network-get-interfaces' \
  | grep -E '"ip-address" *: *"[0-9]+\.' \
  | grep -v '"127\.0\.0\.1"'
```

If `jq` is installed locally, this is cleaner:

```bash
ssh root@<proxmox-host> 'qm guest cmd 110 network-get-interfaces' \
  | jq -r '.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"'
```

**2. Proxmox Web UI:** open `https://<proxmox-host>:8006`, select VM `110` → Summary
tab. The "IPs" row shows what qemu-guest-agent reports, same data as above.

**3. Router / DHCP server lease table:** look for hostname `amp-game`. Useful as a
fallback if qemu-guest-agent is broken or the VM hasn't booted far enough yet.

If you want to stop chasing the IP, set a DHCP reservation on your router for
the VM's MAC address (visible via `ssh root@<proxmox-host> 'qm config 110 | grep ^net0'`).

### Resize a running VM

`deploy.sh` will refuse to touch an existing VM. To change sizing on the
running deployment, ssh to the node:

```
qm set 110 --memory 16384 --cores 6
qm resize 110 scsi0 +50G
```

Memory and disk grow live (no reboot for memory if balloon is enabled;
disk grows online). Cores require a reboot to take effect.

### Re-apply cloud-init

The cloud-init snippet runs once per `instance-id`. To re-run on next boot:

```
ssh amp-admin@<vm-ip> 'sudo cloud-init clean'
ssh root@<proxmox-host> 'qm reboot 110'
```

Note: this re-runs `runcmd`, which is idempotent for our config (ufw rules
add cleanly even if already present).

### Update the cloud-init snippet on the node

If you edit `cloud-init/user-data.yaml`, the change does NOT propagate to
the running VM automatically. Either re-deploy from scratch (destroy +
re-create — only acceptable if no saved data) or manually edit the file
on the Proxmox node:

```
ssh root@<proxmox-host>
vi /var/lib/vz/snippets/vm-110-amp-game-user.yaml
qm reboot 110   # only if you want it to take effect now
```

### Recovery

VM won't boot or AMP corrupted:

1. Take a Proxmox snapshot before any risky change (UI: VM → Snapshots).
2. Roll back via Proxmox UI or `qm rollback 110 <snapshot-name>`.
3. Game-server-level backups: AMP has its own backup feature in the web UI.
   Configure scheduled backups under each instance's Schedule tab.

### Destroy and rebuild

If you really need to start over (no saved games, or saves are backed up):

```
ssh root@<proxmox-host> 'qm stop 110 && qm destroy 110'
./deploy.sh
```

## Files

- `.env.example` — committed; documents required vars
- `.env` — gitignored; your real values
- `deploy.sh` — clone + size + start
- `cloud-init/user-data.yaml` — first-boot config (rendered before upload)
