# Architecture Decision Records

Decisions that shaped the lab. Each ADR is append-only — superseded, not edited.

## Why this exists

The live docs (`docs/*.md`, `*/README.md`) describe *current* state and get pruned as the lab evolves. That keeps them terse for operators, but loses the rationale for past calls. ADRs preserve the "why we picked Y, what we considered, what we rejected" so a future reader (or future me) doesn't have to reverse-engineer it from `git log`.

## Convention

- One file per decision: `NNNN-short-slug.md`, four-digit zero-padded.
- Date in the body, not the filename — filenames are stable, dates are facts.
- Status is one of: **Accepted**, **Superseded by [NNNN](...)**, **Withdrawn**.
- When a decision is reversed, write a **new** ADR that supersedes the old one. Don't edit the original — set its status to `Superseded by NNNN` and link forward.
- Keep each ADR scannable. If you find yourself writing more than ~80 lines, the rationale probably belongs in the vault and the ADR should link to it.

## Index

| ID | Title | Date | Status |
| --- | --- | --- | --- |
| [0001](0001-windows-base-build-host-virtualbox.md) | Windows base build host: VirtualBox on T480, not qemu | 2026-05-08 | Accepted |
| [0002](0002-openbao-seal-shamir-not-hsm.md) | OpenBao seal: Shamir 5-of-3, not PKCS#11/HSM | 2026-05-10 | Accepted |
| [0003](0003-root-ca-encryption-in-vm.md) | Root CA encryption: in-VM LUKS, not host-side | 2026-05-11 | Accepted |
| [0004](0004-three-node-proxmox-cluster.md) | 3-node Proxmox cluster with TB ring1 + NFS shared storage | 2026-05-13 | Accepted |
| [0005](0005-no-claude-coauthor-trailer.md) | No `Co-Authored-By: Claude` trailer in commits | 2026-05-14 | Accepted |
| [0006](0006-packer-templates-per-node.md) | Packer base templates per-node with distinct VMIDs | 2026-05-14 | Accepted |

## Adding a new ADR

```bash
cp docs/decisions/template.md docs/decisions/000N-your-slug.md
# edit, then add a row to the index above
```
