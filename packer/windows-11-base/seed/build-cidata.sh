#!/usr/bin/env bash
# build-cidata.sh — build a NoCloud cidata.iso for VBox / virt-manager
# boots of windows-11-base.qcow2. cloudbase-init in the guest reads the
# ISO on first boot and creates the user defined in user-data.
#
# Usage:
#   ./seed/build-cidata.sh                          # uses ./seed/lab-seed.yaml
#   ./seed/build-cidata.sh seed/other.yaml          # explicit yaml
#
# Output: output-vbox/cidata.iso
#
# After build:
#   VBoxManage import output-vbox/windows-11-base.ovf
#   # In VBox UI (or CLI): attach output-vbox/cidata.iso as second CDROM,
#   # boot the VM. cloudbase-init reads it and creates the user.
#
# Linux-only. Requires `genisoimage` (apt install genisoimage). The
# equivalent on macOS is hdiutil/mkisofs from cdrtools, but VBox-side
# standalone use lives on the T480 in this homelab, so we stay
# Linux-only here.

set -euo pipefail

cd "$(dirname "$0")/.."

USER_DATA="${1:-seed/lab-seed.yaml}"

if [[ ! -f "${USER_DATA}" ]]; then
  echo "ERROR: ${USER_DATA} not found." >&2
  echo "       Copy seed/lab-seed.example.yaml to seed/lab-seed.yaml and fill it in." >&2
  exit 1
fi

if ! command -v genisoimage >/dev/null; then
  echo "ERROR: genisoimage not found. sudo apt install genisoimage" >&2
  exit 1
fi

mkdir -p output-vbox

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# meta-data is required by the NoCloud datasource. instance-id changing
# every build means cloudbase-init treats each ISO as a fresh instance
# and re-runs all plugins. For ad-hoc lab use that's exactly what we want.
cat > "${WORK}/meta-data" <<META
instance-id: lab-$(date -u +%Y%m%d-%H%M%S)
local-hostname: lab
META

cp "${USER_DATA}" "${WORK}/user-data"

OUT="output-vbox/cidata.iso"
genisoimage -quiet -output "${OUT}" -volid cidata \
            -joliet -rock "${WORK}/meta-data" "${WORK}/user-data"

echo "Wrote ${OUT}"
echo
echo "Next: VBoxManage import output-vbox/windows-11-base.ovf"
echo "      then attach ${OUT} as second CDROM and boot."
