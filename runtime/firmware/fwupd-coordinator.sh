#!/usr/bin/env bash
# fwupd-coordinator.sh — coordinate fwupd firmware updates with OS updates
#
# Called by the update engine before/after OS updates based on
# config/system.toml [firmware].policy:
#
#   before_os    Apply firmware updates first, then OS update
#   after_os     Apply OS update first, then firmware updates
#   independent  Firmware updates run on their own schedule
#   disabled     Skip firmware update coordination entirely
#
# Also handles boot-time coordination: fwupd stages EFI capsule updates
# for next boot. The boot confirmation layer must not mark a boot "good"
# until pending capsule updates have been applied.
#
# Usage:
#   fwupd-coordinator.sh check          Check for pending firmware updates
#   fwupd-coordinator.sh apply          Apply pending firmware updates
#   fwupd-coordinator.sh pre-os-update  Run before OS update (per policy)
#   fwupd-coordinator.sh post-os-update Run after OS update (per policy)
#   fwupd-coordinator.sh boot-check     Check for pending capsules at boot time
#   fwupd-coordinator.sh status         Show firmware update status

set -euo pipefail

FWUPD_CMD="${FWUPD_CMD:-fwupdmgr}"
POLICY="${LOTA_FIRMWARE_POLICY:-before_os}"
CONFIG_FILE="${LOTA_CONFIG:-/etc/lota/system.toml}"

info()  { echo "[lota-firmware] $*"; }
warn()  { echo "[lota-firmware] WARN: $*" >&2; }
die()   { echo "[lota-firmware] ERROR: $*" >&2; exit 1; }

require_fwupd() {
  command -v "$FWUPD_CMD" &>/dev/null \
    || { warn "fwupd not found — firmware update coordination disabled"; return 1; }
}

# Read policy from config file if available
read_policy() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local p
    p=$(grep -A5 '^\[firmware\]' "$CONFIG_FILE" 2>/dev/null \
        | grep 'policy' | head -1 \
        | sed 's/.*=\s*"\(.*\)".*/\1/')
    [[ -n "$p" ]] && echo "$p" && return
  fi
  echo "$POLICY"
}

# Check if fwupd has pending updates
has_pending_updates() {
  require_fwupd || return 1
  "$FWUPD_CMD" get-updates --json 2>/dev/null \
    | grep -q '"Flags"' && return 0
  return 1
}

# Check for pending EFI capsule updates (staged for next boot)
has_pending_capsules() {
  # fwupd stages capsules in /boot/efi/EFI/fwupd/
  local capsule_dir="/boot/efi/EFI/fwupd"
  [[ -d "$capsule_dir" ]] && [[ -n "$(ls "$capsule_dir"/*.cap 2>/dev/null)" ]]
}

cmd_check() {
  require_fwupd || exit 0
  info "Refreshing firmware metadata from LVFS"
  "$FWUPD_CMD" refresh --force 2>/dev/null \
    || warn "Metadata refresh failed — using cached data"

  if has_pending_updates; then
    info "Firmware updates available:"
    "$FWUPD_CMD" get-updates 2>/dev/null
    return 0
  else
    info "No firmware updates available"
    return 1
  fi
}

cmd_apply() {
  require_fwupd || exit 0

  if ! has_pending_updates; then
    info "No firmware updates to apply"
    return 0
  fi

  info "Applying firmware updates"
  "$FWUPD_CMD" update --no-reboot-check 2>/dev/null || {
    local rc=$?
    warn "fwupdmgr update exited with code $rc"
    return $rc
  }
  info "Firmware updates applied — may require reboot to activate"
}

cmd_pre_os_update() {
  local policy
  policy=$(read_policy)
  info "Pre-OS-update firmware check (policy: $policy)"

  case "$policy" in
    before_os)
      cmd_check && cmd_apply || true
      ;;
    after_os|independent|disabled)
      info "Skipping pre-OS firmware update (policy: $policy)"
      ;;
    *)
      warn "Unknown firmware policy: $policy"
      ;;
  esac
}

cmd_post_os_update() {
  local policy
  policy=$(read_policy)
  info "Post-OS-update firmware check (policy: $policy)"

  case "$policy" in
    after_os)
      cmd_check && cmd_apply || true
      ;;
    before_os|independent|disabled)
      info "Skipping post-OS firmware update (policy: $policy)"
      ;;
  esac
}

cmd_boot_check() {
  # Called at boot time before confirming a good boot.
  # If there are pending EFI capsule updates, we should NOT mark the boot
  # as good yet — the capsule needs to apply first.
  if has_pending_capsules; then
    warn "Pending EFI firmware capsules detected — boot confirmation deferred"
    warn "Capsules will apply on next reboot"
    # Return non-zero to signal to confirm-boot.sh that it should wait
    return 1
  fi

  # Check if fwupd itself reports pending updates that require reboot
  if require_fwupd 2>/dev/null; then
    local pending
    pending=$("$FWUPD_CMD" get-updates --json 2>/dev/null \
      | grep -c '"NeedsReboot".*true' || echo 0)
    if [[ "$pending" -gt 0 ]]; then
      warn "$pending firmware update(s) require reboot — boot confirmation deferred"
      return 1
    fi
  fi

  info "No pending firmware capsules — boot confirmation can proceed"
  return 0
}

cmd_status() {
  echo "=== lota firmware status ==="
  echo "Policy: $(read_policy)"
  echo ""

  if require_fwupd 2>/dev/null; then
    echo "=== fwupd devices ==="
    "$FWUPD_CMD" get-devices 2>/dev/null || echo "(none)"
    echo ""
    echo "=== Pending firmware updates ==="
    "$FWUPD_CMD" get-updates 2>/dev/null || echo "(none)"
    echo ""
    echo "=== Update history ==="
    "$FWUPD_CMD" get-history 2>/dev/null || echo "(none)"
  else
    echo "fwupd not available"
  fi

  echo ""
  echo "=== Pending EFI capsules ==="
  if has_pending_capsules; then
    ls /boot/efi/EFI/fwupd/*.cap 2>/dev/null
  else
    echo "(none)"
  fi
}

[[ $# -eq 0 ]] && { echo "Usage: fwupd-coordinator.sh <check|apply|pre-os-update|post-os-update|boot-check|status>"; exit 0; }
CMD="$1"; shift
case "$CMD" in
  check)           cmd_check ;;
  apply)           cmd_apply ;;
  pre-os-update)   cmd_pre_os_update ;;
  post-os-update)  cmd_post_os_update ;;
  boot-check)      cmd_boot_check ;;
  status)          cmd_status ;;
  *) die "Unknown command: $CMD" ;;
esac
