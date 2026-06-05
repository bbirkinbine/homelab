#!/usr/bin/env bash
# build-pve.sh — convenience wrapper around `packer validate` + `packer build`.
#
# Usage: ./build-pve.sh <node>
#   e.g. ./build-pve.sh pve12t
#
# Naming mirrors packer/windows-11-base/build-pve.sh; the Ubuntu base has
# only a proxmox-iso source today, but the parallel name keeps the two
# Packer trees consistent and matches the convention documented in
# CLAUDE.md + docs/decisions/0001-windows-base-build-host-virtualbox.md.
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

# ---- Preflight: Proxmox API connectivity + node existence check ----
#
# Fail fast on hostname/TLS/token/node-name issues that would otherwise
# only surface 3+ minutes into `packer build` (where the error is buried
# under retry chatter), or — for the wrong-PROXMOX_NODE case — silently
# at the SSH preflight below with a confusing "could not resolve host"
# error. One curl to /api2/json/nodes covers:
#   - DNS / TLS / wrong port (curl-level error)
#   - bad token (HTTP 401, surfaced by curl -f)
#   - PROXMOX_NODE typo (node missing from cluster nodes list)
#
# Skip with BUILD_SKIP_API_CHECK=1 if you have a reason (e.g., probing
# a node that's intentionally offline). Inherits PROXMOX_SKIP_TLS_VERIFY
# from .env so self-signed homelab certs work.

if [[ "${BUILD_SKIP_API_CHECK:-0}" == "1" ]]; then
  echo "==> preflight: API check SKIPPED (BUILD_SKIP_API_CHECK=1)"
else
  API_NODES_URL="${PROXMOX_URL%/}/nodes"
  echo "==> preflight: API connectivity check (${API_NODES_URL})"
  CURL_OPTS=(-sSf --connect-timeout 5 --max-time 15)
  if [[ "${PROXMOX_SKIP_TLS_VERIFY:-true}" == "true" ]]; then
    CURL_OPTS+=(-k)
  fi
  API_RESP=$(curl "${CURL_OPTS[@]}" \
    -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
    "${API_NODES_URL}" 2>&1) || {
    echo "ERROR: Proxmox API check failed at ${API_NODES_URL}" >&2
    echo "       curl said: ${API_RESP}" >&2
    echo "       Check PROXMOX_URL resolves, the node is up, and" >&2
    echo "       PROXMOX_TOKEN_ID / PROXMOX_TOKEN_SECRET are valid." >&2
    exit 1
  }
  if ! grep -qE "\"node\"[[:space:]]*:[[:space:]]*\"${PROXMOX_NODE}\"" <<< "$API_RESP"; then
    echo "ERROR: PROXMOX_NODE='${PROXMOX_NODE}' not found in cluster nodes." >&2
    echo "       API returned: ${API_RESP}" >&2
    echo "       Check PROXMOX_NODE matches an actual cluster node name (case-sensitive)." >&2
    exit 1
  fi
  echo "    API reachable, token accepted, node ${PROXMOX_NODE} present"
fi

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
[[ -n "${BUILD_USERNAME:-}"   ]] && export PKR_VAR_build_username="${BUILD_USERNAME}"
[[ -n "${BUILD_PASSWORD:-}"   ]] && export PKR_VAR_build_password="${BUILD_PASSWORD}"

# ---- Preflight: clean stale build artifacts from prior aborted runs ----
#
# packer-plugin-proxmox's stepFinalizeTemplateConfig calls
#   lvcreate vm-${vm_id}-cloudinit
# to attach the cloud-init disk. If a previous build aborted after that
# LV was created but before the VM was sealed (Ctrl-C, network blip,
# autoinstall hang), and the VM was later reaped without
# --destroy-unreferenced-disks, the LV survives as an orphan. The next
# run trips at finalize with:
#   Logical Volume "vm-${vm_id}-cloudinit" already exists in volume group
#
# This preflight probes for either a leftover VM at the target ID OR an
# orphan cloud-init LV, and cleans both. Skip with
# BUILD_SKIP_PREFLIGHT_CLEANUP=1 if you have a reason to keep an
# existing VM at vm_id.
#
# WARNING: this destroys any existing VM at PKR_VAR_vm_id on the target
# node. The build-pve.sh <node> arg should be unambiguous — confirm before
# letting this run on a node that may have an in-use template.

TARGET_VMID="${PKR_VAR_vm_id:-9100}"
PROXMOX_SSH_HOST="${PROXMOX_SSH_HOST:-$(printf '%s' "$PROXMOX_URL" | sed -E 's|^https?://||; s|:[0-9]+.*||; s|/.*||')}"
PROXMOX_SSH_USER="${PROXMOX_SSH_USER:-root}"
PREFLIGHT_TARGET="${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}"
PREFLIGHT_SSH_OPTS=(-o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=10")

if [[ "${BUILD_SKIP_PREFLIGHT_CLEANUP:-0}" == "1" ]]; then
  echo "==> preflight: SKIPPED (BUILD_SKIP_PREFLIGHT_CLEANUP=1)"
else
  echo "==> preflight: probing ${PREFLIGHT_TARGET} for stale VM ${TARGET_VMID} / vm-${TARGET_VMID}-cloudinit"
  echo "    (will destroy if found — abort with Ctrl-C in the next 60 seconds if unsafe)"
  sleep 60
  # Pass VMID as an env var to a quoted heredoc so $VMID expands on the
  # remote shell, not locally. lvs runs against any LVM VG on the host;
  # the awk filter matches just the cloud-init LV name regardless of VG.
  ssh "${PREFLIGHT_SSH_OPTS[@]}" "$PREFLIGHT_TARGET" "VMID='${TARGET_VMID}' bash -s" <<'REMOTE'
    set -e
    STALE=0
    if qm status "$VMID" >/dev/null 2>&1; then
      echo "    found existing VM $VMID — will destroy with --purge --destroy-unreferenced-disks"
      STALE=1
    fi
    LV_VG=$(lvs --noheadings -o lv_name,vg_name 2>/dev/null \
            | awk -v v="vm-${VMID}-cloudinit" '$1==v {print $2; exit}')
    if [ -n "$LV_VG" ]; then
      echo "    found orphan LV ${LV_VG}/vm-${VMID}-cloudinit — will lvremove"
      STALE=1
    fi
    if [ "$STALE" = "0" ]; then
      echo "    clean — nothing to do"
      exit 0
    fi
    if qm status "$VMID" >/dev/null 2>&1; then
      qm destroy "$VMID" --purge --destroy-unreferenced-disks
    fi
    # qm destroy --destroy-unreferenced-disks should catch the LV in
    # most cases, but the half-cleaned scenario (VM already gone, LV
    # orphaned) needs a direct lvremove. Re-probe and clean if still
    # present.
    LV_VG=$(lvs --noheadings -o lv_name,vg_name 2>/dev/null \
            | awk -v v="vm-${VMID}-cloudinit" '$1==v {print $2; exit}')
    if [ -n "$LV_VG" ]; then
      lvremove -f "${LV_VG}/vm-${VMID}-cloudinit"
    fi
    echo "    preflight cleanup complete"
REMOTE
fi

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
