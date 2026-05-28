#!/usr/bin/env bash
# adb-sideload.sh — ADB sideload transport for Android OTA delivery
#
# Delivers update packages to Android devices via:
#   - adb sideload (recovery mode, A/B and legacy)
#   - adb push + shell install (rooted devices)
#   - adb reboot recovery (to enter sideload mode)
#
# Supports both A/B OTA packages (payload.bin + payload_properties.txt)
# and legacy OTA packages (update.zip with updater-script).
#
# Commands:
#   sideload     --package FILE [--serial SERIAL]
#   push-install --package FILE --dest PATH [--serial SERIAL]
#   reboot-recovery [--serial SERIAL]
#   reboot-sideload [--serial SERIAL]
#   wait-for-device [--serial SERIAL] [--timeout SECS]
#   status       [--serial SERIAL]
#
# Environment:
#   LOTA_ANDROID_SERIAL   adb -s serial (optional)
#   LOTA_ADB_BIN          Path to adb binary (default: adb)

set -euo pipefail

CMD="${1:-}"
shift || true

ADB="${LOTA_ADB_BIN:-adb}"
SERIAL="${LOTA_ANDROID_SERIAL:-}"

info() { echo "[lota-adb] $*"; }
warn() { echo "[lota-adb] WARN: $*" >&2; }
die()  { echo "[lota-adb] ERROR: $*" >&2; exit 1; }

require_adb() {
  command -v "$ADB" &>/dev/null || die "adb not found — install android-tools-adb"
}

run_adb() {
  local args=()
  [[ -n "$SERIAL" ]] && args+=(-s "$SERIAL")
  "$ADB" "${args[@]}" "$@"
}

parse_serial() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --serial) SERIAL="$2"; shift 2 ;;
      *) break ;;
    esac
  done
}

cmd_sideload() {
  local package="" timeout=300
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --package) package="$2"; shift 2 ;;
      --serial)  SERIAL="$2";  shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$package" ]] && die "--package required"
  [[ ! -f "$package" ]] && die "Package not found: $package"
  require_adb

  local pkg_size
  pkg_size=$(stat -c%s "$package")
  info "Sideloading: $package ($pkg_size bytes)"

  # adb sideload blocks until complete or fails
  # Timeout wrapper to prevent indefinite hang
  if command -v timeout &>/dev/null; then
    timeout "$timeout" run_adb sideload "$package"
  else
    run_adb sideload "$package"
  fi

  info "Sideload complete"
}

cmd_push_install() {
  local package="" dest="/data/local/tmp/ota.zip"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --package) package="$2"; shift 2 ;;
      --dest)    dest="$2";    shift 2 ;;
      --serial)  SERIAL="$2";  shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$package" ]] && die "--package required"
  [[ ! -f "$package" ]] && die "Package not found: $package"
  require_adb

  info "Pushing package to device: $dest"
  run_adb push "$package" "$dest"

  info "Triggering install via update_engine_client"
  # A/B devices: use update_engine_client to apply payload.bin
  if run_adb shell "[ -f /system/bin/update_engine_client ]" 2>/dev/null; then
    run_adb shell "update_engine_client --update --follow \
      --payload=file://${dest} \
      --headers=\"$(run_adb shell "cat ${dest%/*}/payload_properties.txt" 2>/dev/null || echo '')\""
  else
    # Legacy: trigger recovery install via BCB
    warn "update_engine_client not found — attempting recovery install"
    run_adb shell "echo 'boot-recovery' > /cache/recovery/command" 2>/dev/null || true
    run_adb shell "echo '--update_package=${dest}' >> /cache/recovery/command" 2>/dev/null || true
    run_adb reboot recovery
  fi
}

cmd_reboot_recovery() {
  parse_serial "$@"
  require_adb
  info "Rebooting to recovery"
  run_adb reboot recovery
}

cmd_reboot_sideload() {
  parse_serial "$@"
  require_adb
  info "Rebooting to sideload mode"
  # Some devices support direct sideload reboot
  if run_adb reboot sideload 2>/dev/null; then
    info "Device rebooting to sideload"
  else
    info "Rebooting to recovery (manual sideload selection required)"
    run_adb reboot recovery
  fi
}

cmd_wait_for_device() {
  local timeout=60
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --serial)  SERIAL="$2";  shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  require_adb
  info "Waiting for device (timeout: ${timeout}s)"
  if command -v timeout &>/dev/null; then
    timeout "$timeout" run_adb wait-for-device
  else
    run_adb wait-for-device
  fi
  info "Device ready"
}

cmd_status() {
  parse_serial "$@"
  require_adb

  echo "=== ADB Device Status ==="
  run_adb devices -l 2>/dev/null || true
  echo ""

  if run_adb get-state 2>/dev/null; then
    local state
    state=$(run_adb get-state 2>/dev/null || echo "unknown")
    echo "State: $state"

    if [[ "$state" == "device" ]]; then
      echo "Serial:  $(run_adb get-serialno 2>/dev/null || echo unknown)"
      echo "Product: $(run_adb shell getprop ro.product.name 2>/dev/null || echo unknown)"
      echo "Build:   $(run_adb shell getprop ro.build.id 2>/dev/null || echo unknown)"
      echo "Slot:    $(run_adb shell getprop ro.boot.slot_suffix 2>/dev/null || echo unknown)"
      echo "Verified boot: $(run_adb shell getprop ro.boot.verifiedbootstate 2>/dev/null || echo unknown)"
    fi
  fi
}

case "$CMD" in
  sideload)         cmd_sideload "$@" ;;
  push-install)     cmd_push_install "$@" ;;
  reboot-recovery)  cmd_reboot_recovery "$@" ;;
  reboot-sideload)  cmd_reboot_sideload "$@" ;;
  wait-for-device)  cmd_wait_for_device "$@" ;;
  status)           cmd_status "$@" ;;
  "")  die "Usage: adb-sideload.sh {sideload|push-install|reboot-recovery|reboot-sideload|wait-for-device|status}" ;;
  *)   die "Unknown command: $CMD" ;;
esac
