# vms/amp-game/legacy/ — superseded shell+cloud-init artifacts

Everything in this directory was the **first cut** of the amp-game VM:
a shell-script `deploy.sh` (clones VM 9100 → VM 110, sizes it, uploads
a cloud-init snippet, starts it) + a 42-line `cloud-init/user-data.yaml`
that did identity + ufw + unattended-upgrades.

That shape was retired on **2026-05-14** to align amp-game with the
canonical OpenTofu + Ansible + cloud-init pattern that
[`vms/openbao/`](../../openbao/) established. The new provisioning
shape lives one level up at [`vms/amp-game/`](../) and splits
responsibility:

- **OpenTofu** owns VM shape + clone (`vms/amp-game/terraform/`).
- **cloud-init** is identity-only — hostname, admin user, SSH key
  (`vms/amp-game/cloud-init/user-data.yaml.tftpl`). The legacy
  cloud-init's ufw rules and unattended-upgrades stanzas moved out.
- **Ansible** owns software + config — apt prerequisites, ufw rules,
  unattended-upgrades (`vms/amp-game/ansible/`). What was previously
  baked into cloud-init's `runcmd` is now an idempotent Ansible role
  that can be re-run safely (cloud-init runs once per instance-id; not
  a fit for things that might change later).

The **AMP installer ceremony** (`bash <(curl -fsSL https://getamp.sh)`)
hasn't moved — it stays operator-run because it's interactive (license
key, dashboard creds, Standalone mode) and CubeCoders shifts the
prompts between AMP versions. Scripting it would be fragile. This
mirrors openbao's "Ansible installs OpenBao but `bao operator init`
is operator ceremony" decision (see [ADR-0002](../../../docs/decisions/0002-openbao-seal-shamir-not-hsm.md)).

These files are preserved here, not deleted, because:

- `deploy.sh`'s cicustom + cloud-init-drive-recreate dance is non-
  obvious operational knowledge — Proxmox seals a stale cloud-init
  drive into a clone at ide0, and the script's manual detach/recreate
  at ide2 was the workaround before the `bpg/proxmox` provider's
  `initialization {}` block subsumed it cleanly. Useful reference if
  a future role needs to drive cloud-init outside the provider.
- The cloud-init's ufw + unattended-upgrades stanzas illustrate the
  pattern that the Ansible role now implements idempotently. Useful
  if someone hits a bootstrap-before-Ansible-is-installed scenario
  and wants to do it in cloud-init's `runcmd` again.

VMID note: this legacy `deploy.sh` defaults to `VM_ID="110"` in
[`.env.example`](.env.example). That value still matches the new
[`vms/amp-game/terraform/main.tf`](../terraform/main.tf) VMID (110, in
the workload range per [ADR-0008](../../../docs/decisions/0008-service-vmid-range.md)),
so running the legacy `deploy.sh` after the new shape is deployed
would collide. Don't run both. The legacy is reference-only now.

Git history of the move is preserved (used `git mv`), so `git log
--follow` works back through the original commits.
