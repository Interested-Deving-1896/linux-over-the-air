#!/usr/bin/env bash
# fastboot-flash.sh — Fastboot and fastbootd partition flashing for OTA
#
# Handles the full fastboot transport layer for Android OTA delivery:
#   - Bootloader-mode fastboot (physical partitions: boot, vbmeta, recovery)
#   - Fastbootd / userspace fastboot (logical partitions: system, vendor, product)
#   - GSI flashing workflow
#   - Slot-aware flashing (always targets inactive slot)
#
# Commands:
#   flash-boot      --image FILE [--slot SLOT]
#   flash-system    --image FILE [--slot SLOT]
#   flash-vendor    --image FILE [--slot SLOT]
#   flash-vbmeta    --image FILE [--slot SLOT] [--disable-verification]
#   flash-gsi       --system FILE [--vbmeta FILE] [--wipe]
#   flash-all       --boot FILE --system FILE --vendor FILE --vbmeta FILE [--slot SLOT]
#   set-active      --slot SLOT
#   reboot-fastbootd
#   reboot-bootloader
#   status
#
# Environment:
#   LOTA_ANDROID_SERIAL   fastboot -s serial (optional)
#   LOTA_FASTBOOT_BIN     Path to fastboot binary (default: fastboot)

set -euo pipefail

CMD="${1:-}"
shift || true

FASTBOOT="${LOTA_FASTBOOT_BIN:-fastboot}"
SERIAL="${LOTA_ANDROID_SERIAL:-}"

info() { echo "[lota-fastboot] $*"; }
warn() { echo "[lota-fastboot] WARN: $*" >&2; }
die()  { echo "[lota-fastboot] ERROR: $*" >&2; exit 1; }

require_fastboot() {
  command -v "$FASTBOOT" &>/dev/null || die "fastboot not found — install android-tools-fastboot"
}

run_fastboot() {
  local args=()
  [[ -n "$SERIAL" ]] && args+=(-s "$SERIAL")
  "$FASTBOOT" "${args[@]}" "$@"
}

# Detect if device is in fastbootd (userspace) mode
is_fastbootd() {
  local result
  result=$(run_fastboot getvar is-userspace 2>&1 | grep "is-userspace:" | awk '{print $2}' || echo "no")
  [[ "$result" == "yes" ]]
}

# Get current active slot from fastboot
get_current_slot() {
  run_fastboot getvar current-slot 2>&1 | grep "current-slot:" | awk '{print $2}' || echo "a"
}

# Get inactive slot
get_inactive_slot() {
  local current
  current=$(get_current_slot)
  case "$current" in
    a) echo "b" ;;
    b) echo "a" ;;
    *) echo "b" ;;
  esac
}

# Flash a partition, entering fastbootd first if it's a logical partition
flash_partition() {
  local partition="$1"
  local image="$2"
  local need_fastbootd="${3:-false}"

  [[ ! -f "$image" ]] && die "Image not found: $image"

  if [[ "$need_fastbootd" == "true" ]] && ! is_fastbootd; then
    info "Rebooting to fastbootd for logical partition: $partition"
    run_fastboot reboot fastboot
    sleep 5
  fi

  info "Flashing $partition: $image ($(stat -c%s "$image") bytes)"
  run_fastboot flash "$partition" "$image"
  info "Flashed: $partition"
}

cmd_flash_boot() {
  local image="" slot=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image) image="$2"; shift 2 ;;
      --slot)  slot="$2";  shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$image" ]] && die "--image required"
  require_fastboot
  slot="${slot:-$(get_inactive_slot)}"
  flash_partition "boot_${slot}" "$image" false
}

cmd_flash_system() {
  local image="" slot=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image) image="$2"; shift 2 ;;
      --slot)  slot="$2";  shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$image" ]] && die "--image required"
  require_fastboot
  slot="${slot:-$(get_inactive_slot)}"
  # system is a logical partition — requires fastbootd
  flash_partition "system_${slot}" "$image" true
}

cmd_flash_vendor() {
  local image="" slot=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image) image="$2"; shift 2 ;;
      --slot)  slot="$2";  shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$image" ]] && die "--image required"
  require_fastboot
  slot="${slot:-$(get_inactive_slot)}"
  flash_partition "vendor_${slot}" "$image" true
}

