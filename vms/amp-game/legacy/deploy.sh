#!/usr/bin/env bash
# vms/amp-game/deploy.sh
#
# Clone ubuntu-24-04-base into a configured AMP game-server VM.
#
# Workflow:
#   1. Source ./.env (gitignored)
#   2. Verify the template exists and the target VM ID is free (FAIL-FAST: this
#      script will not modify or destroy an existing VM — protects saved games).
#   3. Render cloud-init/user-data.yaml with values from .env
#   4. Upload the rendered snippet to the Proxmox snippets storage
#   5. qm clone -> qm set -> qm resize -> qm set --cicustom -> qm start
#
# To resize an existing deployment, ssh into the Proxmox node and use:
#   qm set <id> --memory <MB> --cores <N>
#   qm resize <id> scsi0 +<N>G

set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=".env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found in $(pwd)." >&2
  echo "       Copy .env.example to .env and fill it in." >&2
  exit 1
fi

set -o allexport
# shellcheck disable=SC1091
source "$ENV_FILE"
set +o allexport

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: required env var $name is not set in $ENV_FILE" >&2
    exit 1
  fi
}

require PROXMOX_HOST
require PROXMOX_NODE
require TEMPLATE_VM_ID
require VM_ID
require VM_NAME
require VM_CORES
require VM_MEMORY
require VM_DISK_SIZE
require VM_STORAGE_POOL
require SNIPPETS_STORAGE
require ADMIN_USERNAME
require SSH_PUBLIC_KEY

