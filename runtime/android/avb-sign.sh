#!/usr/bin/env bash
# avb-sign.sh — Android Verified Boot 2.0 signing and verification
#
# Wraps avbtool to sign partition images and produce vbmeta.img.
# Reads avb_mode from config/system.toml [android].avb_mode:
#   signed    — sign with provided key (--key required)
#   unlocked  — produce a VERIFICATION_DISABLED vbmeta (no key needed)
#
# Commands:
#   sign-boot    --image FILE --key PEM [--partition-size BYTES]
#   sign-system  --image FILE --key PEM [--partition-size BYTES]
#   sign-vendor  --image FILE --key PEM [--partition-size BYTES]
#   make-vbmeta  --output FILE --key PEM --boot FILE --system FILE [--vendor FILE] [--chain partition:idx:pubkey]
#   verify       --image FILE [--pubkey FILE]
#   disable-verification --output FILE
#
# Usage:
#   avb-sign.sh COMMAND [options]

set -euo pipefail

CMD="${1:-}"
shift || true

AVB_ALGORITHM="${LOTA_AVB_ALGORITHM:-SHA256_RSA4096}"
AVB_MODE="${LOTA_AVB_MODE:-signed}"

info() { echo "[lota-avb] $*"; }
die()  { echo "[lota-avb] ERROR: $*" >&2; exit 1; }

require_avbtool() {
  command -v avbtool &>/dev/null || die "avbtool not found — install android-tools-avb or build from AOSP"
}

cmd_sign_boot() {
  local image="" key="" partition_size="" partition_name="boot"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)          image="$2";          shift 2 ;;
      --key)            key="$2";            shift 2 ;;
      --partition-size) partition_size="$2"; shift 2 ;;
      --partition-name) partition_name="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$image" ]] && die "--image required"
  [[ ! -f "$image" ]] && die "Image not found: $image"
  require_avbtool

  if [[ "$AVB_MODE" == "unlocked" ]]; then
    info "AVB mode=unlocked, skipping boot signing"
    return 0
  fi

  [[ -z "$key" ]] && die "--key required for avb_mode=signed"

  # Default partition size: round up image size to next 64MiB boundary
  if [[ -z "$partition_size" ]]; then
    local img_size
    img_size=$(stat -c%s "$image")
    partition_size=$(( ((img_size + 67108863) / 67108864) * 67108864 ))
  fi

  info "Signing $partition_name: $image (partition_size=$partition_size)"
  avbtool add_hash_footer \
    --image "$image" \
    --partition_name "$partition_name" \
    --partition_size "$partition_size" \
    --key "$key" \
    --algorithm "$AVB_ALGORITHM"
  info "Signed: $image"
}

cmd_sign_system() {
  local image="" key="" partition_size="" partition_name="system"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)          image="$2";          shift 2 ;;
      --key)            key="$2";            shift 2 ;;
      --partition-size) partition_size="$2"; shift 2 ;;
      --partition-name) partition_name="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$image" ]] && die "--image required"
  [[ ! -f "$image" ]] && die "Image not found: $image"
  require_avbtool

  if [[ "$AVB_MODE" == "unlocked" ]]; then
    info "AVB mode=unlocked, skipping system signing"
    return 0
  fi

  [[ -z "$key" ]] && die "--key required for avb_mode=signed"

  if [[ -z "$partition_size" ]]; then
    local img_size
    img_size=$(stat -c%s "$image")
    partition_size=$(( ((img_size + 67108863) / 67108864) * 67108864 ))
  fi

  info "Signing $partition_name with hashtree: $image"
  avbtool add_hashtree_footer \
    --image "$image" \
    --partition_name "$partition_name" \
    --partition_size "$partition_size" \
    --key "$key" \
    --algorithm "$AVB_ALGORITHM" \
    --hash_algorithm sha256
  info "Signed: $image"
}

cmd_sign_vendor() {
  # Vendor partition uses a separate key (chain partition descriptor)
  local image="" key="" partition_size=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)          image="$2";          shift 2 ;;
      --key)            key="$2";            shift 2 ;;
      --partition-size) partition_size="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  cmd_sign_system --image "$image" --key "$key" \
    ${partition_size:+--partition-size "$partition_size"} \
    --partition-name vendor
}

cmd_make_vbmeta() {
  local output="" key="" boot="" system="" vendor="" chains=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output)  output="$2";  shift 2 ;;
      --key)     key="$2";     shift 2 ;;
      --boot)    boot="$2";    shift 2 ;;
      --system)  system="$2";  shift 2 ;;
      --vendor)  vendor="$2";  shift 2 ;;
      --chain)   chains+=("$2"); shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$output" ]] && die "--output required"
  require_avbtool

  if [[ "$AVB_MODE" == "unlocked" ]]; then
    info "AVB mode=unlocked, producing VERIFICATION_DISABLED vbmeta"
    avbtool make_vbmeta_image \
      --output "$output" \
      --flags 2
    info "vbmeta (verification disabled): $output"
    return 0
  fi

  [[ -z "$key" ]] && die "--key required for avb_mode=signed"

  local args=(
    --output "$output"
    --key "$key"
    --algorithm "$AVB_ALGORITHM"
  )

  [[ -n "$boot" ]]   && args+=(--include_descriptors_from_image "$boot")
  [[ -n "$system" ]] && args+=(--include_descriptors_from_image "$system")
  [[ -n "$vendor" ]] && args+=(--include_descriptors_from_image "$vendor")

  for chain in "${chains[@]}"; do
    args+=(--chain_partition "$chain")
  done

  info "Creating vbmeta: $output"
  avbtool make_vbmeta_image "${args[@]}"
  info "vbmeta created: $output"
}

cmd_verify() {
  local image="" pubkey=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)  image="$2";  shift 2 ;;
      --pubkey) pubkey="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$image" ]] && die "--image required"
  require_avbtool

  local args=(--image "$image")
  [[ -n "$pubkey" ]] && args+=(--key "$pubkey")

  info "Verifying AVB: $image"
  avbtool verify_image "${args[@]}"
  info "AVB verification passed: $image"
}

cmd_disable_verification() {
  local output=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) output="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$output" ]] && die "--output required"
  require_avbtool

  info "Producing VERIFICATION_DISABLED vbmeta: $output"
  avbtool make_vbmeta_image --output "$output" --flags 2
  info "Done: $output"
}

case "$CMD" in
  sign-boot)             cmd_sign_boot "$@" ;;
  sign-system)           cmd_sign_system "$@" ;;
  sign-vendor)           cmd_sign_vendor "$@" ;;
  make-vbmeta)           cmd_make_vbmeta "$@" ;;
  verify)                cmd_verify "$@" ;;
  disable-verification)  cmd_disable_verification "$@" ;;
  "")  die "Usage: avb-sign.sh {sign-boot|sign-system|sign-vendor|make-vbmeta|verify|disable-verification} [options]" ;;
  *)   die "Unknown command: $CMD" ;;
esac