cmd_flash_vbmeta() {
  local image="" slot="" disable_verification=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)                image="$2"; shift 2 ;;
      --slot)                 slot="$2";  shift 2 ;;
      --disable-verification) disable_verification=true; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$image" ]] && die "--image required"
  require_fastboot
  slot="${slot:-$(get_inactive_slot)}"

  if [[ "$disable_verification" == "true" ]]; then
    info "Flashing vbmeta_${slot} with --disable-verification"
    run_fastboot --disable-verification flash "vbmeta_${slot}" "$image"
  else
    flash_partition "vbmeta_${slot}" "$image" false
  fi
}

cmd_flash_gsi() {
  local system="" vbmeta="" wipe=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --system) system="$2"; shift 2 ;;
      --vbmeta) vbmeta="$2"; shift 2 ;;
      --wipe)   wipe=true;   shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$system" ]] && die "--system required"
  require_fastboot

  info "GSI flash workflow"

  # GSI requires fastbootd for system partition
  if ! is_fastbootd; then
    info "Rebooting to fastbootd"
    run_fastboot reboot fastboot
    sleep 5
  fi

  info "Erasing system partition"
  run_fastboot erase system

  info "Flashing GSI system image"
  run_fastboot flash system "$system"

  if [[ -n "$vbmeta" ]]; then
    info "Flashing vbmeta (verification disabled for GSI)"
    run_fastboot --disable-verification flash vbmeta "$vbmeta"
  else
    warn "No --vbmeta provided — device may fail AVB verification"
  fi

  if [[ "$wipe" == "true" ]]; then
    info "Wiping userdata"
    run_fastboot -w
  fi

  info "GSI flash complete — rebooting"
  run_fastboot reboot
}

cmd_flash_all() {
  local boot="" system="" vendor="" vbmeta="" slot=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --boot)   boot="$2";   shift 2 ;;
      --system) system="$2"; shift 2 ;;
      --vendor) vendor="$2"; shift 2 ;;
      --vbmeta) vbmeta="$2"; shift 2 ;;
      --slot)   slot="$2";   shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  require_fastboot
  slot="${slot:-$(get_inactive_slot)}"
  info "Flashing all partitions to slot $slot"

  [[ -n "$boot" ]]   && cmd_flash_boot   --image "$boot"   --slot "$slot"
  [[ -n "$vbmeta" ]] && cmd_flash_vbmeta --image "$vbmeta" --slot "$slot"
  [[ -n "$system" ]] && cmd_flash_system --image "$system" --slot "$slot"
  [[ -n "$vendor" ]] && cmd_flash_vendor --image "$vendor" --slot "$slot"

  info "Setting active slot: $slot"
  run_fastboot set_active "$slot"
  info "All partitions flashed to slot $slot"
}

cmd_set_active() {
  local slot="${1:-}"
  [[ -z "$slot" ]] && die "Usage: set-active SLOT"
  require_fastboot
  info "Setting active slot: $slot"
  run_fastboot set_active "$slot"
}

cmd_reboot_fastbootd() {
  require_fastboot
  info "Rebooting to fastbootd (userspace fastboot)"
  run_fastboot reboot fastboot
}

cmd_reboot_bootloader() {
  require_fastboot
  info "Rebooting to bootloader"
  run_fastboot reboot-bootloader
}

cmd_status() {
  require_fastboot
  echo "=== Fastboot Device Status ==="
  run_fastboot getvar all 2>&1 | grep -E "(current-slot|is-userspace|slot-count|slot-suffixes|super-partition-name|version)" || true
  echo ""
  echo "Current slot:  $(get_current_slot)"
  echo "Inactive slot: $(get_inactive_slot)"
  echo "Mode:          $(is_fastbootd && echo fastbootd || echo bootloader)"
}

case "$CMD" in
  flash-boot)        cmd_flash_boot "$@" ;;
  flash-system)      cmd_flash_system "$@" ;;
  flash-vendor)      cmd_flash_vendor "$@" ;;
  flash-vbmeta)      cmd_flash_vbmeta "$@" ;;
  flash-gsi)         cmd_flash_gsi "$@" ;;
  flash-all)         cmd_flash_all "$@" ;;
  set-active)        cmd_set_active "$@" ;;
  reboot-fastbootd)  cmd_reboot_fastbootd ;;
  reboot-bootloader) cmd_reboot_bootloader ;;
  status)            cmd_status ;;
  "")  die "Usage: fastboot-flash.sh {flash-boot|flash-system|flash-vendor|flash-vbmeta|flash-gsi|flash-all|set-active|reboot-fastbootd|reboot-bootloader|status}" ;;
  *)   die "Unknown command: $CMD" ;;
esac
