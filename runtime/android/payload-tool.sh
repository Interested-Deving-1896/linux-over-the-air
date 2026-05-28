#!/usr/bin/env bash
# payload-tool.sh — Android payload.bin creation and inspection
#
# Wraps delta_generator (AOSP) and ota_from_target_files to produce
# payload.bin + payload_properties.txt for A/B OTA packages.
# Also supports creating update.zip (for adb sideload) and inspecting
# existing payload.bin files.
#
# Commands:
#   create-full    --target-files ZIP --output DIR [--key PEM] [--key-id ID]
#   create-delta   --source-files ZIP --target-files ZIP --output DIR [--key PEM]
#   create-zip     --payload DIR --output FILE   (wraps payload.bin into update.zip)
#   inspect        --payload FILE                (print DeltaArchiveManifest summary)
#   verify         --payload FILE [--pubkey FILE]
#   extract        --payload FILE --partition NAME --output FILE
#
# Requires: delta_generator (from AOSP build or prebuilt), python3
#
# Environment:
#   LOTA_DELTA_GENERATOR   Path to delta_generator binary
#   LOTA_OTA_TOOLS_DIR     Path to AOSP ota_tools directory
#   LOTA_SIGNING_KEY       Default signing key path

set -euo pipefail

CMD="${1:-}"
shift || true

DELTA_GENERATOR="${LOTA_DELTA_GENERATOR:-delta_generator}"
OTA_TOOLS_DIR="${LOTA_OTA_TOOLS_DIR:-}"
SIGNING_KEY="${LOTA_SIGNING_KEY:-}"

info() { echo "[lota-payload] $*"; }
warn() { echo "[lota-payload] WARN: $*" >&2; }
die()  { echo "[lota-payload] ERROR: $*" >&2; exit 1; }

require_delta_generator() {
  command -v "$DELTA_GENERATOR" &>/dev/null || \
    die "delta_generator not found — set LOTA_DELTA_GENERATOR or build from AOSP system/update_engine"
}

require_python3() {
  command -v python3 &>/dev/null || die "python3 required"
}

# Write payload_properties.txt from a payload.bin
write_payload_properties() {
  local payload="$1"
  local output_dir="$2"

  local sha256 size
  sha256=$(sha256sum "$payload" | awk '{print $1}')
  size=$(stat -c%s "$payload")

  # FILE_HASH and FILE_SIZE are what update_engine_client expects
  cat > "$output_dir/payload_properties.txt" <<EOF
FILE_HASH=$(echo -n "$sha256" | xxd -r -p | base64)
FILE_SIZE=$size
METADATA_HASH=
METADATA_SIZE=
EOF
  info "payload_properties.txt written"
}

cmd_create_full() {
  local target_files="" output_dir="" key="" key_id="1"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-files) target_files="$2"; shift 2 ;;
      --output)       output_dir="$2";   shift 2 ;;
      --key)          key="$2";          shift 2 ;;
      --key-id)       key_id="$2";       shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$target_files" ]] && die "--target-files required"
  [[ -z "$output_dir" ]]   && die "--output required"
  [[ ! -f "$target_files" ]] && die "Target files not found: $target_files"
  require_delta_generator
  require_python3

  mkdir -p "$output_dir"
  key="${key:-$SIGNING_KEY}"

  info "Creating full OTA payload from: $target_files"

  if [[ -n "$OTA_TOOLS_DIR" ]] && [[ -f "$OTA_TOOLS_DIR/ota_from_target_files" ]]; then
    # Use AOSP ota_from_target_files wrapper
    local ota_args=("$target_files" "$output_dir/payload.bin")
    [[ -n "$key" ]] && ota_args=(--key "$key" --key_id "$key_id" "${ota_args[@]}")
    python3 "$OTA_TOOLS_DIR/ota_from_target_files" "${ota_args[@]}"
  else
    # Direct delta_generator invocation
    local gen_args=(
      --type=full
      --out_file="$output_dir/payload.bin"
      --target_image="$target_files"
    )
    [[ -n "$key" ]] && gen_args+=(
      --private_key="$key"
      --public_key="${key%.pem}.pub.pem"
    )
    "$DELTA_GENERATOR" "${gen_args[@]}"
  fi

  write_payload_properties "$output_dir/payload.bin" "$output_dir"
  info "Full payload created: $output_dir/payload.bin"
}

