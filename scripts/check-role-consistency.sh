#!/usr/bin/env bash
# scripts/check-role-consistency.sh — catch drift across vms/*/terraform/ roles.
#
# Usage: scripts/check-role-consistency.sh
#        (or `just check-roles` from the repo root)
#
# What it checks (each is independent — all run, summary at the end):
#   1. `tofu fmt -check` across every tracked .tf file. Excludes the
#      gitignored terraform.tfvars files so local sizing-override
#      drift doesn't fail the check.
#   2. Every role's variables.tf surfaces `disk_storage` AND
#      `snippets_storage`. Both are required surface area per the
#      role convention introduced in feat/nas-vms-disk-default.
#   3. Every role's main.tf wires both storage vars through to the
#      shared module: `disk_storage = var.disk_storage` and
#      `snippets_storage = var.snippets_storage`.
#   4. No role references the removed `encrypted_storage_pool` variable
#      (dropped 2026-05-11 when LUKS moved in-VM; the legacy/ subtrees
#      are excluded — they're intentionally preserved as reference).
#   5. Every role has the canonical file set under terraform/
#      (main.tf, variables.tf, versions.tf, outputs.tf,
#      terraform.tfvars.example, terraform.tfvars.tpl).
#   6. VMID conformance per ADR-0008: services in 8000-8099,
#      workloads in 100-399. Role class is named explicitly in the
#      role_class() function below; add new roles there.
#
# Why bash instead of Python or a real linter framework: this runs
# pre-commit / pre-PR, in seconds, and the operator already has
# bash + grep + awk. Anything heavier is wrong for the job. Mirror
# of the rationale in scripts/preflight.sh.
#
# Exit 0 if every check passes; 1 if any fail; 2 if the script can't
# run (no roles discovered, missing tool).

set -euo pipefail
shopt -s nullglob

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Colors only when stdout is a terminal — keeps CI/log output clean.
if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BOLD=""
  RESET=""
fi

PASS=0
FAIL=0
FAILURES=()

pass() {
  PASS=$((PASS + 1))
  printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"
  if [[ -n "${2:-}" ]]; then
    # Indent the detail block under the FAIL line.
    printf '%s\n' "$2" | sed 's/^/       /'
  fi
}

heading() {
  printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$RESET"
}

# Role-class table for VMID conformance. Edit when adding a new role.
# Service VMIDs live in 8000-8099; workload VMIDs in 100-399 (ADR-0008).
role_class() {
  case "$1" in
    openbao|openclaw|nemoclaw|rootca) echo service ;;
    amp-game)                          echo workload ;;
    *)                                 echo unknown ;;
  esac
}

# --- discover roles ---------------------------------------------------------

ROLES=()
for role_dir in vms/*/terraform; do
  role="$(basename "$(dirname "$role_dir")")"
  ROLES+=("$role")
done

if [[ ${#ROLES[@]} -eq 0 ]]; then
  echo "ERROR: no vms/*/terraform/ roles found. Are you in the repo root?" >&2
  exit 2
fi

printf '%sDiscovered roles:%s %s\n' "$BOLD" "$RESET" "${ROLES[*]}"

# --- 1. tofu fmt across tracked .tf files ----------------------------------

heading "1. tofu fmt (tracked .tf files only)"
if ! command -v tofu >/dev/null 2>&1; then
  fail "tofu binary not on PATH" "install: brew install opentofu"
else
  # We deliberately pass individual tracked .tf files (rather than
  # `-recursive .`) so gitignored terraform.tfvars whitespace drift
  # in local deployments doesn't fail the check.
  drifted=""
  while IFS= read -r f; do
    if ! tofu fmt -check "$f" >/dev/null 2>&1; then
      drifted="${drifted}${f}"$'\n'
    fi
  done < <(git ls-files -- '*.tf')

  if [[ -z "$drifted" ]]; then
    pass "every tracked .tf file is formatted"
  else
    fail "fmt drift detected" "$(printf 'files:\n%sfix: git ls-files -- '\''*.tf'\'' | xargs tofu fmt' "$drifted")"
  fi
fi

# --- 2. storage knob surface (variables.tf) --------------------------------

heading "2. Storage knob surface (variables.tf)"
for role in "${ROLES[@]}"; do
  vars="vms/${role}/terraform/variables.tf"
  if [[ ! -f "$vars" ]]; then
    fail "${role}: variables.tf missing"
    continue
  fi
  missing=""
  grep -qE '^variable "disk_storage"'     "$vars" || missing="${missing}disk_storage "
  grep -qE '^variable "snippets_storage"' "$vars" || missing="${missing}snippets_storage "
  if [[ -z "$missing" ]]; then
    pass "${role}: variables.tf surfaces disk_storage + snippets_storage"
  else
    fail "${role}: variables.tf missing variable(s): ${missing}" \
         "expose them with the shape used in vms/openbao/terraform/variables.tf (Storage section)"
  fi
