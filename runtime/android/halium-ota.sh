#!/usr/bin/env bash
# halium-ota.sh — Halium hardware adaptation layer OTA management
#
# Manages OTA updates for Halium-based systems (Droidian, Ubuntu Touch,
# postmarketOS with Halium). Halium bridges Android kernel/blobs to a
# Linux userspace via LXC containers.
#
# Halium partition layout (typical):
#   /dev/disk/by-partlabel/boot        Android kernel + ramdisk
#   /dev/disk/by-partlabel/system      Android system (HAL blobs)
#   /dev/disk/by-partlabel/userdata    Linux rootfs (bind-mounted)
#   /dev/disk/by-partlabel/vendor      Android vendor blobs (optional)
#
# Update strategies:
#   rootfs    Update the Linux rootfs (Debian/Droidian image)
#   halium    Update the Android system/vendor blobs
#   kernel    Update the Android kernel (boot partition)
#   full      Update all three layers
#
# Commands:
#   update-rootfs   --image FILE [--slot SLOT]
#   update-halium   --system FILE [--vendor FILE]
#   update-kernel   --boot FILE [--dtbo FILE]
#   update-full     --rootfs FILE --system FILE --boot FILE [--vendor FILE]
#   status          Show current Halium layer versions
#   rollback        Restore previous rootfs/halium from backup
#
# Environment:
#   LOTA_HALIUM_ROOTFS_DEVICE   Block device for Linux rootfs
#   LOTA_HALIUM_SYSTEM_DEVICE   Block device for Android system
#   LOTA_HALIUM_BOOT_DEVICE     Block device for boot partition
#   LOTA_HALIUM_VENDOR_DEVICE   Block device for vendor (optional)
#   LOTA_HALIUM_DISTRO          halium distro: droidian|ubports|pmos

set -euo pipefail

CMD="${1:-}"
shift || true

ROOTFS_DEVICE="${LOTA_HALIUM_ROOTFS_DEVICE:-}"
SYSTEM_DEVICE="${LOTA_HALIUM_SYSTEM_DEVICE:-}"
BOOT_DEVICE="${LOTA_HALIUM_BOOT_DEVICE:-}"
VENDOR_DEVICE="${LOTA_HALIUM_VENDOR_DEVICE:-}"
HALIUM_DISTRO="${LOTA_HALIUM_DISTRO:-droidian}"
BACKUP_DIR="/var/lib/lota/halium-backup"

info() { echo "[lota-halium] $*"; }
warn() { echo "[lota-halium] WARN: $*" >&2; }
die()  { echo "[lota-halium] ERROR: $*" >&2; exit 1; }

# Auto-detect Halium partition devices from /proc/cmdline or by-partlabel
detect_devices() {
  if [[ -z "$BOOT_DEVICE" ]]; then
    BOOT_DEVICE=$(readlink -f /dev/disk/by-partlabel/boot 2>/dev/null || \
                  readlink -f /dev/disk/by-partlabel/boot_a 2>/dev/null || \
                  echo "")
  fi
  if [[ -z "$SYSTEM_DEVICE" ]]; then
    SYSTEM_DEVICE=$(readlink -f /dev/disk/by-partlabel/system 2>/dev/null || \
                    readlink -f /dev/disk/by-partlabel/system_a 2>/dev/null || \
                    echo "")
  fi
  if [[ -z "$VENDOR_DEVICE" ]]; then
    VENDOR_DEVICE=$(readlink -f /dev/disk/by-partlabel/vendor 2>/dev/null || \
                    readlink -f /dev/disk/by-partlabel/vendor_a 2>/dev/null || \
                    echo "")
  fi
  # Rootfs: typically the userdata partition or a loop device
  if [[ -z "$ROOTFS_DEVICE" ]]; then
    ROOTFS_DEVICE=$(readlink -f /dev/disk/by-partlabel/userdata 2>/dev/null || echo "")
  fi
}

# Stop the Halium Android container before touching system/vendor
stop_halium_container() {
  info "Stopping Halium Android container"
  if command -v lxc-stop &>/dev/null; then
    lxc-stop -n android 2>/dev/null || true
  fi
  # Droidian uses systemd unit
  systemctl stop lxc@android.service 2>/dev/null || true
  sleep 2
}

start_halium_container() {
  info "Starting Halium Android container"
  systemctl start lxc@android.service 2>/dev/null || \
    lxc-start -n android 2>/dev/null || \
    warn "Could not start Halium container — manual start may be required"
}

# Write image to block device with progress
flash_image() {
  local image="$1"
  local device="$2"
  local label="$3"

  [[ ! -f "$image" ]]   && die "Image not found: $image"
  [[ -z "$device" ]]    && die "No device configured for $label"
  [[ ! -b "$device" ]]  && die "Not a block device: $device"

  local img_size
  img_size=$(stat -c%s "$image")
  info "Flashing $label: $image → $device ($img_size bytes)"

  dd if="$image" of="$device" bs=4M conv=fsync status=progress 2>&1 || \
    die "Flash failed: $label"
  sync
  info "Flashed: $label"
}

