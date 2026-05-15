# 0003 — Root CA encryption: in-VM LUKS, not host-side

**Status:** Accepted
**Date:** 2026-05-11

## Context

The Root CA VM stores its CA private key material (or HSM-wrapped key-refs) on disk and must be encrypted at rest. The original design called for a host-side encrypted Directory pool (`rootca-encrypted`) on `pve12t` — host-side LUKS on a dedicated partition; the VM's disk lives on that pool.

Two issues drove a re-evaluation:

1. Host-side LUKS on a Proxmox storage pool requires the operator to unlock the pool at every host boot — and `pve12t` boots more often than the Root CA powers up (Root CA is offline-first), so the unlock burden was inverted vs. the threat model.
2. The encryption was protecting against host theft, but the more relevant attacker is one who exfiltrates the VM disk image. In-VM LUKS protects against that directly without depending on host-side state.

## Decision

Encryption moves inside the guest. The Root CA VM has a LUKS-on-ext4 partition for the CA material, unlocked at **guest** boot, not host boot. The `rootca-encrypted` host-side storage exception is removed from the install runbook.

## Consequences

- `pve12t` install gets simpler — no host-side LUKS pool to set up after PVE install.
- The Root CA VM stays pve12t-pinned, but only for the HSM USB-passthrough reason — not for any host-side storage reason.
- `docs/proxmox-luks-storage.md` and `vms/rootca/` docs need updates (not yet propagated as of 2026-05-14).
- Host-side LUKS pool docs become a "did not need" footnote, not a primary path.

## Alternatives considered

- **Host-side LUKS pool (original design)** — operationally inverted; host unlocks more often than guest powers on.
- **No encryption, rely on physical security** — physical security of the lab room is reasonable but not a substitute for at-rest crypto on CA private key material.
- **HSM-only storage (key never touches disk)** — the HSM stores wrapped key-refs, not the full CA working set; still need an encrypted partition for everything else (intermediate certs, CRLs, audit logs).
