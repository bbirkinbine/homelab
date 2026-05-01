#!/usr/bin/env bash
# build.sh — convenience wrapper around `packer validate` + `packer build`.
#
# Usage: ./build.sh <node>
#   e.g. ./build.sh pve12
#
# Loads .env.<node> (gitignored), exports PKR_VAR_* for every PROXMOX_* /
# VM_* / ISO_* / BUILD_* variable found, then runs the build. Fails loudly
# if the env file is missing or required values aren't set.

set -euo pipefail

cd "$(dirname "$0")"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <node>" >&2
  echo "Example: $0 pve12" >&2
  echo "" >&2
  echo "Available env files:" >&2
  ls .env.* 2>/dev/null | grep -v '\.example$' | sed 's/^/  /' >&2 || echo "  (none found)" >&2
  exit 1
fi

NODE="$1"
ENV_FILE=".env.${NODE}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy .env.example to ${ENV_FILE} and fill it in." >&2
  exit 1
fi

set -o allexport
# shellcheck disable=SC1091
source "${ENV_FILE}"
set +o allexport

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: required env var ${name} is not set in .env" >&2
    exit 1
  fi
}

require PROXMOX_URL
require PROXMOX_TOKEN_ID
require PROXMOX_TOKEN_SECRET
require PROXMOX_NODE

export PKR_VAR_proxmox_url="${PROXMOX_URL}"
export PKR_VAR_proxmox_token_id="${PROXMOX_TOKEN_ID}"
export PKR_VAR_proxmox_token_secret="${PROXMOX_TOKEN_SECRET}"
export PKR_VAR_proxmox_node="${PROXMOX_NODE}"
export PKR_VAR_proxmox_skip_tls_verify="${PROXMOX_SKIP_TLS_VERIFY:-true}"

[[ -n "${VM_ID:-}"            ]] && export PKR_VAR_vm_id="${VM_ID}"
[[ -n "${VM_NAME:-}"          ]] && export PKR_VAR_vm_name="${VM_NAME}"
[[ -n "${VM_CORES:-}"         ]] && export PKR_VAR_vm_cores="${VM_CORES}"
[[ -n "${VM_MEMORY:-}"        ]] && export PKR_VAR_vm_memory="${VM_MEMORY}"
[[ -n "${VM_DISK_SIZE:-}"     ]] && export PKR_VAR_vm_disk_size="${VM_DISK_SIZE}"
[[ -n "${VM_STORAGE_POOL:-}"  ]] && export PKR_VAR_vm_storage_pool="${VM_STORAGE_POOL}"
[[ -n "${VM_BRIDGE:-}"        ]] && export PKR_VAR_vm_bridge="${VM_BRIDGE}"
[[ -n "${VLAN_TAG:-}"         ]] && export PKR_VAR_vlan_tag="${VLAN_TAG}"
[[ -n "${ISO_FILE:-}"         ]] && export PKR_VAR_iso_file="${ISO_FILE}"
[[ -n "${ISO_URL:-}"          ]] && export PKR_VAR_iso_url="${ISO_URL}"
[[ -n "${ISO_CHECKSUM:-}"     ]] && export PKR_VAR_iso_checksum="${ISO_CHECKSUM}"
[[ -n "${ISO_STORAGE_POOL:-}" ]] && export PKR_VAR_iso_storage_pool="${ISO_STORAGE_POOL}"
[[ -n "${BUILD_USERNAME:-}"   ]] && export PKR_VAR_build_username="${BUILD_USERNAME}"
[[ -n "${BUILD_PASSWORD:-}"   ]] && export PKR_VAR_build_password="${BUILD_PASSWORD}"

echo "==> packer init"
packer init .

echo "==> packer fmt -check"
packer fmt -check . || {
  echo "WARN: packer fmt would change formatting. Run 'packer fmt .' to fix." >&2
}

echo "==> packer validate"
packer validate .

echo "==> packer build"
exec packer build -on-error=ask .
