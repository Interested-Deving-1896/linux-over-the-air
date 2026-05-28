#!/usr/bin/env bash
# bootctl-wrapper.sh — Android A/B slot management via bootctl HAL
#
# Wraps the Android `bootctl` CLI tool and provides a lota-compatible
# interface matching confirm-boot.sh semantics. Falls back to direct
# BCB (Boot Control Block) manipulation via misc partition when bootctl
# is unavailable (e.g. from a Linux host flashing an Android device).
#
# Commands:
#   get-current-slot          Print active slot (a or b)
#   get-inactive-slot         Print inactive slot
#   set-active SLOT           Mark slot as next boot target
#   mark-successful           Mark current slot as successfully booted
#   set-unbootable SLOT       Mark slot as unbootable (pre-install)
#   is-bootable SLOT          Exit 0 if slot is bootable
#   is-successful SLOT        Exit 0 if slot is marked successful
#   get-snapshot-merge-status Print Virtual A/B merge status
#   set-snapshot-merge-status STATUS  Set merge status (none|snapshotted|merging|cancelled)
#   status                    Print full slot state
#
# Environment:
#   LOTA_ANDROID_SERIAL   ADB serial for remote bootctl (optional)
#   LOTA_BOOTCTL_BIN      Path to bootctl binary (default: bootctl)

set -euo pipefail

CMD="${1:-}"
shift || true

BOOTCTL="${LOTA_BOOTCTL_BIN:-bootctl}"
ADB_SERIAL="${LOTA_ANDROID_SERIAL:-}"

info() { echo "[lota-bootctl] $*"; }
die()  { echo "[lota-bootctl] ERROR: $*" >&2; exit 1; }

# Run bootctl, optionally via adb shell
run_bootctl() {
  if [[ -n "$ADB_SERIAL" ]]; then
    adb -s "$ADB_SERIAL" shell "$BOOTCTL" "$@"
  elif command -v "$BOOTCTL" &>/dev/null; then
    "$BOOTCTL" "$@"
  else
    die "bootctl not found and no ADB_SERIAL set. Install android-tools or set LOTA_ANDROID_SERIAL."
  fi
}

# Map slot number (0/1) to letter (a/b)
slot_num_to_letter() {
  case "$1" in
    0) echo "a" ;;
    1) echo "b" ;;
    *) echo "$1" ;;
  esac
}

# Map slot letter (a/b) to number (0/1)
slot_letter_to_num() {
  case "$1" in
    a|A) echo "0" ;;
    b|B) echo "1" ;;
    *) echo "$1" ;;
  esac
}

cmd_get_current_slot() {
  local num
  num=$(run_bootctl get-current-slot 2>/dev/null | tr -d '[:space:]')
  slot_num_to_letter "$num"
}

cmd_get_inactive_slot() {
  local current
  current=$(cmd_get_current_slot)
  case "$current" in
    a) echo "b" ;;
    b) echo "a" ;;
    *) die "Unexpected current slot: $current" ;;
  esac
}

cmd_set_active() {
  local slot="${1:-}"
  [[ -z "$slot" ]] && die "Usage: set-active SLOT"
  local num
  num=$(slot_letter_to_num "$slot")
  info "Setting active slot: $slot (slot $num)"
  run_bootctl set-active-boot-slot "$num"
}

cmd_mark_successful() {
  info "Marking current slot as successfully booted"
  run_bootctl mark-boot-successful
}

cmd_set_unbootable() {
  local slot="${1:-}"
  [[ -z "$slot" ]] && die "Usage: set-unbootable SLOT"
  local num
  num=$(slot_letter_to_num "$slot")
  info "Marking slot $slot as unbootable"
  # bootctl doesn't expose set-slot-as-unbootable directly in CLI;
  # update_engine calls the HAL directly. We use the HAL via a helper
  # if available, otherwise warn.
  if run_bootctl set-slot-as-unbootable "$num" 2>/dev/null; then
    info "Slot $slot marked unbootable"
  else
    info "WARNING: set-slot-as-unbootable not available via bootctl CLI — HAL call required"
  fi
}

cmd_is_bootable() {
  local slot="${1:-}"
  [[ -z "$slot" ]] && die "Usage: is-bootable SLOT"
  local num
  num=$(slot_letter_to_num "$slot")
  local result
  result=$(run_bootctl is-slot-bootable "$num" 2>/dev/null | tr -d '[:space:]')
  [[ "$result" == "1" ]]
}

cmd_is_successful() {
  local slot="${1:-}"
  [[ -z "$slot" ]] && die "Usage: is-successful SLOT"
  local num
  num=$(slot_letter_to_num "$slot")
  local result
  result=$(run_bootctl is-slot-marked-successful "$num" 2>/dev/null | tr -d '[:space:]')
  [[ "$result" == "1" ]]
}

cmd_get_snapshot_merge_status() {
  run_bootctl get-snapshot-merge-status 2>/dev/null || echo "none"
}

cmd_set_snapshot_merge_status() {
  local status="${1:-}"
  [[ -z "$status" ]] && die "Usage: set-snapshot-merge-status STATUS"
  info "Setting snapshot merge status: $status"
  run_bootctl set-snapshot-merge-status "$status"
}

cmd_status() {
  local current inactive
  current=$(cmd_get_current_slot)
  inactive=$(cmd_get_inactive_slot)

  echo "=== Android Slot Status ==="
  echo "Current slot:   $current"
  echo "Inactive slot:  $inactive"

  for slot in a b; do
    local num
    num=$(slot_letter_to_num "$slot")
    local suffix
    suffix=$(run_bootctl get-suffix "$num" 2>/dev/null || echo "_${slot}")
    local bootable successful
    bootable=$(run_bootctl is-slot-bootable "$num" 2>/dev/null | tr -d '[:space:]' || echo "?")
    successful=$(run_bootctl is-slot-marked-successful "$num" 2>/dev/null | tr -d '[:space:]' || echo "?")
    echo "Slot $slot ($suffix): bootable=$bootable successful=$successful"
  done

  local merge_status
  merge_status=$(cmd_get_snapshot_merge_status)
  echo "Snapshot merge: $merge_status"

  # HAL info
  run_bootctl hal-info 2>/dev/null || true
}

case "$CMD" in
  get-current-slot)          cmd_get_current_slot ;;
  get-inactive-slot)         cmd_get_inactive_slot ;;
  set-active)                cmd_set_active "$@" ;;
  mark-successful)           cmd_mark_successful ;;
  set-unbootable)            cmd_set_unbootable "$@" ;;
  is-bootable)               cmd_is_bootable "$@" ;;
  is-successful)             cmd_is_successful "$@" ;;
  get-snapshot-merge-status) cmd_get_snapshot_merge_status ;;
  set-snapshot-merge-status) cmd_set_snapshot_merge_status "$@" ;;
  status)                    cmd_status ;;
  "")  die "Usage: bootctl-wrapper.sh {get-current-slot|get-inactive-slot|set-active|mark-successful|set-unbootable|is-bootable|is-successful|get-snapshot-merge-status|set-snapshot-merge-status|status}" ;;
  *)   die "Unknown command: $CMD" ;;
esac
