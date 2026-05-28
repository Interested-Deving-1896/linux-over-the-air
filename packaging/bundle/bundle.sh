#!/usr/bin/env bash
# bundle.sh — OTA update bundle creation
#
# Produces a signed, versioned update bundle consumable by the lota engine.
# Supports full image, delta (bsdiff), and tar payload types.
#
# Bundle layout:
#   bundle-{version}-{arch}.lota/
#     manifest.json       Metadata: version, arch, channel, payload type, hashes
#     payload             The update payload (image, delta, or tar)
#     payload.sig         Ed25519 signature over payload
#     manifest.sig        Ed25519 signature over manifest.json
#
# Usage:
#   bundle.sh create --version VER --arch ARCH --payload FILE [options]
#   bundle.sh verify --bundle DIR
#   bundle.sh inspect --bundle DIR

set -euo pipefail

CMD="${1:-}"
shift || true

VERSION=""
ARCH=""
PAYLOAD_FILE=""
PAYLOAD_TYPE="full"
CHANNEL="stable"
DISTRO=""
FILESYSTEM=""
SIGNING_KEY=""
OUTPUT_DIR="."
BUNDLE_DIR=""

info() { echo "[lota-bundle] $*"; }
die()  { echo "[lota-bundle] ERROR: $*" >&2; exit 1; }

cmd_create() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)    VERSION="$2";      shift 2 ;;
      --arch)       ARCH="$2";         shift 2 ;;
      --payload)    PAYLOAD_FILE="$2"; shift 2 ;;
      --type)       PAYLOAD_TYPE="$2"; shift 2 ;;
      --channel)    CHANNEL="$2";      shift 2 ;;
      --distro)     DISTRO="$2";       shift 2 ;;
      --filesystem) FILESYSTEM="$2";   shift 2 ;;
      --signing-key) SIGNING_KEY="$2"; shift 2 ;;
      --output)     OUTPUT_DIR="$2";   shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -z "$VERSION" ]]      && die "--version required"
  [[ -z "$ARCH" ]]         && die "--arch required"
  [[ -z "$PAYLOAD_FILE" ]] && die "--payload required"
  [[ ! -f "$PAYLOAD_FILE" ]] && die "Payload not found: $PAYLOAD_FILE"

  BUNDLE_NAME="bundle-${VERSION}-${ARCH}.lota"
  BUNDLE_PATH="${OUTPUT_DIR}/${BUNDLE_NAME}"

  [[ -d "$BUNDLE_PATH" ]] && die "Bundle already exists: $BUNDLE_PATH"
  mkdir -p "$BUNDLE_PATH"

  info "Creating bundle: $BUNDLE_NAME"

  # Copy payload
  cp "$PAYLOAD_FILE" "$BUNDLE_PATH/payload"

  # Compute hashes
  PAYLOAD_SHA256=$(sha256sum "$BUNDLE_PATH/payload" | awk '{print $1}')
  PAYLOAD_SIZE=$(stat -c%s "$BUNDLE_PATH/payload")

  # Write manifest
  cat > "$BUNDLE_PATH/manifest.json" <<EOF
{
  "version": "${VERSION}",
  "arch": "${ARCH}",
  "channel": "${CHANNEL}",
  "distro": "${DISTRO}",
  "filesystem": "${FILESYSTEM}",
  "payload_type": "${PAYLOAD_TYPE}",
  "payload_sha256": "${PAYLOAD_SHA256}",
  "payload_size": ${PAYLOAD_SIZE},
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "format_version": "1"
}
EOF

  # Sign if key provided
  if [[ -n "$SIGNING_KEY" ]]; then
    if command -v openssl &>/dev/null; then
      openssl dgst -sha256 -sign "$SIGNING_KEY" \
        -out "$BUNDLE_PATH/payload.sig" "$BUNDLE_PATH/payload"
      openssl dgst -sha256 -sign "$SIGNING_KEY" \
        -out "$BUNDLE_PATH/manifest.sig" "$BUNDLE_PATH/manifest.json"
      info "Signed with: $SIGNING_KEY"
    else
      die "openssl not found — cannot sign bundle"
    fi
  else
    info "WARNING: Bundle is unsigned (no --signing-key provided)"
  fi

  info "Bundle created: $BUNDLE_PATH"
  info "  Payload type:  $PAYLOAD_TYPE"
  info "  Payload size:  $PAYLOAD_SIZE bytes"
  info "  SHA256:        $PAYLOAD_SHA256"
}

cmd_verify() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bundle) BUNDLE_DIR="$2"; shift 2 ;;
      --pubkey) PUBKEY="$2";     shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -z "$BUNDLE_DIR" ]] && die "--bundle required"
  [[ ! -d "$BUNDLE_DIR" ]] && die "Bundle not found: $BUNDLE_DIR"

  PUBKEY="${PUBKEY:-}"

  info "Verifying bundle: $BUNDLE_DIR"

  # Check required files
  for f in manifest.json payload; do
    [[ ! -f "$BUNDLE_DIR/$f" ]] && die "Missing: $f"
  done

  # Verify payload hash
  EXPECTED_SHA256=$(python3 -c "import json; d=json.load(open('$BUNDLE_DIR/manifest.json')); print(d['payload_sha256'])")
  ACTUAL_SHA256=$(sha256sum "$BUNDLE_DIR/payload" | awk '{print $1}')

  if [[ "$EXPECTED_SHA256" != "$ACTUAL_SHA256" ]]; then
    die "Payload hash mismatch: expected $EXPECTED_SHA256, got $ACTUAL_SHA256"
  fi
  info "  ✓ Payload hash matches"

  # Verify signatures if pubkey provided
  if [[ -n "$PUBKEY" ]]; then
    if [[ ! -f "$BUNDLE_DIR/payload.sig" ]]; then
      die "No signature found but --pubkey provided"
    fi
    openssl dgst -sha256 -verify "$PUBKEY" \
      -signature "$BUNDLE_DIR/payload.sig" "$BUNDLE_DIR/payload" \
      || die "Payload signature verification failed"
    openssl dgst -sha256 -verify "$PUBKEY" \
      -signature "$BUNDLE_DIR/manifest.sig" "$BUNDLE_DIR/manifest.json" \
      || die "Manifest signature verification failed"
    info "  ✓ Signatures valid"
  else
    info "  ~ Signature check skipped (no --pubkey)"
  fi

  info "Bundle OK"
}

cmd_inspect() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bundle) BUNDLE_DIR="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -z "$BUNDLE_DIR" ]] && die "--bundle required"
  [[ ! -f "$BUNDLE_DIR/manifest.json" ]] && die "Not a valid bundle: $BUNDLE_DIR"

  cat "$BUNDLE_DIR/manifest.json"
}

case "$CMD" in
  create)  cmd_create "$@" ;;
  verify)  cmd_verify "$@" ;;
  inspect) cmd_inspect "$@" ;;
  "")      die "Usage: bundle.sh {create|verify|inspect} [options]" ;;
  *)       die "Unknown command: $CMD" ;;
esac