done

# --- 3. storage knob wiring (main.tf -> module) ----------------------------

heading "3. Storage knob wiring (main.tf)"
for role in "${ROLES[@]}"; do
  main="vms/${role}/terraform/main.tf"
  if [[ ! -f "$main" ]]; then
    fail "${role}: main.tf missing"
    continue
  fi
  missing=""
  grep -qE 'disk_storage[[:space:]]*=[[:space:]]*var\.disk_storage'         "$main" \
    || missing="${missing}disk_storage "
  grep -qE 'snippets_storage[[:space:]]*=[[:space:]]*var\.snippets_storage' "$main" \
    || missing="${missing}snippets_storage "
  if [[ -z "$missing" ]]; then
    pass "${role}: main.tf wires both storage vars to the shared module"
  else
    fail "${role}: main.tf not wiring: ${missing}" \
         "add the assignment(s) to the module \"${role}\" { ... } block"
  fi
done

# --- 4. dead-code: removed variables ---------------------------------------

heading "4. Dead-code: removed variables"
# encrypted_storage_pool was dropped 2026-05-11 with the rootca LUKS-in-VM
# move. We catch only HCL syntax usages — declaration, var.<name> reference,
# or `<name> =` assignment — so explanatory prose in comments doesn't trip
# the check. Exclude legacy/ subtrees (preserved as historical reference).
#
# Patterns matched:
#   variable "encrypted_storage_pool" {     (declaration)
#   var.encrypted_storage_pool              (reference)
#   <bol-or-non-id-char>encrypted_storage_pool<ws>*=   (assignment)
removed_var_pattern() {
  local v="$1"
  printf '(^|[^A-Za-z0-9_])%s[[:space:]]*=|var\\.%s|variable[[:space:]]+"%s"' "$v" "$v" "$v"
}

hits=""
pat="$(removed_var_pattern encrypted_storage_pool)"
while IFS= read -r line; do
  case "$line" in
    *legacy/*) ;;
    *) hits="${hits}${line}"$'\n' ;;
  esac
done < <(grep -rnE "$pat" vms/ 2>/dev/null || true)

if [[ -z "$hits" ]]; then
  pass "encrypted_storage_pool: no HCL/tfvars references (removed 2026-05-11)"
else
  fail "encrypted_storage_pool: stale references found" "$hits"
fi

# --- 5. canonical file set per role ----------------------------------------

heading "5. Canonical file set per role"
EXPECTED=(main.tf variables.tf versions.tf outputs.tf terraform.tfvars.example terraform.tfvars.tpl)
for role in "${ROLES[@]}"; do
  missing=""
  for f in "${EXPECTED[@]}"; do
    [[ -f "vms/${role}/terraform/${f}" ]] || missing="${missing}${f} "
  done
  if [[ -z "$missing" ]]; then
    pass "${role}: all canonical files present"
  else
    fail "${role}: missing file(s): ${missing}" \
         "see vms/openbao/terraform/ for the canonical shape"
  fi
done

# --- 6. VMID conformance (ADR-0008) ----------------------------------------

heading "6. VMID conformance (ADR-0008)"
for role in "${ROLES[@]}"; do
  main="vms/${role}/terraform/main.tf"
  # Pull the first `vm_id = <integer>` line; tolerates inline // comments.
  vmid="$(awk '
    /vm_id[[:space:]]*=/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+$/) { print $i; exit }
      }
    }' "$main")"
  if [[ -z "$vmid" ]]; then
    fail "${role}: vm_id not found in main.tf"
    continue
  fi
  class="$(role_class "$role")"
  case "$class" in
    service)
      if [[ "$vmid" -ge 8000 && "$vmid" -le 8099 ]]; then
        pass "${role}: vm_id=${vmid} in service range 8000-8099"
      else
        fail "${role}: vm_id=${vmid} OUTSIDE service range 8000-8099 (ADR-0008)"
      fi
      ;;
    workload)
      if [[ "$vmid" -ge 100 && "$vmid" -le 399 ]]; then
        pass "${role}: vm_id=${vmid} in workload range 100-399"
      else
        fail "${role}: vm_id=${vmid} OUTSIDE workload range 100-399 (ADR-0008)"
      fi
      ;;
    unknown)
      printf '  %swarn%s %s: role class unknown — add it to role_class() in this script\n' \
        "$YELLOW" "$RESET" "$role" 1>&2
      ;;
  esac
done

# --- summary ----------------------------------------------------------------

heading "Summary"
printf '  %s%d passed%s, %s%d failed%s\n' "$GREEN" "$PASS" "$RESET" "$RED" "$FAIL" "$RESET"

if [[ "$FAIL" -gt 0 ]]; then
  printf '\n%sFailed checks:%s\n' "$RED" "$RESET"
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi

exit 0
