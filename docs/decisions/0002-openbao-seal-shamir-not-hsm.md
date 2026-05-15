# 0002 — OpenBao seal: Shamir 5-of-3, not PKCS#11/HSM

**Status:** Accepted
**Date:** 2026-05-10

## Context

The OpenBao VM was originally going to use the SmartCard-HSM (PKCS#11) as its seal mechanism — auto-unseal at boot, no human in the loop. After a closer look at the mechanism intersection between OpenBao's seal interface and the specific SmartCard-HSM on hand, the intersection turned out to be empty: the algorithms OpenBao expects from a PKCS#11 seal aren't ones this HSM exposes.

## Decision

OpenBao uses Shamir 5-of-3 manual unseal. The HSM is re-roled to back the offline Root CA instead (see [0003](0003-root-ca-encryption-in-vm.md) for the Root CA's broader encryption story), where the algorithm match is clean.

## Consequences

- Every cold boot of OpenBao requires a human (or three) to type unseal keys. Operational tax — not automated.
- 5-of-3 enforces shared trust if keys are ever distributed — defensible for a secret manager.
- The HSM is freed up for the Root CA, where it earns its keep (offline ceremony, not always-online).
- No HSM-via-PKCS#11 seal path remains on the OpenBao VM — don't try to restore it.

## Alternatives considered

- **A different HSM model with broader algorithm coverage** — viable but adds hardware purchase + new attack surface; the Shamir tax is real but bounded.
- **Cloud KMS auto-unseal (AWS KMS, etc.)** — the lab is intentionally offline-first; deferred indefinitely.
- **Transit seal via another OpenBao instance** — chicken-and-egg for the lab's only OpenBao.

Full rationale and the alternatives-considered set lives in the private design vault.
