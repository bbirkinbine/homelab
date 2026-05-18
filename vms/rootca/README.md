# vms/rootca

Offline Root CA on Ubuntu 24.04, backed by a CardLogix SmartCard-HSM
4K (token labeled `homelab-rootca-A`). USB-passthrough'd from the
labeled HSM-A jack on pve12t. **Air-gapped after one-shot Ansible
bootstrap** — no NIC, no automatic-anything, accessed only via the
Proxmox noVNC console once operational.

This is **Anchor #1** in the trust hierarchy (Root CA → Intermediate
in OpenBao → leaf certs). The OpenBao side is at
[`vms/openbao/`](../openbao/README.md); the vault doc that wires the
two together is `13 Homelab Blueprint.md` in the Obsidian vault.

## Layout

```text
vms/rootca/
├── README.md           this file
├── terraform/          provisioning shape (clone, size, USB, NIC toggle)
├── ansible/            bootstrap-time toolchain install (one-shot)
└── cloud-init/         identity-only first-boot (hostname, user, plugdev)
```

## Prerequisites

1. **Workstation tooling** — `brew install opentofu just keepassxc ansible`
   (same as openbao; see [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md)).
2. **DKEK ceremony complete.** Both CardLogix tokens initialized as
   `homelab-rootca-A` (HSM-A) / `homelab-rootca-B` (HSM-B) per the
   vault's `CardLogix DKEK Ceremony — Homelab Single-Share.md`. KCV
   should be `70406861715AF81F` (recorded in KeePassXC under
   `homelab-dkek-kcv`). HSM-A is the active token; HSM-B lives in the
   fire safe.
