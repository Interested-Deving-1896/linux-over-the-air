#!/usr/bin/env bash
# install-handler.sh — filesystem-agnostic update payload installer
#
# Dispatches to the correct install method based on filesystem type and
# payload format. Called by the update engine after payload verification.
#
# Supported filesystems: ext4, btrfs, xfs, f2fs, squashfs, erofs, ubifs, raw
# Supported payload formats: full (raw image), delta (bsdiff/zstd-patch), tar, ostree
#
# Usage:
#   install-handler.sh --payload PATH --target DEVICE [options]
#
# Options:
#   --payload PATH       Path to the update payload file
#   --target DEVICE      Target block device or mountpoint
#   --filesystem TYPE    Filesystem type (auto-detected if omitted)
#   --format TYPE        Payload format: full|delta|tar|ostree (auto-detected)
#   --slot SLOT          Target slot: a|b (default: b)
#   --verify             Verify payload signature before installing
#   --dry-run            Print what would be done without doing it
#   --progress           Show progress output

set -euo pipefail

PAYLOAD=""
TARGET=""
FILESYSTEM=""
FORMAT=""
SLOT="b"
VERIFY=false
DRY_RUN=false
PROGRESS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --payload)    PAYLOAD="$2";    shift 2 ;;
    --target)     TARGET="$2";     shift 2 ;;
    --filesystem) FILESYSTEM="$2"; shift 2 ;;
    --format)     FORMAT="$2";     shift 2 ;;
    --slot)       SLOT="$2";       shift 2 ;;
    --verify)     VERIFY=true;     shift ;;
    --dry-run)    DRY_RUN=true;    shift ;;
    --progress)   PROGRESS=true;   shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PAYLOAD" ]] && { echo "ERROR: --payload required" >&2; exit 1; }
[[ -z "$TARGET"  ]] && { echo "ERROR: --target required"  >&2; exit 1; }

info()  { echo "[lota-install] $*"; }
warn()  { echo "[lota-install] WARN: $*" >&2; }
die()   { echo "[lota-install] ERROR: $*" >&2; exit 1; }
run()   { $DRY_RUN && echo "[dry-run] $*" || "$@"; }

# ── Auto-detect filesystem ────────────────────────────────────────────────────
detect_filesystem() {
  local dev="$1"
  if [[ -b "$dev" ]]; then
    blkid -o value -s TYPE "$dev" 2>/dev/null || echo "unknown"
  elif [[ -d "$dev" ]]; then
    stat -f -c '%T' "$dev" 2>/dev/null | sed 's/ext2\/ext3/ext4/'
  else
    echo "unknown"
  fi
}

# ── Auto-detect payload format ────────────────────────────────────────────────
detect_format() {
  local path="$1"
  case "$path" in
    *.delta|*.patch) echo "delta" ;;
    *.tar|*.tar.gz|*.tar.xz|*.tar.zst) echo "tar" ;;
    *.img|*.raw)     echo "full" ;;
    *.bin)
      # Check magic bytes
      local magic
      magic=$(xxd -l 4 "$path" 2>/dev/null | awk '{print $2$3}')
      case "$magic" in
        "43524f53") echo "full" ;;  # CROS delta magic
        *)          echo "full" ;;
      esac
      ;;
    *) echo "full" ;;
  esac
}

# ── Signature verification ────────────────────────────────────────────────────
verify_payload() {
  local payload="$1"
  local sig_file="${payload}.sig"
  local pubkey="${LOTA_PUBKEY:-/etc/lota/update-pubkey.pem}"

  [[ ! -f "$sig_file" ]] && { warn "No signature file found: $sig_file"; return 1; }
  [[ ! -f "$pubkey"   ]] && { warn "No public key found: $pubkey";       return 1; }

  info "Verifying payload signature"
  openssl dgst -sha256 -verify "$pubkey" -signature "$sig_file" "$payload" \
    || die "Payload signature verification failed"
  info "Signature verified"
}

# ── Install methods ───────────────────────────────────────────────────────────