SSH_USER="${SSH_USER:-root}"
SSH_TARGET="${SSH_USER}@${PROXMOX_HOST}"
SSH_OPTS=(-o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=10")

run_remote() {
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"
}

echo "==> verifying template ${TEMPLATE_VM_ID} exists on ${PROXMOX_NODE}"
if ! run_remote "qm status ${TEMPLATE_VM_ID} >/dev/null 2>&1"; then
  echo "ERROR: template VM ${TEMPLATE_VM_ID} not found on ${PROXMOX_NODE}." >&2
  echo "       Did you run packer/ubuntu-24-04-base/build.sh first?" >&2
  exit 1
fi

echo "==> checking VM ${VM_ID} doesn't already exist"
if run_remote "qm status ${VM_ID} >/dev/null 2>&1"; then
  echo "ERROR: VM ${VM_ID} already exists on ${PROXMOX_NODE}." >&2
  echo "       This script will not modify or replace existing VMs." >&2
  echo "       To resize live, ssh ${PROXMOX_HOST} and run:" >&2
  echo "         qm set ${VM_ID} --memory <MB> --cores <N>" >&2
  echo "         qm resize ${VM_ID} scsi0 +<N>G" >&2
  exit 1
fi

echo "==> verifying snippets storage '${SNIPPETS_STORAGE}'"
STORAGE_JSON=$(run_remote "pvesh get /storage/${SNIPPETS_STORAGE} --output-format json")

STORAGE_PATH=$(echo "$STORAGE_JSON" \
  | grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]+"' \
  | sed 's/.*"path"[[:space:]]*:[[:space:]]*"//;s/"$//')
if [[ -z "$STORAGE_PATH" ]]; then
  echo "ERROR: could not resolve path for storage '${SNIPPETS_STORAGE}'." >&2
  exit 1
fi

# Verify the storage actually allows 'snippets' content. Without it,
# Proxmox silently refuses to serve cicustom user-data even though the
# file lands on disk at <path>/snippets/. Failure mode: `qm cloudinit
# dump` returns null, cloud-init falls back to defaults, the VM boots
# with no user-data applied and no DHCP lease. Caught us 2026-05-10.
STORAGE_CONTENT=$(echo "$STORAGE_JSON" \
  | grep -oE '"content"[[:space:]]*:[[:space:]]*"[^"]+"' \
  | sed 's/.*"content"[[:space:]]*:[[:space:]]*"//;s/"$//')
if [[ ",${STORAGE_CONTENT}," != *",snippets,"* ]]; then
  echo "ERROR: storage '${SNIPPETS_STORAGE}' on ${PROXMOX_NODE} does not allow 'snippets' content." >&2
  echo "       Current content list: ${STORAGE_CONTENT}" >&2
  echo "       Fix on the Proxmox host:" >&2
  echo "         ssh ${SSH_TARGET} 'pvesm set ${SNIPPETS_STORAGE} --content snippets,${STORAGE_CONTENT}'" >&2
  echo "       Or via GUI: Datacenter -> Storage -> ${SNIPPETS_STORAGE} -> Edit -> tick Snippets." >&2
  exit 1
fi

SNIPPETS_DIR="${STORAGE_PATH}/snippets"

echo "==> rendering cloud-init/user-data.yaml"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

USER_RENDERED="$TMPDIR/user-data.yaml"
SSH_KEY_ESCAPED=$(printf '%s' "$SSH_PUBLIC_KEY" | sed 's/[\\&|]/\\&/g')
sed \
  -e "s|%%HOSTNAME%%|${VM_NAME}|g" \
  -e "s|%%ADMIN_USERNAME%%|${ADMIN_USERNAME}|g" \
  -e "s|%%SSH_PUBLIC_KEY%%|${SSH_KEY_ESCAPED}|g" \
  cloud-init/user-data.yaml > "$USER_RENDERED"

SNIPPET_NAME="vm-${VM_ID}-${VM_NAME}-user.yaml"
echo "==> uploading ${SNIPPET_NAME} to ${SSH_TARGET}:${SNIPPETS_DIR}/"
run_remote "mkdir -p '${SNIPPETS_DIR}'"
# Pipe the file through ssh+cat instead of scp. scp's binary protocol breaks
# if the remote shell produces any output (e.g. screen -ls in root's .bashrc),
# but cat reading from stdin is unaffected by stderr/stdout chatter.
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "cat > '${SNIPPETS_DIR}/${SNIPPET_NAME}'" < "$USER_RENDERED"

echo "==> cloning ${TEMPLATE_VM_ID} -> ${VM_ID} (${VM_NAME})"
run_remote "qm clone ${TEMPLATE_VM_ID} ${VM_ID} \
  --name ${VM_NAME} \
  --full \
  --storage ${VM_STORAGE_POOL}"

# Detach the cloud-init drive that the Packer template's clone inherited.
# Packer's `cloud_init = true` seals a cloud-init drive into the template
# at build time with content based on whatever cloud-init config existed
# then (none — templates have no cicustom). Clones inherit this drive at
# the first available IDE slot (ide0 for the Ubuntu base). Proxmox 9.1.8's
# `qm set --cicustom` updates the VM config but does NOT regenerate the
# inherited drive's content, and `qm start` doesn't either. Result if left
# in place: the VM boots from the stale drive, cloud-init reads no user-
# data, falls back to defaults — no user, no DHCP, no provisioner.
#
# Burned a day diagnosing this on 2026-05-10 — `qm cloudinit dump` is
# documented to NEVER reflect cicustom content (see Proxmox forum thread
# 164297), which made it look like cicustom itself was broken host-wide.
# It wasn't — the inherited drive from clone was just stale.
#
# Fix is split in two: detach the inherited drive + free the LV NOW, then
# create the fresh drive at ide2 LATER in this script — AFTER `qm set
# --cicustom` has set cicustom on the VM config. Proxmox generates the
# new drive's content from the current config at the moment `qm set --ide2`
# runs, so cicustom must already be in the config by then. (--delete only
# unlinks from config; the LV would cause "volume already exists" on the
# later recreate, hence the explicit pvesm free.)
echo "==> detaching inherited cloud-init drive (will recreate fresh after cicustom)"
CI_SLOT=$(run_remote "qm config ${VM_ID} | grep -oE '^ide[0-9]+: .*media=cdrom' | head -1 | cut -d: -f1")
if [[ -n "$CI_SLOT" ]]; then
  echo "    detaching ${CI_SLOT} (was inherited from template clone)"
  run_remote "qm set ${VM_ID} --delete ${CI_SLOT}"
  run_remote "pvesm free ${VM_STORAGE_POOL}:vm-${VM_ID}-cloudinit 2>/dev/null || true"
else
  echo "    no cloud-init drive inherited (template may have cloud_init=false)"
fi

echo "==> setting sizing (cores=${VM_CORES}, memory=${VM_MEMORY} MB, balloon=${VM_BALLOON:-0})"
run_remote "qm set ${VM_ID} \
  --cores ${VM_CORES} \
  --memory ${VM_MEMORY} \
  --balloon ${VM_BALLOON:-0}"

echo "==> resizing scsi0 to ${VM_DISK_SIZE}"
run_remote "qm resize ${VM_ID} scsi0 ${VM_DISK_SIZE}" || {
  echo "WARN: resize returned non-zero — disk may already be at or above ${VM_DISK_SIZE}. Continuing." >&2
}

echo "==> attaching cloud-init snippet and DHCP ipconfig"
run_remote "qm set ${VM_ID} \
  --cicustom 'user=${SNIPPETS_STORAGE}:snippets/${SNIPPET_NAME}' \
  --ipconfig0 ip=dhcp"

# Create the fresh cloud-init drive at ide2 NOW that cicustom is set on the
# VM config. Proxmox generates the drive's content at this moment from the
# current config, so the user-data is correct from the first boot. (See the
# detach-block comment above for the full bug context.)
echo "==> creating fresh cloud-init drive at ide2 (with cicustom in effect)"
run_remote "qm set ${VM_ID} --ide2 ${VM_STORAGE_POOL}:cloudinit"

echo "==> starting VM ${VM_ID}"
run_remote "qm start ${VM_ID}"

cat <<EOF

==> deploy complete.

Find the VM's IP (qemu-guest-agent runs in the template):
  ssh ${SSH_TARGET} "qm guest cmd ${VM_ID} network-get-interfaces" \\
    | grep -E '"ip-address"' | head -3

Or check your DHCP server / router DHCP table for hostname '${VM_NAME}'.

Next steps once the VM has an IP:
  1. ssh ${ADMIN_USERNAME}@<vm-ip>
  2. sudo su -
  3. bash <(curl -fsSL https://getamp.sh)
       Prompts: dashboard creds (your choice), Docker = n, HTTPS = n
       (Docker = n is right for vanilla MC. Flip to y only if you later
        add Steam-based games like ARK/Rust that benefit from container
        isolation against library/glibc conflicts.)
  4. Open http://<vm-ip>:<port shown by installer>, paste license,
     choose Standalone mode.
EOF
