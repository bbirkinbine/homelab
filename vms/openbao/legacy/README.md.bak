# openbao

VM for running OpenBao (HashiCorp Vault fork) with the seal stanza
backed by a CardLogix SmartCard-HSM 4K via PKCS#11. Cloned at deploy
time from the `ubuntu-24-04-base` template; cloud-init installs the
smartcard stack and OpenBao but **does not** initialize the vault,
generate any seal keys on the HSM, or write a seal stanza — those steps
are deliberately operator-driven and live in the
"Vault Auto-Unseal with CardLogix Pair" runbook (the ceremony doc, not
in this public repo).

The immediate goal of `./deploy.sh` is narrower than the production
purpose: prove that the HSM enumerates inside the guest. Once that's
verified, the same VM is the host for Phase 4 onward of the ceremony.

## Prerequisites

Things that must already be true on the Proxmox node before `deploy.sh`
will work:

1. **`ubuntu-24-04-base` template exists** (default ID `9100`).
   If not, run `packer/ubuntu-24-04-base/build.sh <node>` first.

2. **CardLogix SmartCard-HSM 4K is plugged into the labeled HSM-A USB
   jack** on the Proxmox host. The labeled-jack discipline is what makes
   "swap token A for token B" work without re-running deploy.sh — see
   [Operations: swap HSM tokens](#swap-hsm-tokens).

3. **`pcscd` is NOT running on the Proxmox host itself.** USB passthrough
   does not unbind the host's driver the way `vfio-pci` does, so a
   running host-side `pcscd` would hold the device open and starve the
   guest. `deploy.sh` warns (does not hard-fail) if it detects this.
   Disable with:
   ```
   ssh root@<proxmox-host> 'systemctl disable --now pcscd'
   ```

4. **Snippets content type enabled on the snippets storage.**
   Datacenter → Storage → `local` (or whichever you use) → Edit →
   under **Content**, check **Snippets**. `deploy.sh` verifies this
   automatically and prints the exact `pvesm set` command to fix it
   if the storage doesn't allow `snippets` — so a forgotten checkbox
   after a node rebuild fails fast with the cure in the error message,
   not silently with a no-network VM.

5. **SSH access from this Mac to the Proxmox node** as a user that can
   run `qm`, `pvesh`, and `lsusb` (typically `root`). Test with:
   ```
   ssh root@<proxmox-host> 'qm list | head'
   ```

6. **Target VM ID is free.** `deploy.sh` is fail-fast — it will refuse to
   touch an existing VM (this is doubly important for OpenBao because an
   existing VM may hold initialized seal-key references). Default ID is
   `130`; change in `.env` if it collides.

## Configuration

```
cp .env.example .env
# edit .env: set PROXMOX_HOST, SSH_PUBLIC_KEY, HSM_USB_HOST_PORT, confirm VM_ID
```

`.env` is gitignored.

### Find the HSM's bus-port on the Proxmox host

`HSM_USB_HOST_PORT` pins the passthrough to a physical USB jack via
`<bus>-<port>`.

**Recommended path — use the helper:**

```
./discover-hsm.sh
```

It SSHes to `PROXMOX_HOST` (read from `.env`), enumerates CCID
smart-card devices via `/sys/bus/usb/devices/`, and prints the exact
`HSM_USB_HOST_PORT` and `HSM_USB_USB3` lines to paste into `.env`. If
multiple readers are plugged in, it lists all of them so you can pick
the one at the labeled HSM-A jack. Read-only — never modifies any
file.

**Manual path (fallback / when something looks weird):**

With token A plugged in:

```
ssh root@<proxmox-host> 'lsusb -t'
```

Sample output (CardLogix HSM at bus 1, port 2):

```
/:  Bus 02.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/4p, 5000M
/:  Bus 01.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/8p, 480M
    |__ Port 2: Dev 4, If 0, Class=Chip/SmartCard, Driver=usbfs, 12M
```

The matching value is `HSM_USB_HOST_PORT="1-2"` (Bus 01, Port 2,
no leading zeros). For a port behind an internal hub, the form is
`<bus>-<hub_port>.<device_port>` — e.g. `3-1.4`.

### Decide whether to set HSM_USB_USB3

In the `lsusb -t` output above, the bus the HSM sits on shows `480M`
(USB 2.0, EHCI). Leave `HSM_USB_USB3="0"` — that's the default Proxmox
USB controller and will work.

If your HSM is on a `5000M` bus (USB 3, xHCI), set `HSM_USB_USB3="1"`
in `.env`. Without it, the VM's default EHCI controller can silently
fail to enumerate USB 3 devices. CCID smart-card readers are slow
devices, so the easier alternative is "plug into a USB 2 jack on the
host" — `HSM_USB_USB3` is for cases where no USB 2 jack is available.

### sc-hsm-embedded build (BUILD_SC_HSM_EMBEDDED)

Default `1`. Builds CardContact's `sc-hsm-embedded` PKCS#11 module from
GitHub during cloud-init, installing
`/usr/local/lib/libsc-hsm-pkcs11.so`. The auto-unseal procedure prefers
this module over OpenSC's `opensc-pkcs11.so` because it exposes
SmartCard-HSM-specific features.

Set to `0` to skip the build. The provisioner falls back to
`/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so` (which OpenSC ships as
part of `opensc-pkcs11`), and validation works against either.

## Deploy

```
./deploy.sh
```

Runs from your Mac, SSHes to the Proxmox node, and:

1. Verifies template `9100` exists, target `VM_ID` does not, and a
   CCID smart-card device is present on the host.
2. Soft-warns if host-side `pcscd` is running.
3. Resolves the snippets path on the node via `pvesh`.
4. Renders `cloud-init/user-data.yaml` with values from `.env`.
5. Uploads the rendered snippet to `<storage_path>/snippets/`.
6. `qm clone` (full) → `qm set` (cores/memory/balloon/machine) →
   `qm set --usb0 host=<bus>-<port>` → `qm resize scsi0` →
   `qm set --cicustom + --ipconfig0 ip=dhcp` → `qm start`.

The first boot installs the smartcard stack + OpenBao and reboots
automatically (so udev rules apply via clean USB re-enumeration).
Watch progress on the serial console (`qm terminal <id>` on the node)
or, once the VM has an IP, tail `/var/log/openbao-provision.log`.

## Post-deploy validation

This is the gate for proceeding to Phase 4. **All three steps must
pass.** If any fails, fix it before continuing — re-running the
provisioner is cheap (`sudo bash /usr/local/sbin/openbao-provision.sh`),
and re-deploying from scratch only takes a few minutes.

### 1. lsusb — HSM enumerates inside the guest

```
ssh bao-admin@<vm-ip> lsusb
```

**Success:** at least one line containing `CardContact`,
`SCM Microsystems`, `Identiv`, `CardLogix`, or `SmartCard-HSM`.
Typical:

```
Bus 001 Device 002: ID 04e6:5816 SCM Microsystems, Inc. SmartCard-HSM
```

**Failure modes:**

- *No smart-card device shown.* Most common cause: USB controller
  mismatch. Check `lsusb -t` on the host (`ssh root@<host> 'lsusb -t'`)
  for the bus speed at `HSM_USB_HOST_PORT`. If `5000M` (USB 3), set
  `HSM_USB_USB3="1"` in `.env` and re-deploy. If `480M` (USB 2), check
  `qm config <vmid> | grep usb` on the host shows your `host=<bus>-<port>`
  line; check `dmesg | tail` inside the guest for `usb_submit_urb`
  errors.
- *Wrong device shown.* Token B (or another smart-card reader) is
  plugged into HSM-A jack. Pull, re-seat token A, `qm reboot <vmid>` on
  the host.
- *Empty `lsusb` output.* qemu-guest-agent or USB subsystem failed to
  initialize in the guest — check `qm terminal <vmid>` for boot errors.

### 2. pcscd + pcsc_scan — daemon sees the token

```
ssh bao-admin@<vm-ip>
sudo systemctl status pcscd     # active (running)
pcsc_scan -n                    # one-shot scan; -n disables the loop
```

**Success:** output ends with a `Card state:` block describing the
token. The most useful diagnostic line is the ATR (Answer To Reset);
for the SmartCard-HSM 4K it begins `3B FE 18 00 00 81 31 FE 45 80 31
81 54 48 53 4D` and the ASCII tail `48 53 4D` decodes to "HSM".

**Failure modes:**

- *`pcsc_scan` loops forever showing "Waiting for the first reader..."*
  Most common: pcscd isn't seeing the device. Check
  `journalctl -u pcscd -n 50` for `/dev/bus/usb` permission errors. If
  the host-side pcscd is also running (deploy.sh's soft warning),
  disable it on the host now.
- *`pcscd` is `inactive`.* Run `sudo systemctl start pcscd && systemctl
  status pcscd`. If start fails, check `journalctl -u pcscd -n 100`.
- *`pcsc_scan` shows the reader but "no card present".* The reader is
  visible but the smart-card chip inside isn't responding. Re-seat the
  token in the HSM-A jack (gently — the contacts can lose seat over
  time).

### 3. PKCS#11 — pkcs11-tool sees the slot

```
PKCS11_MOD=/usr/local/lib/libsc-hsm-pkcs11.so
[ -f "$PKCS11_MOD" ] || PKCS11_MOD=/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so

pkcs11-tool --module=$PKCS11_MOD --list-slots
pkcs11-tool --module=$PKCS11_MOD --list-token-slots
```

**Success:** at least one slot, with a token label ending in
`(UserPIN)` (typically `SmartCard-HSM (UserPIN)` or
`homelab-vault-seal-A (UserPIN)` if you set the label during the DKEK
ceremony).

**Failure modes:**

- *"No slots" or `CKR_DEVICE_ERROR` from `C_GetSlotList`.* Almost
  always polkit rejecting the SSH-session client. Confirm with:

  ```bash
  sudo journalctl -u pcscd | grep IsClientAuthorized
  ```

  If you see `Process N (user: 1001) is NOT authorized for action:
  access_pcsc`, the polkit rule at
  `/etc/polkit-1/rules.d/49-pcscd-plugdev.rules` is missing or the
  user is not in the `plugdev` group. Cloud-init lays down both at
  first boot; on a stale VM (or after manual edits), drop the rule
  by hand using the contents from
  [cloud-init/user-data.yaml](cloud-init/user-data.yaml)'s
  `write_files` and run
  `sudo systemctl restart polkit pcscd`. Sanity check: running
  `pkcs11-tool` with `sudo` works regardless of polkit and isolates
  whether anything else is broken.
- *"module load failed" on `libsc-hsm-pkcs11.so`.* The build was
  attempted but produced a broken module. Check the
  `/var/log/openbao-provision.log` build output. As an immediate
  workaround, fall back to `opensc-pkcs11.so` (which is always
  present); to fix sc-hsm-embedded properly, log into the VM and
  re-build manually with verbose output.
- *Slots listed but no token in any slot.* Same as pcsc_scan
  "no card present" — re-seat the token.

## Continuing to Phase 4

Once all three validation steps pass on this VM with token A in HSM-A:

1. Generate the AES wrap and HMAC keys on token A using `pkcs11-tool
   --keypairgen` per the ceremony doc's Phase 4. Record the key labels.
2. Write `/etc/openbao/openbao.hcl` with the `seal "pkcs11" {}` stanza
   per Phase 5.1, pointing at the key labels and the PKCS#11 module
   path that worked in step 3 above.
3. Set the User PIN as an env var via `/etc/openbao/openbao.env`
   (the auto-unseal doc shows the systemd drop-in pattern); never
   hardcode the PIN in `openbao.hcl`.
4. `systemctl restart openbao`, then `bao operator init` and unseal
   verification.

The full procedure (with PINs, key labels, recovery notes, and Phase 6
backup verification against token B) lives in the ceremony doc. **Do
not paste any of that material into files in this repo** — it's a
public GitHub repo.

## Sizing

Default in `.env.example`:

| Resource | Value | Why |
|---|---|---|
| vCPU | 2 | OpenBao with PKCS#11 seal is light — a few goroutines, KV store, audit log |
| RAM | 2 GiB | Comfortable; bump if you add transit/PKI engines or run an HA pair |
| Disk | 32 GiB | Tiny data dir; the size is for /var/log growth + audit-log retention |
| Balloon | 0 | No PCIe passthrough constraint, but disabling balloon is the conservative default for a service that mlocks |
| Machine | q35 | Modern default; matches the rest of the homelab |
| CPU type | (default) | OpenBao does not need `host` — no AVX-path dependency |

Resize-able later via `qm` on the node — see [Operations](#operations).

## Ports

| Port | Protocol | Source | Purpose |
|---|---|---|---|
| 22 | tcp | LAN | SSH (allowed by base template) |
| 8200 | tcp | LAN | OpenBao API |
| 8201 | tcp | — | OpenBao cluster port — **intentionally closed**; opens when (if) you run an HA pair |

UFW is set inside the VM. Perimeter firewall (router) is what gates
external access — keep this VM LAN-only unless you front it with
client-cert auth or mTLS at a reverse proxy.

## Operations

### Find the VM's IP

DHCP lease, so the IP can change. Three ways to look it up:

**1. qm guest cmd from your Mac (works as long as qemu-guest-agent is running in the VM):**

```bash
ssh root@<proxmox-host> 'qm guest cmd 130 network-get-interfaces' \
  | grep -E '"ip-address" *: *"[0-9]+\.' \
  | grep -v '"127\.0\.0\.1"'
```

If `jq` is installed locally, this is cleaner:

```bash
ssh root@<proxmox-host> 'qm guest cmd 130 network-get-interfaces' \
  | jq -r '.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"'
```

**2. Proxmox Web UI:** open `https://<proxmox-host>:8006`, select VM
`130` → Summary tab.

**3. Router / DHCP server lease table:** look for hostname `openbao`.
Useful as a fallback if qemu-guest-agent is broken or the VM hasn't
booted far enough yet.

For a service like OpenBao, set a DHCP reservation on your router for
the VM's MAC address (visible via `ssh root@<proxmox-host> 'qm config
130 | grep ^net0'`) so you have a stable address for `bao` CLI use and
seal-stanza references.

### Resize a running VM

`deploy.sh` will refuse to touch an existing VM. To change sizing on
the running deployment, ssh to the node:

```
qm set 130 --memory 4096 --cores 4
qm resize 130 scsi0 +20G
```

Memory and disk grow live; cores require a reboot to take effect.

### Re-run the provisioner

The cloud-init snippet runs once per `instance-id`. To re-run on next
boot:

```
ssh bao-admin@<vm-ip> 'sudo cloud-init clean'
ssh root@<proxmox-host> 'qm reboot 130'
```

To just re-run the smartcard + OpenBao install (without touching
cloud-init's user/ufw setup), the provision script is idempotent:

```
ssh bao-admin@<vm-ip> 'sudo bash /usr/local/sbin/openbao-provision.sh'
```

### Swap HSM tokens

The whole point of pinning the passthrough by `host=<bus>-<port>`: you
swap which token the VM sees by physically moving cards in the host's
HSM-A jack. No Proxmox reconfig, no reboot.

Use case: quarterly DR drill (per the ceremony doc's Phase 8) — pull
token A, plug token B, re-test that OpenBao unseals against B.

```
# 1. Stop OpenBao to release the HSM cleanly
ssh bao-admin@<vm-ip> 'sudo systemctl stop openbao'

# 2. Physically swap tokens at the HSM-A jack on the host

# 3. Restart pcscd in the guest so it sees the new card's ATR
ssh bao-admin@<vm-ip> 'sudo systemctl restart pcscd'

# 4. Verify with pcsc_scan + pkcs11-tool (steps 2 + 3 above)

# 5. Restart OpenBao (which will now unseal via the swapped token)
ssh bao-admin@<vm-ip> 'sudo systemctl start openbao'
```

### Re-attach an HSM that vanished

If the host rebooted without the guest, or the USB device dropped off
the bus mid-session, the passthrough config can desync. Re-stamp it:

```
ssh root@<proxmox-host>
qm set 130 --delete usb0
qm set 130 --usb0 host=<bus>-<port>     # use the same value as .env
qm reboot 130
```

If `qm set --usb0` fails with "no such device" but the device does
appear in `lsusb -t`, the bus-port may have shifted (host firmware
re-enumerated or you swapped Thunderbolt accessories). Re-discover
with `lsusb -t` and update `.env` + the live config to match.

### Update the cloud-init snippet on the node

If you edit `cloud-init/user-data.yaml`, the change does NOT propagate
to the running VM automatically. Either re-deploy from scratch or
manually edit the file on the Proxmox node:

```
ssh root@<proxmox-host>
vi /var/lib/vz/snippets/vm-130-openbao-user.yaml
qm reboot 130   # only if you want it to take effect now
```

### Destroy and rebuild

> **WARNING.** Destroying this VM means losing OpenBao's storage state.
> If you've completed Phase 5 of the ceremony (initialized the vault
> and unsealed against token A), the destroy + rebuild loses any
> secrets, policies, and the seal-key references already wrapped to the
> HSM. You'd be re-running Phase 4 and Phase 5 from scratch. The HSM's
> on-token keys survive the VM destroy (they live on the chip, not in
> the VM), but OpenBao's storage layer that references them does not.

```
ssh root@<proxmox-host> 'qm stop 130 && qm destroy 130'
./deploy.sh
```

## Files

- `.env.example` — committed; documents required vars
- `.env` — gitignored; your real values
- `discover-hsm.sh` — read-only USB discovery helper; prints `HSM_USB_*` values to paste into `.env`
- `deploy.sh` — clone + size + USB attach + start
- `cloud-init/user-data.yaml` — first-boot config (rendered before upload)
