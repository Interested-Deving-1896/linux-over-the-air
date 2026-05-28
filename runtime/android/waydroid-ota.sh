#!/usr/bin/env bash
# waydroid-ota.sh — Waydroid Android container image OTA management
#
# Manages OTA updates for Waydroid (Android in LXC on Linux) running on
# Debian/Devuan hosts. Handles:
#   - Image updates (system.img + vendor.img hot-swap)
#   - APK/OBB sideload into the running container
#   - Incus-managed container lifecycle (if using Incus instead of native LXC)
#   - Channel switching (vanilla, GAPPS, etc.)
#
# Waydroid image paths:
#   /var/lib/waydroid/images/system.img
#   /var/lib/waydroid/images/vendor.img
#
# Commands:
#   check-update    Check for newer Waydroid images
#   update          Download and apply new system/vendor images
#   sideload-apk    --apk FILE [--package NAME]
#   sideload-obb    --obb FILE --package NAME
#   status          Show current Waydroid version and container state
#   stop            Stop Waydroid session and container
#   start           Start Waydroid session
#   rollback        Restore previous images from backup
#
# Environment:
#   LOTA_WAYDROID_IMAGES_DIR   Image directory (default: /var/lib/waydroid/images)
#   LOTA_WAYDROID_CHANNEL      Image channel: vanilla|gapps (default: vanilla)
#   LOTA_WAYDROID_ARCH         Architecture (default: auto-detect)
#   LOTA_USE_INCUS             Use Incus instead of native LXC (default: false)

set -euo pipefail

CMD="${1:-}"
shift || true

IMAGES_DIR="${LOTA_WAYDROID_IMAGES_DIR:-/var/lib/waydroid/images}"
CHANNEL="${LOTA_WAYDROID_CHANNEL:-vanilla}"
ARCH="${LOTA_WAYDROID_ARCH:-$(uname -m)}"
USE_INCUS="${LOTA_USE_INCUS:-false}"
BACKUP_DIR="${IMAGES_DIR}/.lota-backup"

info() { echo "[lota-waydroid] $*"; }
warn() { echo "[lota-waydroid] WARN: $*" >&2; }
die()  { echo "[lota-waydroid] ERROR: $*" >&2; exit 1; }

require_waydroid() {
  command -v waydroid &>/dev/null || die "waydroid not found — install waydroid"
}

# Normalize arch to Waydroid naming
normalize_arch() {
  case "$ARCH" in
    x86_64|amd64)   echo "x86_64" ;;
    aarch64|arm64)  echo "arm64" ;;
    armv7*|armhf)   echo "arm" ;;
    i686|i386)      echo "x86" ;;
    *)              echo "$ARCH" ;;
  esac
}

# Stop Waydroid session and container before image swap
stop_waydroid() {
  info "Stopping Waydroid session"
  waydroid session stop 2>/dev/null || true

  if [[ "$USE_INCUS" == "true" ]]; then
    info "Stopping Waydroid Incus container"
    incus stop waydroid 2>/dev/null || true
  else
    info "Stopping Waydroid LXC container"
    waydroid container stop 2>/dev/null || true
  fi
  sleep 2
}

# Start Waydroid session
start_waydroid() {
  if [[ "$USE_INCUS" == "true" ]]; then
    info "Starting Waydroid via Incus"
    incus start waydroid 2>/dev/null || true
  fi
  info "Starting Waydroid session"
  waydroid session start &
  sleep 3
}

cmd_check_update() {
  require_waydroid
  info "Checking for Waydroid image updates (channel: $CHANNEL, arch: $(normalize_arch))"

  # waydroid upgrade --check is not always available; use the OTA server if configured
  if waydroid upgrade --check 2>/dev/null; then
    info "waydroid upgrade --check completed"
  else
    # Fall back to checking the lota OTA server for waydroid images
    local server_url="${LOTA_SERVER_URL:-}"
    if [[ -n "$server_url" ]]; then
      info "Checking lota OTA server: $server_url"
      curl -sf "${server_url}/api/packages?channel=${CHANNEL}&arch=$(normalize_arch)&distro=waydroid" \
        | python3 -c "import json,sys; pkgs=json.load(sys.stdin); print(pkgs[0]['version'] if pkgs else 'no update')" \
        2>/dev/null || info "No update information available"
    else
      warn "No update server configured — set LOTA_SERVER_URL"
    fi
  fi
}

