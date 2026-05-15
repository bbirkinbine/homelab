#!/usr/bin/env bash
# scripts/write-inventory.sh — populate vms/<role>/ansible/inventory.yml
# from `tofu output ansible_inventory_hint`.
#
# Usage: scripts/write-inventory.sh <role>
#
# Replaces the manual paste step in the per-role deploy flow. Reads the
# role's tofu output (which the module's outputs.tf renders as a paste-
# ready inventory block) and writes it to the gitignored inventory.yml
# the Ansible play actually consumes.
#
# Refuses to write a broken inventory: if `module.<role>.ipv4` is null
# (qemu-guest-agent hasn't reported the VM's IP yet), the rendered
# output contains the placeholder string `<paste-from-tofu-output-or-router>`.
# The script detects that and bails with a clear error — the previous
# inventory.yml (if any) stays untouched.
#
# Why bash, not a Justfile inline: the placeholder-detection + clear
# failure message would be ugly as a one-liner. Matches the
# preflight.sh / hydrate.sh pattern — one script, one job, no deps
# beyond bash + tofu.

set -euo pipefail

ROLE="${1:-}"
if [[ -z "$ROLE" ]]; then
  echo "Usage: $0 <role>" >&2
  exit 64
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROLE_TF_DIR="$REPO_ROOT/vms/$ROLE/terraform"
ROLE_ANSIBLE_DIR="$REPO_ROOT/vms/$ROLE/ansible"
INVENTORY_FILE="$ROLE_ANSIBLE_DIR/inventory.yml"

if [[ ! -d "$ROLE_TF_DIR" ]]; then
  echo "ERROR: $ROLE_TF_DIR does not exist." >&2
  echo "       Available roles:" >&2
  find "$REPO_ROOT/vms" -mindepth 2 -maxdepth 2 -type d -name terraform \
    | sed -E "s|^$REPO_ROOT/vms/||; s|/terraform||" \
    | sed 's/^/         /' >&2
  exit 65
fi

if [[ ! -d "$ROLE_ANSIBLE_DIR" ]]; then
  echo "ERROR: $ROLE_ANSIBLE_DIR does not exist." >&2
  echo "       The role looks half-ported (terraform/ present, ansible/ missing)." >&2
  exit 66
fi

# Refresh outputs from real infra before reading. `tofu output` reads
# cached values from state, NOT re-evaluated expressions. Two ways that
# bites without this step:
#   1. The output's `format(...)` string in outputs.tf changes (e.g. a
#      new field added to the inventory shape) — the cached value is
#      stale until the next `tofu apply`.
#   2. The VM's DHCP lease changes IP between deploys — the cached ipv4
#      output points at the old IP.
# `apply -refresh-only -auto-approve` re-runs both: pulls live agent
# state from Proxmox AND re-evaluates output expressions. Doesn't touch
# infrastructure (refresh-only is a no-op for resources by definition).
# Skip with BUILD_SKIP_REFRESH=1 if you have a reason (e.g. probing an
# offline cluster from a stale local state).
if [[ "${BUILD_SKIP_REFRESH:-0}" != "1" ]]; then
  (cd "$ROLE_TF_DIR" && tofu apply -refresh-only -auto-approve -input=false) >/dev/null 2>&1 || {
    echo "WARN: 'tofu apply -refresh-only' failed for role=$ROLE — proceeding with cached state." >&2
    echo "      If the inventory ends up wrong, run 'tofu apply' in $ROLE_TF_DIR first." >&2
  }
fi

# Pull the inventory hint from tofu. `tofu output -raw <name>` prints the
# raw string value (no JSON wrapping). Capture, don't pipe, so we can
# inspect the content before writing.
HINT="$(cd "$ROLE_TF_DIR" && tofu output -raw ansible_inventory_hint 2>/dev/null)" || {
  echo "ERROR: 'tofu output ansible_inventory_hint' failed for role=$ROLE." >&2
  echo "       Has 'just apply $ROLE' been run successfully?" >&2
  echo "       (tofu state may be empty or the output may be missing.)" >&2
  exit 70
}

# The outputs.tf for every role renders ansible_inventory_hint with a
# coalesce() fallback to "<paste-from-tofu-output-or-router>" when
# `module.<role>.ipv4` is null. That means the qemu-guest-agent hasn't
# reported the VM's IP yet (cloud-init still finishing, or agent not
# running). Refuse to write a broken inventory.
if [[ "$HINT" == *"<paste-from-tofu-output-or-router>"* ]]; then
  echo "ERROR: tofu output ipv4 is null for role=$ROLE." >&2
  echo "       The qemu-guest-agent hasn't reported the VM's IP yet." >&2
  echo "       Wait ~30s after first boot and retry, or look up the IP" >&2
  echo "       from your router's DHCP lease table by hostname '$ROLE'." >&2
  echo "       If the IP is known and you need to override, write" >&2
  echo "       inventory.yml by hand from inventory.yml.example." >&2
  exit 71
fi

# Write atomically: tmp file in the same dir, then mv. Avoids leaving a
# partial inventory.yml if something goes wrong mid-write.
TMP="$(mktemp "${INVENTORY_FILE}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$HINT" > "$TMP"
mv "$TMP" "$INVENTORY_FILE"
trap - EXIT

echo "wrote $INVENTORY_FILE"
