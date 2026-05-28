#!/usr/bin/env bash
# hook-runner.sh — pre/post update hook execution engine
#
# Runs hook scripts from /etc/lota/hooks.d/ at defined lifecycle points.
# Hooks are shell scripts or executables named {phase}-{priority}-{name}.sh
#
# Phases:
#   pre-download      Before downloading the update payload
#   post-download     After download, before verification
#   pre-verify        Before signature verification
#   post-verify       After verification, before install
#   pre-install       Before writing to the target slot
#   post-install      After writing, before boot confirmation
#   pre-reboot        Just before rebooting into the new slot
#   post-reboot       After first boot into the new slot (confirm-boot calls this)
#   rollback          When rolling back to the previous slot
#
# Hook environment variables (available to all hooks):
#   LOTA_PHASE        Current lifecycle phase
#   LOTA_SLOT         Target slot (a or b)
#   LOTA_PAYLOAD      Path to the update payload
#   LOTA_VERSION      Update version string
#   LOTA_CHANNEL      Update channel
#   LOTA_FILESYSTEM   Target filesystem type
#   LOTA_DISTRO       Target distro
#   LOTA_ARCH         Target architecture
#
# Exit codes from hooks:
#   0    Success — continue
#   1    Failure — abort update (for pre-* phases) or warn (for post-* phases)
#   2    Skip — skip this hook, continue with others
#   75   Retry — retry this hook (up to LOTA_HOOK_RETRIES times)
#
# Usage:
#   hook-runner.sh --phase PHASE [--slot SLOT] [--payload PATH] [--version VER]

set -euo pipefail

PHASE=""
SLOT="${LOTA_SLOT:-b}"
PAYLOAD="${LOTA_PAYLOAD:-}"
VERSION="${LOTA_VERSION:-unknown}"
CHANNEL="${LOTA_CHANNEL:-stable}"
FILESYSTEM="${LOTA_FILESYSTEM:-}"
DISTRO="${LOTA_DISTRO:-}"
ARCH="${LOTA_ARCH:-}"
HOOK_DIR="${LOTA_HOOK_DIR:-/etc/lota/hooks.d}"
HOOK_TIMEOUT="${LOTA_HOOK_TIMEOUT:-300}"
HOOK_RETRIES="${LOTA_HOOK_RETRIES:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)      PHASE="$2";      shift 2 ;;
    --slot)       SLOT="$2";       shift 2 ;;
    --payload)    PAYLOAD="$2";    shift 2 ;;
    --version)    VERSION="$2";    shift 2 ;;
    --channel)    CHANNEL="$2";    shift 2 ;;
    --filesystem) FILESYSTEM="$2"; shift 2 ;;
    --distro)     DISTRO="$2";     shift 2 ;;
    --arch)       ARCH="$2";       shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PHASE" ]] && { echo "ERROR: --phase required" >&2; exit 1; }

info()  { echo "[lota-hooks] $*"; }
warn()  { echo "[lota-hooks] WARN: $*" >&2; }
die()   { echo "[lota-hooks] ERROR: $*" >&2; exit 1; }

export LOTA_PHASE="$PHASE"
export LOTA_SLOT="$SLOT"
export LOTA_PAYLOAD="$PAYLOAD"
export LOTA_VERSION="$VERSION"
export LOTA_CHANNEL="$CHANNEL"
export LOTA_FILESYSTEM="$FILESYSTEM"
export LOTA_DISTRO="$DISTRO"
export LOTA_ARCH="$ARCH"

[[ ! -d "$HOOK_DIR" ]] && { info "No hook directory: $HOOK_DIR"; exit 0; }

# Collect hooks for this phase, sorted by priority (numeric prefix)
mapfile -t HOOKS < <(
  find "$HOOK_DIR" -maxdepth 1 \
    \( -name "${PHASE}-*.sh" -o -name "${PHASE}-*" \) \
    -type f -executable \
    | sort
)

if [[ ${#HOOKS[@]} -eq 0 ]]; then
  info "No hooks for phase: $PHASE"
  exit 0
fi

info "Running ${#HOOKS[@]} hook(s) for phase: $PHASE"

failed=0
for hook in "${HOOKS[@]}"; do
  name=$(basename "$hook")
  info "  → $name"

  attempt=0
  while [[ $attempt -lt $HOOK_RETRIES ]]; do
    attempt=$((attempt + 1))

    set +e
    timeout "$HOOK_TIMEOUT" bash "$hook"
    rc=$?
    set -e

    case $rc in
      0)
        info "    ✓ $name"
        break
        ;;
      2)
        info "    ~ $name (skipped)"
        break
        ;;
      75)
        warn "    ↺ $name (retry $attempt/$HOOK_RETRIES)"
        sleep 2
        ;;
      124)
        warn "    ✗ $name (timeout after ${HOOK_TIMEOUT}s)"
        # Treat timeout as failure for pre-* phases
        [[ "$PHASE" == pre-* ]] && failed=$((failed + 1))
        break
        ;;
      *)
        warn "    ✗ $name (exit $rc)"
        [[ "$PHASE" == pre-* ]] && failed=$((failed + 1))
        break
        ;;
    esac
  done
done

if [[ $failed -gt 0 ]]; then
  die "$failed hook(s) failed in phase $PHASE — aborting update"
fi

info "Phase $PHASE complete"
