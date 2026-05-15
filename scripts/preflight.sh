#!/usr/bin/env bash
# scripts/preflight.sh — verify prerequisites before `tofu apply`.
#
# Usage: scripts/preflight.sh <role>
#
# Checks (per-role, all required unless noted):
#   1. terraform.tfvars exists in vms/<role>/terraform/ (or the .tpl
#      version + hydrate has been run).
#   2. proxmox_endpoint is reachable from this workstation.
#   3. ssh-agent has a key loaded AND that key can ssh root@<node>
#      without prompting — bpg/proxmox uploads snippets over SSH, and
#      a missing key makes `tofu apply` fail opaquely deep into the
#      plan.
#   4. The Packer template (default 9100) exists on the target node.
#   5. The snippets-storage allows `snippets` content type. Failure
#      here causes cicustom to silently no-op (caught us 2026-05-10).
#
# Exit 0 if all green; non-zero with a cure command on the first
# failure.
#
# This script is intentionally bash, not Python or Go — it's
# pre-`tofu init`, runs in seconds, and the operator already has
# bash + ssh + curl. Anything heavier is wrong for the job.

set -euo pipefail

ROLE="${1:-}"
if [[ -z "$ROLE" ]]; then
  echo "Usage: $0 <role>" >&2
  exit 64
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROLE_TF_DIR="$REPO_ROOT/vms/$ROLE/terraform"

if [[ ! -d "$ROLE_TF_DIR" ]]; then
  echo "ERROR: $ROLE_TF_DIR does not exist." >&2
  echo "       Available roles:" >&2
  find "$REPO_ROOT/vms" -mindepth 2 -maxdepth 2 -type d -name terraform \
    | sed -E "s|^$REPO_ROOT/vms/||; s|/terraform||" \
    | sed 's/^/         /' >&2
  exit 65
fi

cd "$ROLE_TF_DIR"

# ---- 1. terraform.tfvars must exist ------------------------------------------
TFVARS_FILE="terraform.tfvars"
if [[ ! -f "$TFVARS_FILE" ]]; then
  echo "ERROR: $ROLE_TF_DIR/$TFVARS_FILE not found." >&2
  if [[ -f "terraform.tfvars.tpl" ]]; then
    echo "       Run: just hydrate $ROLE   # resolves kp:// placeholders via KeePassXC" >&2
  fi
  if [[ -f "terraform.tfvars.example" ]]; then
    echo "       Or:  cp terraform.tfvars.example terraform.tfvars && \$EDITOR terraform.tfvars" >&2
  fi
  exit 66
fi

# Pull the few values we need to verify reachability. The
# variables.tf for each role is the source of truth for which vars
# exist; here we only need `proxmox_endpoint` and `proxmox_node`.
#
# This is a fragile inline parser, but the alternative (sourcing a
# bash file) doesn't apply to HCL syntax. We accept `key = "value"`
# with quoted strings only, which matches the example .tfvars shape.
parse_tfvar() {
  local key="$1"
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
      sub("^[^=]*=[[:space:]]*\"", "")
      sub("\"[[:space:]]*$", "")
      print
      exit
    }
  ' "$TFVARS_FILE"
}

PROXMOX_ENDPOINT="$(parse_tfvar proxmox_endpoint)"
PROXMOX_NODE="$(parse_tfvar proxmox_node)"

if [[ -z "$PROXMOX_ENDPOINT" || -z "$PROXMOX_NODE" ]]; then
  echo "ERROR: could not parse proxmox_endpoint / proxmox_node from $TFVARS_FILE." >&2
  echo "       Ensure they're declared as: key = \"value\"  (quoted string, on one line)." >&2
  exit 67
fi

# Derive SSH target host from the endpoint URL (host portion only).
SSH_HOST="$(echo "$PROXMOX_ENDPOINT" | sed -E 's|^https?://||; s|:[0-9]+.*$||; s|/.*$||')"
if [[ -z "$SSH_HOST" ]]; then
  echo "ERROR: could not extract host from proxmox_endpoint='$PROXMOX_ENDPOINT'." >&2
  exit 68
fi