3. **HSM-A physically plugged into the labeled HSM-A jack on pve12t.**
   Bus-port `1-2` (preserved from the legacy openbao USB passthrough
   testing — see [`legacy/discover-hsm.sh`](../openbao/legacy/discover-hsm.sh)
   in the openbao role's legacy folder if you need to re-verify).
4. **No host-side encrypted storage required.** This role's disk lives
   on the standard `local-lvm` pool (or whatever the module default is
   on pve12t). Encryption is handled *inside the guest*: the Ansible
   role carves a LUKS-formatted partition on the VM's disk and mounts
   it at `/var/lib/rootca-encrypted` where all ceremony artifacts live.
   Host root sees only the encrypted block range for that partition;
   the OS install itself is cleartext (the rest of the disk is the
   standard Packer 9100 base). This is a 2026-05-11 architecture
   change from the prior host-side LUKS Directory pool; the threat
   model moves the encryption boundary into the VM so that a host-root
   attacker on pve12t cannot reach the cleartext Root CA key material
   without also compromising the running guest.
5. **`tofu@pve` API token** (same one as openbao — `Homelab/Tofu/proxmox-api-token`
   in KeePassXC). See [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md).
6. **SSH access to pve12t + key loaded into `ssh-agent`.**
   `ssh-copy-id root@pve12t`, then `ssh-add ~/.ssh/id_ed25519` once
   per shell session. The `bpg/proxmox` provider uploads cloud-init
   snippets over SSH (not the HTTP API) and shells out non-
   interactively, so the key must already be in the agent before
   `tofu apply`. Preflight verifies both. See
   [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) section
   **(d) Load the private key into `ssh-agent`** for the macOS
   Keychain auto-load pattern that survives reboot.
7. **Host-side `pcscd` is NOT running on pve12t.** USB passthrough
   does not unbind the host driver the way `vfio-pci` does; a running
   host-side pcscd would hold the device open and starve the guest:

   ```bash
   ssh root@pve12t 'systemctl disable --now pcscd 2>/dev/null || true'
   ```

## Deploy

This role has a **two-phase lifecycle** that's not present in openbao:

```text
Phase A: Bootstrap (network attached)
  1. just hydrate rootca           # render terraform.tfvars
  2. just apply rootca             # creates VM with NIC, USB passthrough'd,
                                   # disk on standard local-lvm (no host-side
                                   # encryption — see prereq 4).
  3. just inventory rootca         # writes ansible/inventory.yml from tofu output
                                   # (waits on qemu-guest-agent — retry if "not reported")
  4. just ansible-deps rootca      # one-time per workstation
  5. just ansible rootca           # installs smartcard stack, sc-hsm-embedded,
                                   # polkit + udev + plugdev plumbing, carves
                                   # + LUKS-formats /var/lib/rootca-encrypted
                                   # (operator pastes the passphrase from
                                   # KeePassXC → Homelab/RootCA/luks-passphrase
                                   # when prompted), locks the VM down for
                                   # air-gap. Idempotent on re-runs.

  ── Verification gate (do this before Phase B) ──
  6. ssh rootca-admin@<vm-ip>
     # Confirm the in-VM LUKS partition is present and mounted:
     lsblk -o NAME,FSTYPE,MOUNTPOINT | grep rootca-encrypted
     mountpoint /var/lib/rootca-encrypted
     # Confirm the HSM enumerates:
     pkcs11-tool --module $PKCS11_MODULE --list-slots
     # Must show a slot with token label `homelab-rootca-A (UserPIN)`.
     # If you also want to verify the on-card state, log in:
     sc-hsm-tool
     # Should show: DKEK shares=1, DKEK key check value=0x70406861715AF81F

Phase B: Make air-gap permanent
  7. $EDITOR vms/rootca/terraform/terraform.tfvars
     # change: enable_network = false
  8. just apply rootca             # NIC removed declaratively
  9. just output rootca            # → "network REMOVED — VM is AIR-GAPPED"

Phase C: Ceremonies (forever after)
  All future access is via Proxmox noVNC console only. The
  CardLogix as Offline Root CA.md vault doc Phases 2-4 happen here:
    * Phase 2 — Generate the Root CA key on HSM-A
    * Phase 3 — Wrap to HSM-B (DKEK backup)
    * Phase 4 — Sign the Intermediate CSR (annually or on rotation)
```

## How the air-gap is enforced

Two complementary mechanisms:

1. **No NIC.** After Phase B, the VM has no network adapter at all.
   This is the strong guarantee — no kernel network stack to be
   exploited, no DHCP request to leak the MAC, no DNS leaks, no
   chance of accidental egress.
2. **Ceremony artifacts encrypted at rest, inside the VM.** The
   ceremony directory (`/var/lib/rootca-encrypted`) lives on a LUKS
   partition that is `noauto` in `/etc/crypttab` + `/etc/fstab`. On
   every VM boot it stays locked until the operator opens the noVNC
   console, runs `rootca-unlock`, and types the passphrase. The OS
   install on the rest of the disk is cleartext (standard Packer 9100
   base) — but the cert material, the private parts of any in-flight
   ceremony, the audit logs of past ceremonies, and any DKEK-wrap
   blobs only exist in cleartext while the partition is unlocked.

The two combine multiplicatively: while the partition is locked the
ceremony state is opaque even to root inside the guest; while it's
unlocked, there's no network egress path. The threat being defended
against is: a sustained attacker with root on pve12t cannot extract
the Root CA key material without (a) the in-VM LUKS passphrase AND
(b) HSM-A physically plugged in AND (c) the HSM User PIN. The 2026-05-11
move from host-side LUKS to in-VM LUKS strengthens (a) — under the
prior model, host root on pve12t could read the cleartext partition
while it was unlocked for a ceremony; under the new model, host root
sees only the encrypted block range and would additionally need to
compromise the running guest to reach the cleartext.

## Ceremony procedure (boots the VM for a Root CA operation)

Every ceremony is the same shape — only the operation in the middle
changes (Phase 2 keygen, Phase 3 DKEK wrap, Phase 4 Intermediate sign,
Phase 6 DR drill against HSM-B).

No host-side unlock step — everything happens inside the VM via noVNC.

```bash
# 1. Retrieve the LUKS passphrase from KeePassXC.
#    Entry: Homelab/RootCA/luks-passphrase

# 2. Confirm HSM-A is in the labeled jack (bus-port 1-2) on pve12t.
ssh root@pve12t 'lsusb -t | grep -A1 "Class=0[0b]b"'

# 3. Start the Root CA VM via the Proxmox UI or qm.
ssh root@pve12t 'qm start 110'

# 4. Open the noVNC console for VM 110. Log in as rootca-admin.
#    The /var/lib/rootca-encrypted partition is LOCKED at boot
#    (noauto in /etc/crypttab + /etc/fstab). Unlock it now:
#
#      sudo rootca-unlock           # prompts for the LUKS passphrase
#                                   # → luksOpen + mount + verify
#
#    Then follow the relevant phase of
#    `CardLogix as Offline Root CA.md` in the vault.

# 5. When done, lock the partition again from inside the VM:
#
#      sudo rootca-lock             # umount + luksClose + verify

# 6. Shut the VM down cleanly from the noVNC console (or qm shutdown).
ssh root@pve12t 'qm shutdown 110'

# 7. Update the ceremony log in KeePassXC.
```

The whole loop takes 2-3 minutes of setup/teardown around however long
the actual ceremony takes (Phase 2 keygen is ~3 minutes; Phase 4
Intermediate signing is ~1 minute). Faster than the old host-side
LUKS flow because there's no `cryptsetup luksOpen` + `pvesm set` dance
on the hypervisor.

## Re-bootstrapping (rare — only when toolchain needs updating)

If you need to pull a new sc-hsm-embedded release, patch a CVE in
openssl, or otherwise update the toolchain:

```bash
# 1. In vms/rootca/terraform/terraform.tfvars:
   enable_network = true                # back to bootstrap mode

# 2. Re-attach NIC.
just apply rootca                       # NIC re-attached

# 3. Boot the VM via Proxmox UI / qm start 110. Open noVNC.
#    From inside the VM, unlock the ceremony partition (the toolchain
#    update may need to write into it):
#      sudo rootca-unlock                # paste LUKS passphrase
# 4. SSH in, verify reachability.
# 5. just ansible rootca                 # idempotent re-bootstrap
#    (preview first: just ansible-check rootca   # --check --diff)
# 6. Verify (pkcs11-tool --list-slots + lsblk | grep rootca-encrypted).
# 7. In the VM: sudo rootca-lock         # close + umount the partition
# 8. In terraform.tfvars: enable_network = false
# 9. just apply rootca                   # NIC removed again
```

The re-bootstrap window is small and high-risk — only do it when you
have a specific reason. The default operational posture is "never
touch this VM."

## Why no `bao operator init`-equivalent automation

The Root CA's first-init flow (Phase 2 in the vault doc) generates the
Root CA keypair on HSM-A, self-signs the Root cert, and DKEK-wraps the
key to HSM-B. Every one of those operations:

- Touches the HSM User PIN (must be typed manually, not stored on disk).
- Produces high-value artifacts (root-ca.pem, the .wrapped blob,
  fingerprints recorded in KeePassXC) that need operator inspection
  before they leave the VM via single-purpose USB.
- Is one-shot — re-running by accident wipes the on-card key and
  starts over from scratch.

Automating this would mean either embedding the PIN in code (terrible)
or running half the ceremony interactively over an SSH-or-noVNC bridge
(error-prone). The vault doc is explicit: this is an operator ceremony
with a written procedure and a paper log. Ansible's job ends at "the
toolchain is installed and the HSM enumerates."

## Destroy and rebuild

> **WARNING.** Destroying this VM means losing whatever ceremony
> artifacts live in `/root/secure-removable` (which should be empty
> outside an active ceremony — operator shreds them before each
> ceremony ends). It does NOT touch the on-card keys; HSM-A and
> HSM-B both retain whatever is wrapped on them.
>
> If the Root CA key has already been generated on HSM-A and
> DKEK-wrapped to HSM-B (vault doc Phase 3 complete), a clean
> rebuild looks like:
>
> 1. `just destroy rootca` — removes the VM.
> 2. Re-run Phase A bootstrap + Phase B air-gap.
> 3. At the noVNC console: skip Phase 2 (key already exists on HSM-A);
>    optionally re-run Phase 4 to sign a fresh Intermediate.
>
> If you ALSO lost the Root cert (`root-ca.pem`), it can be regenerated
> from the existing HSM-A key with `openssl req` — the key is intact,
> only the self-signed cert needs re-issuance. The fingerprint will
> differ; every host that trusts the Root CA needs the new cert
> redistributed.

```bash
just destroy rootca
# then full Phase A + B + ceremony to rebuild
```

## Sizing

| Resource | Value | Why |
| --- | --- | --- |
| vCPU | 2 | HSM is the bottleneck, not the CPU |
| RAM | 4 GiB | openssl + pkcs11-provider during ceremonies; comfortable |
| Disk | 40 GiB | Standard 9100 base wants ~8 GiB; the rest carries `/var/lib/rootca-encrypted` (LUKS partition for ceremony artifacts). Bumped from 32 GiB on 2026-05-11 with the host-side → in-VM LUKS move so the encrypted partition has somewhere to live |
| Balloon | 0 | mlock-style memory hygiene; nothing else needs the RAM anyway |
| Machine | q35 | Matches the rest of the homelab |
| CPU type | x86-64-v3 | Module default; AES-NI via the Intel ISA bit. Portable across NUC12/13 even though USB passthrough still pins this VM to pve12t |
| `started` | false | Manual start only — ceremonies trigger boot |
| `on_boot` | false | Host boot must not auto-start a VM that holds an HSM-bound CA. Operator decides when to power it up |

## Ports (during bootstrap window only)

| Port | Protocol | Source | Purpose |
| --- | --- | --- | --- |
| 22 | tcp | LAN | SSH for `just ansible rootca` |

After Phase B, no ports — there's no NIC. ufw is configured for
default-deny in+out as belt-and-suspenders in case the operator ever
re-attaches the NIC for a maintenance re-bootstrap.

## Files

- `terraform/main.tf` — provider + module call (USB passthrough, conditional NIC, 40 GiB disk on standard `local-lvm`).
- `terraform/variables.tf` — `enable_network` is the air-gap toggle.
- `cloud-init/user-data.yaml.tftpl` — hostname + admin user with plugdev membership.
- `ansible/site.yml` + `roles/rootca/` — toolchain install + polkit/udev + in-VM LUKS partition setup + `rootca-unlock` / `rootca-lock` helpers + lockdown.

## Related

- [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) — workstation workflow.
- [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md) — API token + role.
- `modules/proxmox-vm/` — shared module (USB passthrough + conditional NIC support added for this role).
- `vms/openbao/legacy/` — preserved knowledge of USB-passthrough discovery + sc-hsm-embedded build patterns this role builds on.
- Vault docs (Obsidian, `Projects/Homelab/`):
  - `CardLogix as Offline Root CA.md` — Phase 2 keygen, Phase 3 wrap, Phase 4 signing.
  - `CardLogix DKEK Ceremony — Homelab Single-Share.md` — the pairing ceremony that precedes this VM.
  - `CardLogix HSM Receipt Validation and VM Setup.md` — tamper-check + operational VM spec.
  - `13 Homelab Blueprint.md` — broader trust hierarchy (Anchor #1 = this Root CA).
