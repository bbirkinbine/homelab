#!/usr/bin/env bash
# build-vbox.sh — wrapper around `packer init/validate/build` for the
# windows-11-base virtualbox-iso source. Sister script to build-pve.sh
# (proxmox-iso); they share the
# .pkr.hcl + Autounattend.xml + provisioner pipeline but have separate
# operational paths.
#
# Usage:
#   ./build-vbox.sh <host>
#
# Where <host> matches a `.env.<host>` file in this directory. Examples:
#   ./build-vbox.sh t480-vbox    # build VDI locally on T480 via VirtualBox
#
# Copy .env.vbox.example to .env.<your-host> and fill in ISO_URL,
# ISO_CHECKSUM, VIRTIO_ISO_PATH. .env.* files are gitignored.
#
# Output: a sysprep'd VBox VM exported to OVF + VMDK + NVRAM in
# $VBOX_OUTPUT_DIR (default ./output-vbox/). The disk is VMware-style
# VMDK because virtualbox-iso plugin's format="ovf" packages with that
# convention — qemu-img reads VMDK natively. Convert to qcow2 for
# virt-manager via:
#
#   qemu-img convert -f vmdk -O qcow2 -p \
#     output-vbox/windows-11-base-disk001.vmdk \
#     output-vbox/windows-11-base.qcow2
#
# (qemu-utils provides qemu-img.)
#
# Why this source exists: the qemu source's press-any-key prompt window
# is unhittable on T480 + qemu 8.2 + Ubuntu OVMF (verified extensively
# 2026-05-07 — every keystroke delivery path tested missed). VBox's
# input pipeline doesn't have that class of bug.
#
# Linux-only. Requires:
#   - VirtualBox >= 7.0 (Win11 needs UEFI + TPM 2.0 + Secure Boot, all
#     introduced in 7.0). Install: `sudo apt install virtualbox` from
#     Ubuntu 24.04 universe (currently ships 7.2.x).
#   - packer >= 1.10 (HashiCorp BSL move pulled it from Ubuntu repos;
#     install the static binary from releases.hashicorp.com).
#   - Optional: qemu-utils for the post-build VDI→qcow2 conversion.

set -euo pipefail

cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: build-vbox.sh only runs on Linux." >&2
  echo "       Current host is $(uname -s)." >&2
  exit 1
fi

if ! command -v VBoxManage >/dev/null; then
  echo "ERROR: VBoxManage not found. sudo apt install virtualbox" >&2
  exit 1
fi

# Sanity-check VBox version. VBox 7.0+ has --tpm-type and --firmware efi
# support, both required for Win11. Older versions will fail at vboxmanage
# step with "unrecognized option".
VBOX_MAJOR=$(VBoxManage --version 2>/dev/null | cut -d. -f1)
if [[ -z "${VBOX_MAJOR}" || "${VBOX_MAJOR}" -lt 7 ]]; then
  echo "ERROR: VirtualBox >= 7.0 required (Win11 needs --tpm-type + --firmware efi)." >&2
  echo "       Detected: $(VBoxManage --version 2>&1 | head -1)" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <host>" >&2
  echo "" >&2
  echo "Available .env.<host> files:" >&2
  ls .env.* 2>/dev/null | grep -vE '\.example$' | sed 's/^/  /' >&2 || \
    echo "  (none found — copy .env.vbox.example to .env.<host>)" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 t480-vbox     # build VDI on T480 via VirtualBox" >&2
  exit 1
fi

TARGET="$1"
ENV_FILE=".env.${TARGET}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy .env.vbox.example to ${ENV_FILE} and fill it in." >&2
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
    echo "       (did you point this script at a proxmox env? use ./build-pve.sh instead.)" >&2
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# virtualbox-iso required env
# ----------------------------------------------------------------------------
require ISO_URL
require ISO_CHECKSUM
require VIRTIO_ISO_PATH

export PKR_VAR_iso_url="${ISO_URL}"
export PKR_VAR_iso_checksum="${ISO_CHECKSUM}"
export PKR_VAR_virtio_iso_path="${VIRTIO_ISO_PATH}"

[[ -n "${VBOX_OUTPUT_DIR:-}" ]] && export PKR_VAR_vbox_output_dir="${VBOX_OUTPUT_DIR}"

# ----------------------------------------------------------------------------
# Common vars (shared across all builders, set if present)
# ----------------------------------------------------------------------------
[[ -n "${VM_NAME:-}"        ]] && export PKR_VAR_vm_name="${VM_NAME}"
[[ -n "${VM_CORES:-}"       ]] && export PKR_VAR_vm_cores="${VM_CORES}"
[[ -n "${VM_MEMORY:-}"      ]] && export PKR_VAR_vm_memory="${VM_MEMORY}"
[[ -n "${VM_DISK_SIZE:-}"   ]] && export PKR_VAR_vm_disk_size="${VM_DISK_SIZE}"
[[ -n "${BUILD_USERNAME:-}" ]] && export PKR_VAR_build_username="${BUILD_USERNAME}"
[[ -n "${BUILD_PASSWORD:-}" ]] && export PKR_VAR_build_password="${BUILD_PASSWORD}"

PACKER_ONLY="-only=windows-11-base.virtualbox-iso.windows-11-base"

echo "Target: ${TARGET}  (virtualbox-iso, $(uname -s) $(uname -m), VBox $(VBoxManage --version | head -1))"

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
