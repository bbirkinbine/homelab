#!/usr/bin/env bash
# scripts/hydrate.sh — render a config file from a kp://-templated source.
#
# Usage:
#   scripts/hydrate.sh <role> [--force]                    # vms/<role>/terraform/ shorthand
#   scripts/hydrate.sh <path-to-foo.tpl> [--force]         # explicit template path
#
# The first form keeps the legacy shorthand: resolves to
# vms/<role>/terraform/terraform.tfvars{.tpl}. The second form accepts
# any file ending in `.tpl` and writes the rendered output to the same
# path with `.tpl` stripped.
#
# Replaces kp:// placeholders with values pulled from KeePassXC via
# `keepassxc-cli show`. Writes the result with mode 0600 (gitignored
# is the caller's responsibility — keep `.tpl` out of the placeholder
# value, keep the rendered output in `.gitignore`).
#
# Placeholder grammar:
#   kp://<group-path>/<entry-name>[#<field>]
#
#   group-path   : '/'-separated KeePassXC group names; first component
#                  must NOT have a leading slash. e.g. Homelab/Tofu.
#   entry-name   : title of the entry within that group.
#   field        : optional; defaults to Password. Common alternatives:
#                  UserName, URL, Notes.
#
# Environment:
#   KEEPASSXC_DB — REQUIRED. Path to the .kdbx file. Brian's homelab DB
#                  is typically ~/Documents/KeePassXC/homelab.kdbx; set
#                  KEEPASSXC_DB in your shell profile to avoid pasting
#                  the path every run.
#   KEEPASSXC_KEYFILE — OPTIONAL. Path to a key file (if the DB uses
#                       a key file in addition to or instead of a master
#                       password).
#   KEEPASSXC_YUBIKEY — OPTIONAL. YubiKey HMAC-SHA1 challenge-response
#                       slot, e.g. "2" or "2:1234567" to disambiguate by
#                       serial when multiple YubiKeys are plugged in.
#                       The key will blink for a touch once per lookup.
#
# Idempotency: if terraform.tfvars already exists and is newer than the
# .tpl, hydrate is a no-op. Pass --force to rehydrate anyway.
#
# This script prompts for the DB master password ONCE (or the YubiKey
# touch, if the DB is challenge-response unlocked), then reuses the
# unlocked DB for all subsequent lookups via keepassxc-cli's stdin
# pattern.

set -euo pipefail

ARG="${1:-}"
FORCE=0
shift || true
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    *) echo "ERROR: unknown arg '$arg'" >&2; exit 64 ;;
  esac
done