install_full_image() {
  local payload="$1" target="$2" fs="$3"
  info "Installing full image to $target (fs: $fs)"

  local dd_opts="bs=4M conv=fsync"
  $PROGRESS && dd_opts="$dd_opts status=progress"

  case "$fs" in
    ext4|xfs|f2fs|btrfs)
      # Write raw image, then resize to fill partition
      run dd if="$payload" of="$target" $dd_opts
      case "$fs" in
        ext4) run e2fsck -f "$target" 2>/dev/null || true
              run resize2fs "$target" ;;
        xfs)  run xfs_growfs "$target" 2>/dev/null || true ;;
        btrfs)run btrfs filesystem resize max "$target" 2>/dev/null || true ;;
      esac
      ;;
    squashfs|erofs)
      # Read-only filesystems — write directly, no resize
      run dd if="$payload" of="$target" $dd_opts
      ;;
    ubifs)
      # NAND flash — use ubiupdatevol
      run ubiupdatevol "$target" "$payload"
      ;;
    raw)
      run dd if="$payload" of="$target" $dd_opts
      ;;
    *)
      warn "Unknown filesystem $fs — attempting raw dd"
      run dd if="$payload" of="$target" $dd_opts
      ;;
  esac
}

install_delta() {
  local payload="$1" target="$2"
  info "Applying delta patch to $target"

  # Detect delta tool
  if command -v bspatch &>/dev/null; then
    local tmp_out
    tmp_out=$(mktemp)
    run bspatch "$target" "$tmp_out" "$payload"
    run dd if="$tmp_out" of="$target" bs=4M conv=fsync
    rm -f "$tmp_out"
  elif command -v zstd &>/dev/null && [[ "$payload" == *.zst ]]; then
    local tmp_patch tmp_out
    tmp_patch=$(mktemp)
    tmp_out=$(mktemp)
    run zstd -d "$payload" -o "$tmp_patch"
    run bspatch "$target" "$tmp_out" "$tmp_patch"
    run dd if="$tmp_out" of="$target" bs=4M conv=fsync
    rm -f "$tmp_patch" "$tmp_out"
  else
    die "No delta patch tool found (bspatch required)"
  fi
}

install_tar() {
  local payload="$1" target="$2"
  info "Extracting tar payload to $target"

  # Mount target if it's a block device
  local mounted=false
  local mountpoint="$target"
  if [[ -b "$target" ]]; then
    mountpoint=$(mktemp -d)
    run mount "$target" "$mountpoint"
    mounted=true
  fi

  local tar_opts="-xf"
  $PROGRESS && tar_opts="-xvf"

  run tar $tar_opts "$payload" -C "$mountpoint" --numeric-owner

  if $mounted; then
    run umount "$mountpoint"
    rmdir "$mountpoint"
  fi
}

install_ostree() {
  local payload="$1" target="$2"
  info "Applying OSTree update from $payload"
  command -v ostree &>/dev/null || die "ostree not found"
  run ostree admin upgrade --os="$target" 2>/dev/null || \
    run ostree pull-local "$payload"
}

# ── Pre/post install hooks ────────────────────────────────────────────────────
run_hooks() {
  local phase="$1"  # pre-install or post-install
  local hook_dir="${LOTA_HOOK_DIR:-/etc/lota/hooks.d}"
  [[ ! -d "$hook_dir" ]] && return 0

  for hook in "$hook_dir"/${phase}-*.sh; do
    [[ -f "$hook" ]] || continue
    info "Running hook: $(basename "$hook")"
    run bash "$hook" \
      LOTA_PAYLOAD="$PAYLOAD" \
      LOTA_TARGET="$TARGET" \
      LOTA_SLOT="$SLOT" \
      LOTA_FILESYSTEM="$FILESYSTEM" || warn "Hook $(basename "$hook") failed (non-fatal)"
  done
}

# ── Main ──────────────────────────────────────────────────────────────────────
[[ ! -f "$PAYLOAD" ]] && die "Payload not found: $PAYLOAD"

[[ -z "$FILESYSTEM" ]] && FILESYSTEM="$(detect_filesystem "$TARGET")"
[[ -z "$FORMAT"     ]] && FORMAT="$(detect_format "$PAYLOAD")"

info "Installing update"
info "  Payload:    $PAYLOAD"
info "  Target:     $TARGET"
info "  Filesystem: $FILESYSTEM"
info "  Format:     $FORMAT"
info "  Slot:       $SLOT"

$VERIFY && verify_payload "$PAYLOAD"

run_hooks "pre-install"

case "$FORMAT" in
  full)   install_full_image "$PAYLOAD" "$TARGET" "$FILESYSTEM" ;;
  delta)  install_delta      "$PAYLOAD" "$TARGET" ;;
  tar)    install_tar        "$PAYLOAD" "$TARGET" ;;
  ostree) install_ostree     "$PAYLOAD" "$TARGET" ;;
  *)      die "Unknown payload format: $FORMAT" ;;
esac

run_hooks "post-install"

info "Install complete — reboot to activate slot $SLOT"