cmd_create_delta() {
  local source_files="" target_files="" output_dir="" key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-files) source_files="$2"; shift 2 ;;
      --target-files) target_files="$2"; shift 2 ;;
      --output)       output_dir="$2";   shift 2 ;;
      --key)          key="$2";          shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$source_files" ]] && die "--source-files required"
  [[ -z "$target_files" ]] && die "--target-files required"
  [[ -z "$output_dir" ]]   && die "--output required"
  require_delta_generator

  mkdir -p "$output_dir"
  key="${key:-$SIGNING_KEY}"

  info "Creating delta OTA payload: $source_files → $target_files"

  local gen_args=(
    --type=delta
    --out_file="$output_dir/payload.bin"
    --source_image="$source_files"
    --target_image="$target_files"
  )
  [[ -n "$key" ]] && gen_args+=(
    --private_key="$key"
    --public_key="${key%.pem}.pub.pem"
  )
  "$DELTA_GENERATOR" "${gen_args[@]}"

  write_payload_properties "$output_dir/payload.bin" "$output_dir"
  info "Delta payload created: $output_dir/payload.bin"
}

cmd_create_zip() {
  local payload_dir="" output=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --payload) payload_dir="$2"; shift 2 ;;
      --output)  output="$2";      shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$payload_dir" ]] && die "--payload required"
  [[ -z "$output" ]]      && die "--output required"
  [[ ! -f "$payload_dir/payload.bin" ]] && die "payload.bin not found in: $payload_dir"

  info "Creating update.zip: $output"

  # A/B OTA zip layout:
  #   payload.bin
  #   payload_properties.txt
  #   META-INF/com/android/metadata
  #   META-INF/com/android/otacert (optional)

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT

  cp "$payload_dir/payload.bin" "$tmp_dir/"
  cp "$payload_dir/payload_properties.txt" "$tmp_dir/" 2>/dev/null || true

  mkdir -p "$tmp_dir/META-INF/com/android"
  cat > "$tmp_dir/META-INF/com/android/metadata" <<EOF
ota-type=AB
ota-required-cache=0
post-build=lota/$(date +%Y%m%d)
post-timestamp=$(date +%s)
EOF

  (cd "$tmp_dir" && zip -r "$output" .)
  info "update.zip created: $output"
}

cmd_inspect() {
  local payload=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --payload) payload="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$payload" ]] && die "--payload required"
  [[ ! -f "$payload" ]] && die "Payload not found: $payload"

  # Read the CrAU header manually
  local magic file_version manifest_size
  magic=$(dd if="$payload" bs=1 count=4 2>/dev/null | cat)
  [[ "$magic" != "CrAU" ]] && die "Not a valid payload.bin (magic mismatch)"

  # Read 8-byte big-endian file_format_version at offset 4
  file_version=$(dd if="$payload" bs=1 skip=4 count=8 2>/dev/null | od -An -tu8 | tr -d ' ')
  # Read 8-byte big-endian manifest_size at offset 12
  manifest_size=$(dd if="$payload" bs=1 skip=12 count=8 2>/dev/null | od -An -tu8 | tr -d ' ')

  echo "=== payload.bin ==="
  echo "Magic:            CrAU"
  echo "Format version:   $file_version"
  echo "Manifest size:    $manifest_size bytes"
  echo "File size:        $(stat -c%s "$payload") bytes"
  echo "SHA256:           $(sha256sum "$payload" | awk '{print $1}')"

  # If delta_generator is available, use it to dump the manifest
  if command -v "$DELTA_GENERATOR" &>/dev/null; then
    info "Dumping manifest via delta_generator"
    "$DELTA_GENERATOR" --in_file="$payload" --dump_manifest 2>/dev/null || true
  else
    warn "delta_generator not available — install for full manifest dump"
  fi
}

cmd_verify() {
  local payload="" pubkey=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --payload) payload="$2"; shift 2 ;;
      --pubkey)  pubkey="$2";  shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$payload" ]] && die "--payload required"
  require_delta_generator

  local args=(--in_file="$payload" --verify)
  [[ -n "$pubkey" ]] && args+=(--public_key="$pubkey")

  info "Verifying payload: $payload"
  "$DELTA_GENERATOR" "${args[@]}"
  info "Payload verification passed"
}

cmd_extract() {
  local payload="" partition="" output=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --payload)   payload="$2";   shift 2 ;;
      --partition) partition="$2"; shift 2 ;;
      --output)    output="$2";    shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$payload" ]]   && die "--payload required"
  [[ -z "$partition" ]] && die "--partition required"
  [[ -z "$output" ]]    && die "--output required"
  require_delta_generator

  info "Extracting partition '$partition' from payload"
  "$DELTA_GENERATOR" \
    --in_file="$payload" \
    --extract_partition="$partition" \
    --out_file="$output"
  info "Extracted: $output"
}

case "$CMD" in
  create-full)  cmd_create_full "$@" ;;
  create-delta) cmd_create_delta "$@" ;;
  create-zip)   cmd_create_zip "$@" ;;
  inspect)      cmd_inspect "$@" ;;
  verify)       cmd_verify "$@" ;;
  extract)      cmd_extract "$@" ;;
  "")  die "Usage: payload-tool.sh {create-full|create-delta|create-zip|inspect|verify|extract}" ;;
  *)   die "Unknown command: $CMD" ;;
esac
