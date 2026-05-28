#!/usr/bin/env bash
# android-bundle.sh — Android OTA bundle creation
#
# Produces a lota-compatible Android OTA bundle containing:
#   payload.bin              CrAU format payload (full or delta)
#   payload_properties.txt   FILE_HASH, FILE_SIZE, METADATA_HASH, METADATA_SIZE
#   update.zip               ADB sideload package (wraps payload.bin)
#   vbmeta.img               Signed or verification-disabled vbmeta
#   manifest.json            lota bundle metadata
#
# Supports all four transport modes:
#   fastboot   — images flashed directly via fastboot-flash.sh
#   adb        — update.zip delivered via adb-sideload.sh
#   network    — payload.bin served via Nebraska/Omaha server
#   all        — produce all artifacts
#
# Usage:
#   android-bundle.sh create [options]
#   android-bundle.sh inspect --bundle DIR
#
# Options:
#   --version VER          Update version string (required)
#   --arch ARCH            Target arch: arm64|arm|x86_64|x86|riscv64 (required)
#   --channel CHANNEL      Update channel (default: stable)
#   --distro DISTRO        Target distro/device (default: android)
#   --type full|delta      Payload type (default: full)
#   --target-files ZIP     AOSP target-files zip (for payload.bin creation)
#   --source-files ZIP     Source target-files zip (delta only)
#   --boot FILE            boot.img (for fastboot bundle)
#   --system FILE          system.img
#   --vendor FILE          vendor.img
#   --avb-key PEM          AVB signing key (omit for unlocked/disabled)
#   --avb-mode signed|unlocked  AVB mode (default: unlocked)
#   --output DIR           Output directory (default: .)
#   --transport all|fastboot|adb|network  Artifacts to produce (default: all)

set -euo pipefail

CMD="${1:-create}"
shift || true

VERSION=""
ARCH=""
CHANNEL="stable"
DISTRO="android"
PAYLOAD_TYPE="full"
TARGET_FILES=""
SOURCE_FILES=""
BOOT_IMG=""
SYSTEM_IMG=""
VENDOR_IMG=""
AVB_KEY=""
AVB_MODE="unlocked"
OUTPUT_DIR="."
TRANSPORT="all"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${LOTA_RUNTIME_DIR:-$(cd "$SCRIPT_DIR/../../runtime" && pwd)}"

info() { echo "[lota-android-bundle] $*"; }
die()  { echo "[lota-android-bundle] ERROR: $*" >&2; exit 1; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)     VERSION="$2";      shift 2 ;;
      --arch)        ARCH="$2";         shift 2 ;;
      --channel)     CHANNEL="$2";      shift 2 ;;
      --distro)      DISTRO="$2";       shift 2 ;;
      --type)        PAYLOAD_TYPE="$2"; shift 2 ;;
      --target-files) TARGET_FILES="$2"; shift 2 ;;
      --source-files) SOURCE_FILES="$2"; shift 2 ;;
      --boot)        BOOT_IMG="$2";     shift 2 ;;
      --system)      SYSTEM_IMG="$2";   shift 2 ;;
      --vendor)      VENDOR_IMG="$2";   shift 2 ;;
      --avb-key)     AVB_KEY="$2";      shift 2 ;;
      --avb-mode)    AVB_MODE="$2";     shift 2 ;;
      --output)      OUTPUT_DIR="$2";   shift 2 ;;
      --transport)   TRANSPORT="$2";    shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