cmd_update() {
  local system_img="" vendor_img="" version=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --system)  system_img="$2"; shift 2 ;;
      --vendor)  vendor_img="$2"; shift 2 ;;
      --version) version="$2";    shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  require_waydroid

  # If no explicit images provided, use waydroid's built-in upgrade
  if [[ -z "$system_img" ]] && [[ -z "$vendor_img" ]]; then
    info "Running waydroid upgrade"
    stop_waydroid
    waydroid upgrade
    start_waydroid
    return 0
  fi

  # Manual image swap
  [[ ! -d "$IMAGES_DIR" ]] && die "Waydroid images directory not found: $IMAGES_DIR"

  # Backup current images
  info "Backing up current images to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  [[ -f "$IMAGES_DIR/system.img" ]] && cp "$IMAGES_DIR/system.img" "$BACKUP_DIR/system.img.bak"
  [[ -f "$IMAGES_DIR/vendor.img" ]] && cp "$IMAGES_DIR/vendor.img" "$BACKUP_DIR/vendor.img.bak"

  stop_waydroid

  if [[ -n "$system_img" ]]; then
    info "Installing system image: $system_img"
    cp "$system_img" "$IMAGES_DIR/system.img"
  fi
  if [[ -n "$vendor_img" ]]; then
    info "Installing vendor image: $vendor_img"
    cp "$vendor_img" "$IMAGES_DIR/vendor.img"
  fi

  # Re-initialize Waydroid with new images
  info "Re-initializing Waydroid"
  waydroid init -f 2>/dev/null || waydroid init

  start_waydroid
  info "Waydroid update complete"
}

cmd_sideload_apk() {
  local apk="" package=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apk)     apk="$2";     shift 2 ;;
      --package) package="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$apk" ]] && die "--apk required"
  [[ ! -f "$apk" ]] && die "APK not found: $apk"
  require_waydroid

  info "Installing APK: $apk"
  waydroid app install "$apk"
  info "APK installed"
}

cmd_sideload_obb() {
  local obb="" package=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --obb)     obb="$2";     shift 2 ;;
      --package) package="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$obb" ]]     && die "--obb required"
  [[ -z "$package" ]] && die "--package required"
  [[ ! -f "$obb" ]]   && die "OBB not found: $obb"
  require_waydroid

  # OBB files go to /sdcard/Android/obb/{package}/
  local obb_dest="/sdcard/Android/obb/${package}"
  local obb_filename
  obb_filename=$(basename "$obb")

  info "Pushing OBB to container: $obb_dest/$obb_filename"
  waydroid shell mkdir -p "$obb_dest" 2>/dev/null || true
  # Push via lxc-attach or waydroid shell
  if command -v lxc-attach &>/dev/null; then
    lxc-attach -n waydroid -- mkdir -p "$obb_dest"
    cp "$obb" "/var/lib/waydroid/data/media/0/Android/obb/${package}/${obb_filename}"
  else
    warn "lxc-attach not available — copy OBB manually to /var/lib/waydroid/data/media/0/Android/obb/${package}/"
    mkdir -p "/var/lib/waydroid/data/media/0/Android/obb/${package}/"
    cp "$obb" "/var/lib/waydroid/data/media/0/Android/obb/${package}/${obb_filename}"
  fi
  info "OBB installed: $obb_filename"
}

cmd_status() {
  require_waydroid
  echo "=== Waydroid Status ==="
  waydroid status 2>/dev/null || echo "Waydroid not running"
  echo ""
  echo "Images directory: $IMAGES_DIR"
  for img in system.img vendor.img; do
    if [[ -f "$IMAGES_DIR/$img" ]]; then
      echo "  $img: $(stat -c%s "$IMAGES_DIR/$img") bytes, modified $(stat -c%y "$IMAGES_DIR/$img")"
    else
      echo "  $img: not found"
    fi
  done
  echo "Channel: $CHANNEL"
  echo "Arch:    $(normalize_arch)"
  echo "Incus:   $USE_INCUS"
}

cmd_stop() {
  require_waydroid
  stop_waydroid
  info "Waydroid stopped"
}

cmd_start() {
  require_waydroid
  start_waydroid
  info "Waydroid started"
}

cmd_rollback() {
  require_waydroid
  [[ ! -d "$BACKUP_DIR" ]] && die "No backup found at $BACKUP_DIR"

  info "Rolling back Waydroid images"
  stop_waydroid

  [[ -f "$BACKUP_DIR/system.img.bak" ]] && cp "$BACKUP_DIR/system.img.bak" "$IMAGES_DIR/system.img"
  [[ -f "$BACKUP_DIR/vendor.img.bak" ]] && cp "$BACKUP_DIR/vendor.img.bak" "$IMAGES_DIR/vendor.img"

  waydroid init -f 2>/dev/null || waydroid init
  start_waydroid
  info "Waydroid rollback complete"
}

case "$CMD" in
  check-update)  cmd_check_update "$@" ;;
  update)        cmd_update "$@" ;;
  sideload-apk)  cmd_sideload_apk "$@" ;;
  sideload-obb)  cmd_sideload_obb "$@" ;;
  status)        cmd_status ;;
  stop)          cmd_stop ;;
  start)         cmd_start ;;
  rollback)      cmd_rollback ;;
  "")  die "Usage: waydroid-ota.sh {check-update|update|sideload-apk|sideload-obb|status|stop|start|rollback}" ;;
  *)   die "Unknown command: $CMD" ;;
esac
