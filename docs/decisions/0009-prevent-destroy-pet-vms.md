# 0009 — `prevent_destroy = true` is the default for pet VMs

**Status:** Accepted
**Date:** 2026-05-21

## Context

Every VM the lab provisions through [`modules/proxmox-vm/`](../../modules/proxmox-vm/) is a pet: unique role, unique VMID per [ADR-0008](0008-service-vmid-range.md), named in `/etc/hosts`, persistent on-disk state, no replication. There is one `openbao`, one `rootca`, one `llm`, one `monitoring`. None of them should ever be destroyed by an `apply` that an operator didn't deliberately mean to destroy.

The shared module did not encode this property. It treated every VM the way the `bpg/proxmox` provider treats any resource: a benign-looking attribute change on a resource the provider classifies as `ForceNew` produces a destroy-recreate plan. Several cloud-init-related attributes in [`proxmox_virtual_environment_vm.initialization`](https://github.com/bpg/terraform-provider-proxmox) fall in that category — see upstream issues [#1636](https://github.com/bpg/terraform-provider-proxmox/issues/1636), [#1998](https://github.com/bpg/terraform-provider-proxmox/issues/1998), [#2071](https://github.com/bpg/terraform-provider-proxmox/issues/2071). A recent destructive-apply incident in this lab (see operator's vault for the post-mortem) demonstrated that the "read the plan carefully" floor is insufficient: `tofu apply -auto-approve`, distractedness, or skim-reading a multi-resource diff all bypass it.

The compensating control that holds is structural: make the provider refuse the destroy at plan time, with a clear error, before any state mutation. OpenTofu's [`lifecycle { prevent_destroy = true }`](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle) does exactly that. It fails the plan with an explicit error message naming the protected resource, and the apply cannot proceed without the operator removing the protection first.

## Decision

The shared `modules/proxmox-vm/` module hardcodes `lifecycle { prevent_destroy = true }` on the `proxmox_virtual_environment_vm.this` resource. HCL does not permit `prevent_destroy` to be set from a variable — the value must be a literal at parse time — so there is no per-role opt-out via tfvars. An intentional destroy requires the operator to edit the module and remove the lifecycle block, then restore it.

**Concrete binding (this ADR's commit):**

`modules/proxmox-vm/main.tf` — add inside `proxmox_virtual_environment_vm.this`:

```hcl
lifecycle {
  // Pet VMs (ADR-0009). Every role under vms/ is a unique service with
  // persistent on-disk state; none should be destroyed by an apply that
  // the operator didn't deliberately mean to destroy. Removing this
  // lifecycle block is the explicit "yes, destroy this" signal. Do that
  // for a single intentional rebuild, then restore the block in the
  // same PR — never commit the module without it.
  prevent_destroy = true
}
```

No role-level changes. Every role inherits the protection through the shared module on its next apply. The lifecycle block is a no-op for any VM whose plan doesn't propose a destroy — the protection only triggers when destruction is attempted.

### Amendment (2026-06-05) — applies to the Windows module too

A second shared module, [`modules/proxmox-vm-windows/`](../../modules/proxmox-vm-windows/), was added when the first Windows VM role shipped ([`vms/win-client/`](../../vms/win-client/)). Windows guests require ForceNew-prone attributes the Linux module deliberately avoids (`bios`, `efi_disk`, `tpm_state`, `operating_system`) plus a different cloud-init shape, so they live in a separate module rather than as knobs on `modules/proxmox-vm/` — which keeps the Linux module (shared by the live pets) free of new ForceNew surface.

That Windows module carries the **identical** `lifecycle { prevent_destroy = true }` on its `proxmox_virtual_environment_vm.this`. So this ADR's invariant holds for **every** provisioned VM regardless of OS, and the intentional-destroy procedure is the same — comment out the lifecycle block in whichever module the role uses (`modules/proxmox-vm/` for Linux, `modules/proxmox-vm-windows/` for Windows), apply, then restore it.

## Consequences

- **The bpg `ForceNew` class of bug becomes a plan-time error, not a silent destroy.** Adding any attribute that the provider classifies as ForceNew (`meta_data_file_id`, certain disk attribute changes, etc.) to a deployed VM now fails the plan with `Resource module.<role>.proxmox_virtual_environment_vm.this has lifecycle.prevent_destroy set, but the plan calls for this resource to be destroyed.`
- **`tofu apply -auto-approve` becomes safer by default.** Even if an operator forgets to drop `-auto-approve`, the lifecycle gate refuses the destroy before any state mutation.
- **Intentional destroys are friction.** A genuine rebuild requires editing `modules/proxmox-vm/main.tf` to comment out the lifecycle block, applying, then restoring it. This is the cost; it is also the feature. Rebuilds of pet VMs are rare events; the few extra seconds of operator intent is exactly the gate we want.
- **The `_template` role inherits the safe default with no extra wiring.** New roles created from `vms/_template/` are protected from day one.
- **PBS backups remain the recovery path for the rare intentional destroy.** Disabling `prevent_destroy` does not waive any other safety; it just permits the destroy that the operator deliberately wants.
- **Provider drift detection is unaffected.** `tofu plan` still surfaces config drift, attribute changes, and in-place updates. Only the `Plan: ... to destroy` action class is gated.

## Alternatives considered

- **Per-role opt-in (`prevent_destroy = false` by default).** Rejected — it's the current behavior and the source of the incident. Defaulting to the dangerous shape and requiring operators to remember to opt into safety is the wrong invariant.
- **HCL variable as the `prevent_destroy` value.** Terraform/OpenTofu rejects this at parse time; `prevent_destroy` must be a literal `true` or `false`. The module hardcodes `true`; roles that need destroyability comment out the lifecycle block locally. Cleaner than introducing a variable that the language doesn't honor.
- **OPA / Conftest policy that fails any plan containing `delete`.** A complementary defense, not a replacement. Conftest needs CI or a pre-apply hook; `prevent_destroy` is enforced by the provider itself with zero infrastructure. Adopt Conftest later for additional defense in depth.
- **Relying on operator discipline alone (no `-auto-approve`, careful plan review).** Discipline is necessary but not sufficient. The incident showed that the floor "read every plan carefully" is permeable. Layered defense — lifecycle gate + plan review + drop `-auto-approve` — is the goal; this ADR encodes the load-bearing layer.
- **`prevent_destroy = true` hardcoded in every role's main.tf instead of the shared module.** Rejected — duplicates the rule across every role file, drifts as roles are added, and misses the protection on `_template`-derived new roles unless the operator remembers to add it. The shared module is the right enforcement point.
