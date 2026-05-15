# 0008 — Service VMID range 8000-8099 (separated from workloads)

**Status:** Accepted
**Date:** 2026-05-14

## Context

VMID assignment in the lab grew by accretion. At the time this ADR was written, the live numbering was:

- `openbao` — VMID 130
- `rootca` — VMID 110 (in source; not yet deployed)
- `amp-game` (legacy) — VMID 110 (in source; legacy `deploy.sh`)
- `llm` (legacy) — currently unset / per-deploy

Two latent problems:

1. **Source-level collision.** `rootca` and `amp-game` both claimed `vm_id = 110` in their respective files. Neither was `tofu apply`'d so no live collision yet, but the next deploy of one would have blocked the other.
2. **No tier separation.** Services and workloads sat in adjacent integers (`110`, `130`) with no semantic grouping. A `qm destroy {100..199}` mistake or a bulk-clone script keyed on a numeric range could not tell `openbao` apart from `amp-game`.

The 9100-9299 range is already reserved for Packer base templates ([ADR-0006](0006-packer-templates-per-node.md)) — itself a tier-separation convention applied to foundational images. Extending the same pattern to "foundational services" is natural.

## Decision

Reserve **8000-8099** for infrastructure and security services. Workload VMs use **100-399**. Templates remain in **9100-9299** per [ADR-0006](0006-packer-templates-per-node.md).

**Concrete renumber (this ADR's commit):**

- `openbao`: `130` → `8030`
- `rootca`: `110` → `8031` (also resolves the source-level collision with `amp-game`)

**Aspirational subdivision of the workload range** (not load-bearing; convention only, deviate when there's a reason):

| Range | Category | Examples |
| --- | --- | --- |
| 100-199 | Application / workload VMs | `amp-game` (110), future media servers, dashboards |
| 200-299 | Compute / accelerator VMs | future `llm` (200?), ML workloads |
| 300-399 | Reserved for k8s/k3s nodes | `k3s-control` (310), `k3s-worker-N` (311+) |
| 8000-8099 | Infrastructure / security services | `openbao` (8030), `rootca` (8031), future cert-manager / DNS |
| 9100-9199 | Ubuntu Packer templates | per-node (ADR-0006) |
| 9200-9299 | Windows Packer templates | per-node (ADR-0006) |

The load-bearing rule is "services in 8000-8099." The finer subdivision below 1000 is guidance; future roles should follow it where applicable but the ADR doesn't supersede over a thoughtful one-off deviation.

## Consequences

- **Blast-radius separation.** A workload-range bulk operation can't accidentally touch service VMs. `qm destroy 100-399` is bounded to the application tier.
- **Visual grouping in the Proxmox UI.** VMs sort by VMID; services cluster at the top of the list, workloads in the middle, templates at the bottom. A glance at the UI maps tier→region of the screen.
- **Mental-model parity with [ADR-0006](0006-packer-templates-per-node.md).** Foundational things (templates → 9xxx, services → 8xxx) sit above the noise of application VMs.
- **Cheap to introduce now.** Neither `openbao` nor `rootca` had been `tofu apply`'d at the time of this ADR — both renumbers are one-line source edits with no state surgery. The cost would have been materially higher (live `qm set --vmid` or `tofu destroy/apply` cycles) had this been deferred.
- **Per-role tfvars unaffected.** VMIDs are hardcoded in each role's `terraform/main.tf` module call (`vm_id = NNNN`); no top-level convention table needs to be maintained. The ADR is the convention; the role file is the binding.
- **Live services exception.** If a future renumber proposal lands while the service is running and seal-initialized (e.g., openbao with Shamir keys committed), the renumber must be deferred to a maintenance window. Don't `tofu destroy` a live service to satisfy a numbering convention.

## Alternatives considered

- **Keep sequential numbering.** Rejected — already produced the 110/110 source-level collision between `rootca` and `amp-game`. Numbering by arrival order doesn't scale past a handful of VMs.
- **Use tags instead of VMID ranges** (e.g., `tags = ["service", ...]`). Rejected as a substitute (but kept as complementary). Tags are filterable but not visible in `qm destroy`, `qm clone`, the UI sort order, or in bash globs (`qm list | awk '$1 ~ /^8/'`). VMID is what shows up in the operator's hands during emergencies; that's where the tier marker belongs.
- **Finer subdivision encoded as a hard rule** (e.g., apps in 100-199 *must not* be reassigned to 200-299). Rejected as too rigid — the aspirational table above is guidance, not gospel. The only ADR-load-bearing rule is "services in 8000-8099."
- **Use four-digit VMIDs everywhere** (e.g., 1100 for amp-game, 1130 for openbao). Rejected — disambiguates services from workloads but loses the visual clarity of "8 = service, 1-3 = workload, 9 = template." Three-digit workload VMIDs match Proxmox community conventions and stay readable in `pvesh` output.