# ---- 2. Proxmox API endpoint reachable ---------------------------------------
echo "==> reachability check on $PROXMOX_ENDPOINT"
if ! curl -ksS --max-time 5 -o /dev/null "${PROXMOX_ENDPOINT%/}/api2/json/version"; then
  echo "ERROR: cannot reach Proxmox API at $PROXMOX_ENDPOINT." >&2
  echo "       Check VPN / Tailscale and DNS for $SSH_HOST." >&2
  exit 69
fi

# ---- 3. SSH agent loaded + root@<host> reachable -----------------------------
echo "==> ssh-agent key loaded?"
if ! ssh-add -L >/dev/null 2>&1; then
  echo "ERROR: ssh-agent has no keys loaded." >&2
  echo "       bpg/proxmox uploads cloud-init snippets over SSH; a missing key" >&2
  echo "       would let 'tofu apply' get past the plan and then fail opaquely." >&2
  echo "       Cure: ssh-add ~/.ssh/id_ed25519   (or whichever key root@$SSH_HOST trusts)" >&2
  exit 70
fi

echo "==> ssh root@$SSH_HOST reachable?"
if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
       "root@$SSH_HOST" true; then
  echo "ERROR: ssh root@$SSH_HOST failed (BatchMode=yes — no prompts allowed)." >&2
  echo "       Cure: ssh-copy-id root@$SSH_HOST   (then re-run preflight)" >&2
  exit 71
fi

# ---- 4. Template VM exists on the target node --------------------------------
# Per-node Ubuntu template VMIDs (matches local.ubuntu_template_ids in each
# Linux role's terraform/main.tf — see ADR-0006). Duplicated here because
# parsing HCL from a shell preflight is more fragile than a 5-line case.
# Override via the TEMPLATE_VM_ID env var if a role needs a different one.
if [[ -z "${TEMPLATE_VM_ID:-}" ]]; then
  case "$PROXMOX_NODE" in
    pve12t) TEMPLATE_VM_ID=9100 ;;
    pve13m) TEMPLATE_VM_ID=9101 ;;
    pve13t) TEMPLATE_VM_ID=9102 ;;
    *)
      echo "ERROR: no Ubuntu template VMID mapped for node '$PROXMOX_NODE'." >&2
      echo "       Update the case statement in $0 (or set TEMPLATE_VM_ID)." >&2
      exit 72
      ;;
  esac
fi
echo "==> template VM $TEMPLATE_VM_ID present on $PROXMOX_NODE?"
if ! ssh "root@$SSH_HOST" "qm status $TEMPLATE_VM_ID" >/dev/null 2>&1; then
  echo "ERROR: template VM $TEMPLATE_VM_ID not found on $PROXMOX_NODE." >&2
  echo "       Build it first: packer/ubuntu-24-04-base/build-pve.sh $PROXMOX_NODE" >&2
  echo "       (with VM_ID=$TEMPLATE_VM_ID in .env.$PROXMOX_NODE)" >&2
  exit 72
fi

# ---- 5. Snippets storage allows snippets content -----------------------------
# Default snippets storage is `local` (matches the module's default
# and what every NUC ships with). Allow override via .tfvars.
SNIPPETS_STORAGE="$(parse_tfvar snippets_storage)"
SNIPPETS_STORAGE="${SNIPPETS_STORAGE:-local}"

echo "==> snippets content type enabled on '$SNIPPETS_STORAGE'?"
STORAGE_CONTENT="$(ssh "root@$SSH_HOST" \
  "pvesh get /storage/$SNIPPETS_STORAGE --output-format json" \
  | tr -d '\n' \
  | sed -nE 's/.*"content"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"

if [[ ",${STORAGE_CONTENT}," != *",snippets,"* ]]; then
  echo "ERROR: storage '$SNIPPETS_STORAGE' on $PROXMOX_NODE does not allow 'snippets'." >&2
  echo "       Current content: $STORAGE_CONTENT" >&2
  echo "       Cure (run on the Proxmox host):" >&2
  echo "         ssh root@$SSH_HOST 'pvesm set $SNIPPETS_STORAGE --content snippets,$STORAGE_CONTENT'" >&2
  echo "       Or via GUI: Datacenter → Storage → $SNIPPETS_STORAGE → Edit → tick Snippets." >&2
  exit 73
fi

echo "==> all preflight checks passed for role=$ROLE."
