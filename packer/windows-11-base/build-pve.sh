#!/usr/bin/env bash
# build-pve.sh — wrapper around `packer init/validate/build` for the
# windows-11-base proxmox-iso source. Sister script to build-qemu.sh
# (qemu/T480 builds); they share the .pkr.hcl + Autounattend.xml +
# provisioner pipeline but have separate operational paths.
#
# Usage:
#   ./build-pve.sh <node>
#
# Where <node> matches a `.env.<node>` file in this directory. Examples:
#   ./build-pve.sh pve12    # build template on pve12 node
#   ./build-pve.sh pve13    # build template on pve13 node
#
# Copy .env.pve.example to .env.<your-node> and fill in PROXMOX_URL,
# PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET, PROXMOX_NODE plus the storage
# pool ISO references. .env.* files are gitignored.
#
# Output: a Proxmox template VM (default ID 9101, name windows-11-base)
# on the configured Proxmox node, sysprep'd and ready to clone via
# Terraform/OpenTofu cicustom user-data.

set -euo pipefail

cd "$(dirname "$0")"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <node>" >&2
  echo "" >&2
  echo "Available .env.<node> files:" >&2
  ls .env.* 2>/dev/null | grep -vE '\.example$|\.qemu\.example$' | sed 's/^/  /' >&2 || \
    echo "  (none found — copy .env.pve.example to .env.<node>)" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 pve12      # build template on pve12 node" >&2
  echo "  $0 pve13      # build template on pve13 node" >&2
  exit 1
fi

TARGET="$1"
ENV_FILE=".env.${TARGET}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy .env.pve.example to ${ENV_FILE} and fill it in." >&2
  exit 1
fi

set -o allexport
# shellcheck disable=SC1091
source "${ENV_FILE}"
set +o allexport

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: required env var ${name} is not set in ${ENV_FILE}" >&2
    echo "       (did you point this script at a qemu env? use ./build-qemu.sh instead.)" >&2
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# proxmox-iso required env
# ----------------------------------------------------------------------------
require PROXMOX_URL
require PROXMOX_TOKEN_ID
require PROXMOX_TOKEN_SECRET
require PROXMOX_NODE

export PKR_VAR_proxmox_url="${PROXMOX_URL}"
export PKR_VAR_proxmox_token_id="${PROXMOX_TOKEN_ID}"
export PKR_VAR_proxmox_token_secret="${PROXMOX_TOKEN_SECRET}"
export PKR_VAR_proxmox_node="${PROXMOX_NODE}"
export PKR_VAR_proxmox_skip_tls_verify="${PROXMOX_SKIP_TLS_VERIFY:-true}"

[[ -n "${ISO_FILE:-}"         ]] && export PKR_VAR_iso_file="${ISO_FILE}"
[[ -n "${VIRTIO_ISO_FILE:-}"  ]] && export PKR_VAR_virtio_iso_file="${VIRTIO_ISO_FILE}"
[[ -n "${ISO_STORAGE_POOL:-}" ]] && export PKR_VAR_iso_storage_pool="${ISO_STORAGE_POOL}"

# ----------------------------------------------------------------------------
# Common vars (shared across both builders, set if present)
# ----------------------------------------------------------------------------
[[ -n "${VM_ID:-}"           ]] && export PKR_VAR_vm_id="${VM_ID}"
[[ -n "${VM_NAME:-}"         ]] && export PKR_VAR_vm_name="${VM_NAME}"
[[ -n "${VM_CORES:-}"        ]] && export PKR_VAR_vm_cores="${VM_CORES}"
[[ -n "${VM_MEMORY:-}"       ]] && export PKR_VAR_vm_memory="${VM_MEMORY}"
[[ -n "${VM_DISK_SIZE:-}"    ]] && export PKR_VAR_vm_disk_size="${VM_DISK_SIZE}"
[[ -n "${VM_STORAGE_POOL:-}" ]] && export PKR_VAR_vm_storage_pool="${VM_STORAGE_POOL}"
[[ -n "${VM_BRIDGE:-}"       ]] && export PKR_VAR_vm_bridge="${VM_BRIDGE}"
[[ -n "${VLAN_TAG:-}"        ]] && export PKR_VAR_vlan_tag="${VLAN_TAG}"
[[ -n "${BUILD_USERNAME:-}"  ]] && export PKR_VAR_build_username="${BUILD_USERNAME}"
[[ -n "${BUILD_PASSWORD:-}"  ]] && export PKR_VAR_build_password="${BUILD_PASSWORD}"

PACKER_ONLY="-only=windows-11-base.proxmox-iso.windows-11-base"

echo "Target: ${TARGET}  (proxmox-iso, node=${PROXMOX_NODE})"

echo "==> packer init"
packer init .

echo "==> packer fmt -check"
packer fmt -check . || {
  echo "WARN: packer fmt would change formatting. Run 'packer fmt .' to fix." >&2
}

echo "==> packer validate"
packer validate ${PACKER_ONLY} .

echo "==> packer build"
exec packer build -on-error=ask ${PACKER_ONLY} .