if [[ -z "$ARG" ]]; then
  echo "Usage: $0 <role>|<path-to-foo.tpl> [--force]" >&2
  exit 64
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Two input forms:
#   - explicit path ending in `.tpl` (anywhere under the repo)
#   - shorthand <role>, resolves to vms/<role>/terraform/terraform.tfvars.tpl
# The output path is always the input path with `.tpl` stripped.
if [[ "$ARG" == *.tpl ]]; then
  # Absolute path passed through; relative path resolved against PWD.
  if [[ "$ARG" = /* ]]; then
    TPL="$ARG"
  else
    TPL="$(cd "$(dirname "$ARG")" 2>/dev/null && pwd)/$(basename "$ARG")"
    if [[ -z "$TPL" || ! -e "$(dirname "$TPL")" ]]; then
      echo "ERROR: cannot resolve directory for $ARG" >&2
      exit 65
    fi
  fi
  OUT="${TPL%.tpl}"
else
  TPL="$REPO_ROOT/vms/$ARG/terraform/terraform.tfvars.tpl"
  OUT="$REPO_ROOT/vms/$ARG/terraform/terraform.tfvars"
fi

if [[ ! -f "$TPL" ]]; then
  echo "ERROR: $TPL not found." >&2
  echo "       Either create one with kp:// placeholders, or skip hydrate" >&2
  echo "       and create $OUT manually from the .example sibling file." >&2
  exit 65
fi

# Skip if already up-to-date.
if [[ -f "$OUT" && $FORCE -eq 0 && "$OUT" -nt "$TPL" ]]; then
  echo "==> $OUT is newer than $TPL; skipping (use --force to rehydrate)."
  exit 0
fi

# Verify tooling + DB env.
if ! command -v keepassxc-cli >/dev/null 2>&1; then
  echo "ERROR: keepassxc-cli not on PATH." >&2
  echo "       brew install keepassxc   (or your distro's equivalent)" >&2
  exit 66
fi

if [[ -z "${KEEPASSXC_DB:-}" ]]; then
  echo "ERROR: KEEPASSXC_DB environment variable not set." >&2
  echo "       export KEEPASSXC_DB=~/path/to/homelab.kdbx" >&2
  echo "       (Add to your shell profile so it's persistent.)" >&2
  exit 67
fi

if [[ ! -f "$KEEPASSXC_DB" ]]; then
  echo "ERROR: KEEPASSXC_DB=$KEEPASSXC_DB does not exist." >&2
  exit 68
fi

KP_ARGS=(-q)
if [[ -n "${KEEPASSXC_KEYFILE:-}" ]]; then
  KP_ARGS+=(--key-file "$KEEPASSXC_KEYFILE")
fi
if [[ -n "${KEEPASSXC_YUBIKEY:-}" ]]; then
  KP_ARGS+=(--yubikey "$KEEPASSXC_YUBIKEY")
fi

# Prompt for the master password once. We read it here and pipe to
# keepassxc-cli on stdin for each lookup; KeePassXC has no
# session/socket mode in the CLI, so we cache the password in this
# process's memory rather than re-prompting per entry.
echo -n "KeePassXC master password for $KEEPASSXC_DB: " >&2
read -rs KP_PASSWORD
echo >&2

if [[ -z "$KP_PASSWORD" ]]; then
  echo "ERROR: empty password." >&2
  exit 69
fi

# kp_lookup <group-path>/<entry-name>[#<field>]  →  prints the value.
# Uses `keepassxc-cli show -a <field>` to fetch a single attribute.
# Falls back to Password if no #field is specified.
kp_lookup() {
  local spec="$1"
  local path field

  if [[ "$spec" == *"#"* ]]; then
    path="${spec%%#*}"
    field="${spec#*#}"
  else
    path="$spec"
    field="Password"
  fi

  # keepassxc-cli expects the path with a leading slash.
  echo -n "$KP_PASSWORD" | keepassxc-cli show "${KP_ARGS[@]}" \
    -s -a "$field" "$KEEPASSXC_DB" "/$path"
}

# Old-school `banner`-style attention grab printed BEFORE each
# keepassxc-cli invocation when the DB is YubiKey-protected. Each
# invocation re-issues the HMAC-SHA1 challenge, so the user has to
# physically touch the key — easy to miss the blink while looking at
# something else, hence the oversized prompt.
yubikey_banner() {
  local count="$1" total="$2" spec="$3"
  cat >&2 <<'BANNER'

     _____ ___  _   _  ____ _   _   _  _________   __
    |_   _/ _ \| | | |/ ___| | | | | |/ / ____\ \ / /
      | || | | | | | | |   | |_| | | ' /|  _|  \ V /
      | || |_| | |_| | |___|  _  | | . \| |___  | |
      |_| \___/ \___/ \____|_| |_| |_|\_\_____| |_|

    >>>  LOOK FOR THE BLINKING LIGHT  <<<

BANNER
  printf '    [%d/%d]  %s\n\n' "$count" "$total" "$spec" >&2
}

# Pre-count kp:// references (skipping comments) so we can show
# touch-count progress. With a YubiKey-locked DB, each keepassxc-cli
# invocation re-issues the HMAC challenge — N references = N touches.
TOTAL_REFS="$(grep -v '^[[:space:]]*#' "$TPL" | grep -oE 'kp://[^[:space:]"'"'"')]+' | wc -l | tr -d ' ')"

if [[ -n "${KEEPASSXC_YUBIKEY:-}" ]]; then
  echo "==> rendering $OUT from $TPL  ($TOTAL_REFS kp:// refs — YubiKey will blink before each)"
else
  echo "==> rendering $OUT from $TPL  ($TOTAL_REFS kp:// refs)"
fi
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Pull every kp:// reference, look it up, and stream-substitute.
# We process line-by-line so a single failed lookup gives a clear
# error pointing at the offending line.
LINE_NO=0
REF_COUNT=0
while IFS= read -r line || [[ -n "$line" ]]; do
  LINE_NO=$((LINE_NO + 1))
  # Skip HCL comments — kp:// inside a `#` line is documentation, not a placeholder.
  if [[ "$line" =~ ^[[:space:]]*# ]]; then
    printf '%s\n' "$line" >> "$TMP"
    continue
  fi
  while [[ "$line" =~ kp://([^[:space:]\"\'\)]+) ]]; do
    SPEC="${BASH_REMATCH[1]}"
    REF_COUNT=$((REF_COUNT + 1))
    if [[ -n "${KEEPASSXC_YUBIKEY:-}" ]]; then
      yubikey_banner "$REF_COUNT" "$TOTAL_REFS" "kp://$SPEC"
    else
      echo "    [$REF_COUNT/$TOTAL_REFS] kp://$SPEC" >&2
    fi
    KP_ERR="$(mktemp)"
    if ! VALUE="$(kp_lookup "$SPEC" 2>"$KP_ERR")"; then
      echo "ERROR: line $LINE_NO: could not resolve kp://$SPEC" >&2
      echo "       Check the entry exists in $KEEPASSXC_DB and the field name is correct." >&2
      if [[ -s "$KP_ERR" ]]; then
        echo "       keepassxc-cli said:" >&2
        sed 's/^/         /' "$KP_ERR" >&2
      fi
      rm -f "$KP_ERR"
      exit 70
    fi
    rm -f "$KP_ERR"
    # Escape sed metacharacters in the value so the replacement is literal.
    ESCAPED="$(printf '%s' "$VALUE" | sed -e 's/[\/&|]/\\&/g')"
    line="$(printf '%s' "$line" | sed -E "s|kp://${SPEC//|/\\|}|$ESCAPED|")"
  done
  printf '%s\n' "$line" >> "$TMP"
done < "$TPL"

install -m 600 "$TMP" "$OUT"
echo "==> wrote $OUT (mode 0600)"