cmd_update_rootfs() {
  local image="" slot=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image) image="$2"; shift 2 ;;
      --slot)  slot="$2";  shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$image" ]] && die "--image required"
  detect_devices

  # Backup current rootfs header (first 4MiB)
  mkdir -p "$BACKUP_DIR"
  if [[ -n "$ROOTFS_DEVICE" ]] && [[ -b "$ROOTFS_DEVICE" ]]; then
    info "Backing up rootfs header"
    dd if="$ROOTFS_DEVICE" of="$BACKUP_DIR/rootfs.header.bak" bs=4M count=1 2>/dev/null || true
  fi

  flash_image "$image" "${ROOTFS_DEVICE:-}" "rootfs"
}

cmd_update_halium() {
  local system="" vendor=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --system) system="$2"; shift 2 ;;
      --vendor) vendor="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$system" ]] && die "--system required"
  detect_devices

  stop_halium_container

  flash_image "$system" "${SYSTEM_DEVICE:-}" "system"

  if [[ -n "$vendor" ]]; then
    flash_image "$vendor" "${VENDOR_DEVICE:-}" "vendor"
  fi

  start_halium_container
}

cmd_update_kernel() {
  local boot="" dtbo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --boot) boot="$2"; shift 2 ;;
      --dtbo) dtbo="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$boot" ]] && die "--boot required"
  detect_devices

  # Backup current boot image
  mkdir -p "$BACKUP_DIR"
  if [[ -n "$BOOT_DEVICE" ]] && [[ -b "$BOOT_DEVICE" ]]; then
    info "Backing up boot partition"
    dd if="$BOOT_DEVICE" of="$BACKUP_DIR/boot.img.bak" bs=4M 2>/dev/null || true
  fi

  flash_image "$boot" "${BOOT_DEVICE:-}" "boot"

  if [[ -n "$dtbo" ]]; then
    local dtbo_device
    dtbo_device=$(readlink -f /dev/disk/by-partlabel/dtbo 2>/dev/null || echo "")
    [[ -n "$dtbo_device" ]] && flash_image "$dtbo" "$dtbo_device" "dtbo"
  fi
}

cmd_update_full() {
  local rootfs="" system="" boot="" vendor=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rootfs) rootfs="$2"; shift 2 ;;
      --system) system="$2"; shift 2 ;;
      --boot)   boot="$2";   shift 2 ;;
      --vendor) vendor="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$rootfs" ]] && die "--rootfs required"
  [[ -z "$system" ]] && die "--system required"
  [[ -z "$boot" ]]   && die "--boot required"

  info "Full Halium update: rootfs + system + kernel"
  stop_halium_container
  detect_devices

  cmd_update_kernel --boot "$boot"
  cmd_update_halium --system "$system" ${vendor:+--vendor "$vendor"}
  cmd_update_rootfs --image "$rootfs"

  start_halium_container
  info "Full Halium update complete — reboot required"
}

cmd_status() {
  detect_devices
  echo "=== Halium Status ==="
  echo "Distro:         $HALIUM_DISTRO"
  echo "Boot device:    ${BOOT_DEVICE:-not detected}"
  echo "System device:  ${SYSTEM_DEVICE:-not detected}"
  echo "Vendor device:  ${VENDOR_DEVICE:-not detected}"
  echo "Rootfs device:  ${ROOTFS_DEVICE:-not detected}"
  echo ""

  # Halium version from /etc/halium-version if present
  if [[ -f /etc/halium-version ]]; then
    echo "Halium version: $(cat /etc/halium-version)"
  fi

  # Android container state
  if command -v lxc-info &>/dev/null; then
    echo ""
    lxc-info -n android 2>/dev/null || echo "Android container: not running"
  fi

  # Distro-specific version info
  case "$HALIUM_DISTRO" in
    droidian)
      cat /etc/droidian-release 2>/dev/null || true ;;
    ubports)
      cat /etc/system-image/channel.ini 2>/dev/null || true ;;
  esac
}

cmd_rollback() {
  [[ ! -d "$BACKUP_DIR" ]] && die "No backup found at $BACKUP_DIR"
  detect_devices

  info "Rolling back Halium layers"
  stop_halium_container

  if [[ -f "$BACKUP_DIR/boot.img.bak" ]] && [[ -n "$BOOT_DEVICE" ]]; then
    info "Restoring boot partition"
    dd if="$BACKUP_DIR/boot.img.bak" of="$BOOT_DEVICE" bs=4M conv=fsync 2>/dev/null
  fi

  start_halium_container
  info "Rollback complete — reboot required"
}

case "$CMD" in
  update-rootfs) cmd_update_rootfs "$@" ;;
  update-halium) cmd_update_halium "$@" ;;
  update-kernel) cmd_update_kernel "$@" ;;
  update-full)   cmd_update_full "$@" ;;
  status)        cmd_status ;;
  rollback)      cmd_rollback ;;
  "")  die "Usage: halium-ota.sh {update-rootfs|update-halium|update-kernel|update-full|status|rollback}" ;;
  *)   die "Unknown command: $CMD" ;;
esac