cmd_create() {
  parse_args "$@"
  [[ -z "$VERSION" ]] && die "--version required"
  [[ -z "$ARCH" ]]    && die "--arch required"

  BUNDLE_NAME="android-bundle-${VERSION}-${ARCH}.lota"
  BUNDLE_PATH="${OUTPUT_DIR}/${BUNDLE_NAME}"
  [[ -d "$BUNDLE_PATH" ]] && die "Bundle already exists: $BUNDLE_PATH"
  mkdir -p "$BUNDLE_PATH"

  export LOTA_AVB_MODE="$AVB_MODE"

  # ── Step 1: payload.bin ──────────────────────────────────────────────────
  if [[ "$TRANSPORT" == "all" ]] || [[ "$TRANSPORT" == "network" ]] || [[ "$TRANSPORT" == "adb" ]]; then
    if [[ -n "$TARGET_FILES" ]]; then
      info "Creating payload.bin from target-files"
      local payload_args=(
        --target-files "$TARGET_FILES"
        --output "$BUNDLE_PATH"
      )
      [[ "$PAYLOAD_TYPE" == "delta" ]] && [[ -n "$SOURCE_FILES" ]] && \
        payload_args=(--source-files "$SOURCE_FILES" "${payload_args[@]}")
      [[ -n "$AVB_KEY" ]] && payload_args+=(--key "$AVB_KEY")

      local payload_cmd="create-full"
      [[ "$PAYLOAD_TYPE" == "delta" ]] && payload_cmd="create-delta"

      bash "$RUNTIME_DIR/android/payload-tool.sh" "$payload_cmd" "${payload_args[@]}"
    else
      info "No --target-files provided — skipping payload.bin creation"
    fi
  fi

  # ── Step 2: AVB signing ──────────────────────────────────────────────────
  local vbmeta_path="$BUNDLE_PATH/vbmeta.img"
  if [[ "$AVB_MODE" == "unlocked" ]] || [[ -z "$AVB_KEY" ]]; then
    info "Producing VERIFICATION_DISABLED vbmeta"
    bash "$RUNTIME_DIR/android/avb-sign.sh" disable-verification --output "$vbmeta_path"
  else
    info "Signing partition images with AVB"
    local sign_args=(make-vbmeta --output "$vbmeta_path" --key "$AVB_KEY")
    [[ -n "$BOOT_IMG" ]]   && {
      bash "$RUNTIME_DIR/android/avb-sign.sh" sign-boot --image "$BOOT_IMG" --key "$AVB_KEY"
      sign_args+=(--boot "$BOOT_IMG")
    }
    [[ -n "$SYSTEM_IMG" ]] && {
      bash "$RUNTIME_DIR/android/avb-sign.sh" sign-system --image "$SYSTEM_IMG" --key "$AVB_KEY"
      sign_args+=(--system "$SYSTEM_IMG")
    }
    [[ -n "$VENDOR_IMG" ]] && {
      bash "$RUNTIME_DIR/android/avb-sign.sh" sign-vendor --image "$VENDOR_IMG" --key "$AVB_KEY"
      sign_args+=(--vendor "$VENDOR_IMG")
    }
    bash "$RUNTIME_DIR/android/avb-sign.sh" "${sign_args[@]}"
  fi

  # ── Step 3: Copy partition images for fastboot transport ─────────────────
  if [[ "$TRANSPORT" == "all" ]] || [[ "$TRANSPORT" == "fastboot" ]]; then
    [[ -n "$BOOT_IMG" ]]   && cp "$BOOT_IMG"   "$BUNDLE_PATH/boot.img"
    [[ -n "$SYSTEM_IMG" ]] && cp "$SYSTEM_IMG" "$BUNDLE_PATH/system.img"
    [[ -n "$VENDOR_IMG" ]] && cp "$VENDOR_IMG" "$BUNDLE_PATH/vendor.img"
  fi

  # ── Step 4: update.zip for ADB sideload ─────────────────────────────────
  if [[ "$TRANSPORT" == "all" ]] || [[ "$TRANSPORT" == "adb" ]]; then
    if [[ -f "$BUNDLE_PATH/payload.bin" ]]; then
      info "Creating update.zip for ADB sideload"
      bash "$RUNTIME_DIR/android/payload-tool.sh" create-zip \
        --payload "$BUNDLE_PATH" \
        --output "$BUNDLE_PATH/update.zip"
    fi
  fi

  # ── Step 5: manifest.json ────────────────────────────────────────────────
  local payload_sha256="" payload_size=0
  if [[ -f "$BUNDLE_PATH/payload.bin" ]]; then
    payload_sha256=$(sha256sum "$BUNDLE_PATH/payload.bin" | awk '{print $1}')
    payload_size=$(stat -c%s "$BUNDLE_PATH/payload.bin")
  fi

  cat > "$BUNDLE_PATH/manifest.json" <<EOF
{
  "version": "${VERSION}",
  "arch": "${ARCH}",
  "channel": "${CHANNEL}",
  "distro": "${DISTRO}",
  "payload_type": "${PAYLOAD_TYPE}",
  "payload_format": "android-crau",
  "avb_mode": "${AVB_MODE}",
  "transport": "${TRANSPORT}",
  "payload_sha256": "${payload_sha256}",
  "payload_size": ${payload_size},
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "format_version": "1"
}
EOF

  info "Android bundle created: $BUNDLE_PATH"
  info "  Version:   $VERSION"
  info "  Arch:      $ARCH"
  info "  AVB mode:  $AVB_MODE"
  info "  Transport: $TRANSPORT"
  [[ -f "$BUNDLE_PATH/payload.bin" ]]  && info "  payload.bin: $payload_size bytes"
  [[ -f "$BUNDLE_PATH/update.zip" ]]   && info "  update.zip: $(stat -c%s "$BUNDLE_PATH/update.zip") bytes"
  [[ -f "$BUNDLE_PATH/vbmeta.img" ]]   && info "  vbmeta.img: $(stat -c%s "$BUNDLE_PATH/vbmeta.img") bytes"
}

cmd_inspect() {
  local bundle_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bundle) bundle_dir="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$bundle_dir" ]] && die "--bundle required"
  [[ ! -f "$bundle_dir/manifest.json" ]] && die "Not a valid bundle: $bundle_dir"

  echo "=== Android Bundle ==="
  cat "$bundle_dir/manifest.json"
  echo ""
  echo "Contents:"
  ls -lh "$bundle_dir/"

  if [[ -f "$bundle_dir/payload.bin" ]]; then
    echo ""
    bash "$RUNTIME_DIR/android/payload-tool.sh" inspect --payload "$bundle_dir/payload.bin"
  fi
}

case "$CMD" in
  create)  cmd_create "$@" ;;
  inspect) cmd_inspect "$@" ;;
  "")      die "Usage: android-bundle.sh {create|inspect} [options]" ;;
  *)       die "Unknown command: $CMD" ;;
esac
