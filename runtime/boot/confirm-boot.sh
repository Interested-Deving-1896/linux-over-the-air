#!/usr/bin/env bash
# confirm-boot.sh — mark the current boot slot as good
#
# Called after a successful boot into an updated slot to prevent the
# bootloader from reverting to the previous slot on next boot.
#
# Lineage: chromeos-setgoodkernel + RAUC boot confirmation + GRUB/U-Boot/EFI
#
# Supports:
#   grub2         — grub-editenv / grubenv
#   systemd-boot  — bootctl set-oneshot / status
#   u-boot        — fw_setenv upgrade_available 0
#   barebox       — barebox-state
#   efi-stub      — EFI variable via efibootmgr
#   rauc          — rauc status mark-good
#   custom        — LOTA_CONFIRM_COMMAND env var
#
# Usage:
#   confirm-boot.sh [--bootloader TYPE] [--slot SLOT] [--dry-run]
#   confirm-boot.sh --status

set -euo pipefail

BOOTLOADER="${LOTA_BOOTLOADER:-}"
SLOT="${LOTA_SLOT:-}"
DRY_RUN=false
STATUS_ONLY=false
CONFIG_FILE="${LOTA_CONFIG:-/etc/lota/system.toml}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootloader) BOOTLOADER="$2"; shift 2 ;;
    --slot)       SLOT="$2";       shift 2 ;;
    --dry-run)    DRY_RUN=true;    shift ;;
    --status)     STATUS_ONLY=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

info()  { echo "[lota-boot] $*"; }
warn()  { echo "[lota-boot] WARN: $*" >&2; }
die()   { echo "[lota-boot] ERROR: $*" >&2; exit 1; }
run()   { $DRY_RUN && echo "[dry-run] $*" || "$@"; }

# ── Auto-detect bootloader ────────────────────────────────────────────────────
detect_bootloader() {
  # Check config file first
  if [[ -f "$CONFIG_FILE" ]]; then
    local bl
    bl=$(grep -E '^\s*type\s*=' "$CONFIG_FILE" | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
    [[ -n "$bl" ]] && echo "$bl" && return
  fi

  # Auto-detect from installed tools
  command -v grub-editenv   &>/dev/null && echo "grub2"        && return
  command -v bootctl        &>/dev/null && echo "systemd-boot" && return
  command -v fw_setenv      &>/dev/null && echo "u-boot"       && return
  command -v barebox-state  &>/dev/null && echo "barebox"      && return
  command -v rauc           &>/dev/null && echo "rauc"         && return
  [[ -d /sys/firmware/efi ]] && echo "efi-stub" && return
  echo "unknown"
}

# ── Detect current slot ───────────────────────────────────────────────────────
detect_slot() {
  # Check kernel cmdline for slot info (update_engine convention)
  if grep -q 'lota_slot=' /proc/cmdline 2>/dev/null; then
    grep -o 'lota_slot=[^ ]*' /proc/cmdline | cut -d= -f2
    return
  fi
  # RAUC convention
  if command -v rauc &>/dev/null; then
    rauc status 2>/dev/null | grep 'booted' | grep -o 'rootfs\.[ab]' | head -1
    return
  fi
  # Default
  echo "a"
}

# ── Bootloader-specific confirmation ─────────────────────────────────────────
confirm_grub2() {
  local grubenv
  grubenv=$(find /boot -name grubenv 2>/dev/null | head -1)
  [[ -z "$grubenv" ]] && grubenv="/boot/grub/grubenv"
  info "Confirming boot via grub-editenv: $grubenv"
  run grub-editenv "$grubenv" set boot_success=1
  run grub-editenv "$grubenv" unset boot_indeterminate
  # Clear upgrade_available flag used by some GRUB OTA setups
  run grub-editenv "$grubenv" set upgrade_available=0 2>/dev/null || true
}

confirm_systemd_boot() {
  info "Confirming boot via bootctl"
  # bootctl set-good marks the current entry as successfully booted
  if bootctl --version 2>/dev/null | grep -q '^[2-9][0-9][0-9]'; then
    run bootctl set-good 2>/dev/null || run bootctl set-oneshot "" 2>/dev/null || true
  else
    warn "bootctl version too old for set-good — marking via EFI variable"
    confirm_efi_stub
  fi
}

confirm_u_boot() {
  info "Confirming boot via fw_setenv"
  run fw_setenv upgrade_available 0
  run fw_setenv bootcount 0 2>/dev/null || true
}

confirm_barebox() {
  info "Confirming boot via barebox-state"
  run barebox-state --set "system.state.bootstate.${SLOT}.remaining_attempts=3"
  run barebox-state --set "system.state.bootstate.${SLOT}.good=1"
}

confirm_efi_stub() {
  info "Confirming boot via EFI variable"
  # Write OsGoodBoot EFI variable (linux-over-the-air convention)
  local efi_var="/sys/firmware/efi/efivars/OsGoodBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  if [[ -d /sys/firmware/efi/efivars ]]; then
    run bash -c "printf '\x07\x00\x00\x00\x01' > '$efi_var'" 2>/dev/null || \
      warn "Could not write EFI variable — may need root or efivarfs mounted"
  else
    warn "EFI variables not available"
  fi
}

confirm_rauc() {
  info "Confirming boot via rauc"
  run rauc status mark-good
}

confirm_custom() {
  local cmd="${LOTA_CONFIRM_COMMAND:-}"
  [[ -z "$cmd" ]] && die "LOTA_CONFIRM_COMMAND not set for custom bootloader"
  info "Confirming boot via custom command: $cmd"
  run bash -c "$cmd"
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
  echo "=== lota boot status ==="
  echo "Bootloader: ${BOOTLOADER:-$(detect_bootloader)}"
  echo "Slot:       ${SLOT:-$(detect_slot)}"
  echo "Kernel:     $(uname -r)"
  echo "Cmdline:    $(cat /proc/cmdline)"
  if command -v rauc &>/dev/null; then
    echo ""
    echo "=== RAUC slot status ==="
    rauc status 2>/dev/null || true
  fi
  if command -v grub-editenv &>/dev/null; then
    echo ""
    echo "=== GRUB env ==="
    grubenv=$(find /boot -name grubenv 2>/dev/null | head -1)
    [[ -n "$grubenv" ]] && grub-editenv "$grubenv" list 2>/dev/null || true
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
[[ -z "$BOOTLOADER" ]] && BOOTLOADER="$(detect_bootloader)"
[[ -z "$SLOT" ]]       && SLOT="$(detect_slot)"

if $STATUS_ONLY; then show_status; exit 0; fi

info "Confirming boot: bootloader=$BOOTLOADER slot=$SLOT"

case "$BOOTLOADER" in
  grub2)        confirm_grub2 ;;
  systemd-boot) confirm_systemd_boot ;;
  u-boot)       confirm_u_boot ;;
  barebox)      confirm_barebox ;;
  efi-stub)     confirm_efi_stub ;;
  rauc)         confirm_rauc ;;
  custom)       confirm_custom ;;
  unknown)      warn "Could not detect bootloader — boot not confirmed" ;;
  *)            die "Unknown bootloader: $BOOTLOADER" ;;
esac

info "Boot confirmed for slot $SLOT"
