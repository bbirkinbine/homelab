# TODO

Deferred work — things that need to happen but aren't blocking the
current commit. Keep this list short and surgical. ADRs cover
load-bearing decisions; this file is for "obvious work I don't want
to forget."

Convention: each item is a one-line summary + a short rationale + a
trigger that makes it urgent. Strike through (`~~done~~`) or delete
once landed.

## Open

### Cloud-init datasource bug — every role deploy currently fails to bring up the network (BLOCKING)

**Symptom:** VMs cloned from the Ubuntu 24.04 base template (per ADR-0006)
pick `Datasource DataSourceNone` instead of NoCloud, even though the
Proxmox cloud-init CD is present, correctly labeled `cidata`, mounted
at `/dev/sr0`, and contains valid `user-data` + `meta-data` + `network-config`.
Result: no netplan written → `enp6s18` reported by networkd as
`State: off (unmanaged)` → no DHCP → no IP → `tofu apply` times out
waiting for the QEMU agent to publish interface info. First observed
during the amp-game port on 2026-05-15.

**Diagnostic data captured during the 2026-05-15 session:**

- `qm config 110` shows only `ide2: local-lvm:vm-110-cloudinit,media=cdrom`
  (no stale `ide0` drive — the bpg/proxmox `initialization {}` block IS
  attaching cloud-init at `ide2` cleanly).
- `qm guest exec 110 -- ls /dev/disk/by-label/` shows `cidata -> ../../sr0`.
- Mounted `/dev/sr0` contains: `user-data` (1427 bytes — matches the
  snippet uploaded by tofu), `meta-data` (54 bytes — valid `instance-id`),
  `network-config` (265 bytes), `vendor-data` (0 bytes).
- `cloud-init status` reports `error - done`, `last_update: 1970-01-01`.
- `/run/cloud-init/result.json` shows `"datasource": null` and
  `errors: [ssh_authkey_fingerprints / KeyError("getpwnam(): name not found: 'ubuntu'")]`.
- **`/var/log/cloud-init.log` only contains `modules:config` and `modules:final` stages** —
  no `init-local` or `init` stage logging at all. Same for
  `/var/log/cloud-init-output.log`. This is the strongest unexplored
  clue: if `cloud-init-local.service` isn't actually running, NoCloud
  detection never happens.

**What was tried (and didn't work):**

- 2026-05-15: speculated this was [CVE-2024-6174](https://github.com/canonical/cloud-init/security/advisories/GHSA-83c5-cwjr-pvm9)
  enforcement and proposed adding `datasource: NoCloud: fs_label: cidata`
  to [`30-cloud-init-config.sh`](packer/ubuntu-24-04-base/provision/30-cloud-init-config.sh).
  Reverted — `fs_label` is not a documented cloud-init NoCloud config key
  and would have been silently ignored. The CVE-2024-6174 diagnosis was
  also unverified.

**Where to look next (fresh session):**

1. `systemctl status cloud-init-local.service` inside the VM — is the
   unit even running? If failed/inactive, that's the root cause.
2. `journalctl -u cloud-init-local.service --no-pager` — what does the
   init-local stage actually log? It may be writing to journal, not
   `/var/log/cloud-init.log`.
3. `journalctl -b -p err` — any boot-time errors that would prevent
   cloud-init-local from running.
4. `cloud-init init --local` run manually — does it succeed when invoked
   directly? Useful for isolating from the systemd-unit question.
5. If init-local IS running but rejecting NoCloud, then check the actually-
   documented post-CVE-2024-6174 opt-in mechanisms: kernel cmdline
   `ds=nocloud`, smbios system-serial-number `ds=nocloud`, or a
   `meta-data` file containing `dsmode: net` / `seedfrom:`.
6. Compare against a known-working cloud-init + Proxmox setup (e.g.
   [proxmox-community-scripts](https://tteck.github.io/Proxmox/) or
   the [bpg/proxmox provider's own integration test fixtures](https://github.com/bpg/terraform-provider-proxmox))
   to see what they configure differently.

**Trigger:** blocks every OpenTofu + Ansible role deploy (amp-game,
openbao, rootca). Pick up next session with the `systemctl status` +
`journalctl` checks above before guessing at fixes.

### Boot-time `systemd-networkd-wait-online` stall (~2 min per boot)

VMs cloned from the Ubuntu 24.04 base sit at
`[ *** ] Job systemd-networkd-wait-online.se...tart running (1min 21s / no limit)`
on first boot. Ubuntu 24.04 ships the unit with **no timeout** by
default, so when an interface fails to come online (currently a
consequence of the cloud-init bug above — networkd has no `.network`
config for `enp6s18`), boot stalls indefinitely. The `bpg/proxmox`
provider's QEMU-agent wait then races against its own timeout.

**Fix (to land alongside or after the cloud-init investigation):**
drop a systemd unit override in
[`packer/ubuntu-24-04-base/provision/30-cloud-init-config.sh`](packer/ubuntu-24-04-base/provision/30-cloud-init-config.sh):

```ini
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --any --timeout=30
```

`--any` means "any interface online" (right for single-NIC VMs);
`--timeout=30` caps the wait so boot can never hang longer than 30s.

Was attempted in the 2026-05-15 session but reverted unverified
because the template wasn't successfully rebuilt with the change.
Lift this back in on the next Packer base touch and test against a
clean clone.

### Module output `mac` returns loopback `00:00:00:00:00:00`

The shared module's
[`outputs.tf`](modules/proxmox-vm/outputs.tf) (or wherever
`mac_addresses[0]` is being indexed) returns the first MAC the agent
reports — which is always `lo` (the loopback interface, MAC
`00:00:00:00:00:00`). Should filter out loopback before picking the
first. Caught in the 2026-05-15 amp-game apply: `mac = "00:00:00:00:00:00"`
in tofu output, which is useless for pinning a DHCP reservation.

**Fix:** in
[`modules/proxmox-vm/main.tf`](modules/proxmox-vm/main.tf)/`outputs.tf`,
use `try(...)` + a filter expression on `network_interface_names` or
similar to skip `lo` and return the first ethernet MAC.

**Trigger:** low priority — only matters when you want to pin a DHCP
reservation by MAC from tofu output. Workaround: `qm config 110 | grep ^net0`
on the Proxmox host gets the real MAC.

## Done

(none yet)
