# TODO

Deferred work — things that need to happen but aren't blocking the
current commit. Keep this list short and surgical. ADRs cover
load-bearing decisions; this file is for "obvious work I don't want
to forget."

Convention: each item is a one-line summary + a short rationale + a
trigger that makes it urgent. Strike through (`~~done~~`) or delete
once landed.

## Open

### Rebuild Ubuntu 24.04 base template to activate apt-lists retention

`packer/ubuntu-24-04-base/provision/99-cleanup.sh` was updated to stop
wiping `/var/lib/apt/lists/*` so cloned VMs carry the build-time
package index — required to make `ansible-playbook --check`
(`just ansible-check <role>`) work against freshly-cloned VMs without
a prior manual `apt update`. The script change is committed; the
behavior only manifests after a `build-pve.sh` rebuild of the Ubuntu
base.

Trigger that makes it urgent: any operator workflow that depends on
`just ansible-check <role>` succeeding on first bring-up. Currently
sidestepped by running `just ansible <role>` (real apply) directly,
which fires `update_cache: true` and populates lists/ from scratch.

Steps (from the Mac, per `packer/ubuntu-24-04-base/README.md` and
ADR-0006 per-node template VMID conventions):

1. `cd packer/ubuntu-24-04-base/`
2. Rebuild on each node — templates are per-node with distinct VMIDs
   (`9100` on pve12t, `9101` on pve13m, `9102` on pve13t):
   - `./build-pve.sh pve12t`
   - `./build-pve.sh pve13m`
   - `./build-pve.sh pve13t`
3. Existing VMs (openbao, monitoring, etc.) are unaffected — they
   already cloned from the prior template. Only new role deploys
   pick up the updated base.

## Done

### ~~Module output `mac` returns loopback `00:00:00:00:00:00`~~

Was indexing `mac_addresses[0]` which is always `lo`. Fixed by
mirroring the existing `ipv4` output pattern — `mac_addresses[1]`
under a `try(...)` (the bpg/proxmox provider's `mac_addresses` is
ordered the same as the agent's interface list: index 0 = `lo`,
index 1 = first real ethernet).

### ~~Cloud-init datasource bug — every role deploy failed to bring up the network~~

Root cause (verified 2026-05-15 against a fresh amp-game clone from
the rebuilt template 9102): our own `packer-cleanup.service` was
creating a systemd ordering cycle that systemd resolved by deleting
`cloud-init-local.service` from the boot graph. The unit had
`Before=cloud-init-local.service` AND `WantedBy=multi-user.target`
without `DefaultDependencies=no`, so the auto-added
`After=basic.target` closed a loop back through sysinit. Diagnostic
on a pre-fix clone:

```text
sysinit.target: Found ordering cycle on cloud-init-local.service/start
sysinit.target: Found dependency on packer-cleanup.service/start
sysinit.target: Found dependency on basic.target/start
sysinit.target: Job cloud-init-local.service/start deleted to break ordering cycle
```

The earlier-observed "reboot fix" worked because `packer-cleanup`
self-destructs after running, so the second boot has no cycle.

Fixed in commit `cfea90f`:
`packer/ubuntu-24-04-base/provision/99-cleanup.sh` — added
`DefaultDependencies=no` + `Conflicts=shutdown.target`, switched
`WantedBy=multi-user.target` to `WantedBy=sysinit.target`.

Wrong hypotheses that were tried and rejected during diagnosis (all
moot in retrospect, see git history for context):
CVE-2024-6174 enforcement, dropping bpg's `ip_config {}` to remove
`network-config` from cidata, switching the cloud-init drive
`interface` from `ide2` to `scsi3`, udev/cidata-label race.

### ~~Boot-time `systemd-networkd-wait-online` stall (~2 min per boot)~~

Same commit (`cfea90f`):
`packer/ubuntu-24-04-base/provision/30-cloud-init-config.sh` now
installs a drop-in for `systemd-networkd-wait-online.service` with
`ExecStart=/lib/systemd/systemd-networkd-wait-online --any --timeout=30`.
Boot can no longer block longer than 30s on this unit. Verified
on the same amp-game clone (boot completed in well under 30s; the
override is in `/etc/systemd/system/systemd-networkd-wait-online.service.d/timeout.conf`).
