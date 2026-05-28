#!/usr/bin/env bash
# incus-ota.sh — Incus integration for linux-over-the-air
#
# Replaces Docker/Podman for OTA update staging and testing.
# Incus supports KVM VMs, QEMU disk images, and OCI containers
# under a single API — making it strictly better for a distro-agnostic
# OTA system that needs to test updates across different environments.
#
# Commands:
#   stage       Create an Incus instance for staging an update
#   test        Run an update in an isolated VM/container and verify
#   image       Build an Incus image from an OTA payload
#   clean       Remove staging instances and images
#   status      Show active OTA instances
#
# Instance types:
#   container   Lightweight, fast — for testing update scripts and hooks
#   vm          Full KVM VM — for testing bootloader confirmation, EFI, kernel
#   qemu-img    QEMU disk image — for testing raw image installs offline
#
# Usage:
#   incus-ota.sh stage  --type container|vm [--image IMAGE] [--name NAME]
#   incus-ota.sh test   --payload PATH [--type container|vm] [--arch ARCH]
#   incus-ota.sh image  --payload PATH --out PATH [--format qcow2|raw|oci]
#   incus-ota.sh clean  [--all] [--name NAME]
#   incus-ota.sh status

set -euo pipefail

INCUS_CMD="${INCUS_CMD:-incus}"
LOTA_INCUS_PREFIX="${LOTA_INCUS_PREFIX:-lota-ota}"
LOTA_BASE_IMAGE="${LOTA_BASE_IMAGE:-images:debian/trixie}"
LOTA_INSTANCE_TYPE="${LOTA_INSTANCE_TYPE:-container}"

info()  { echo "[lota-incus] $*"; }
warn()  { echo "[lota-incus] WARN: $*" >&2; }
die()   { echo "[lota-incus] ERROR: $*" >&2; exit 1; }

require_incus() {
  command -v "$INCUS_CMD" &>/dev/null \
    || die "incus not found — install from https://linuxcontainers.org/incus/"
}

# ── stage ─────────────────────────────────────────────────────────────────────
cmd_stage() {
  local type="$LOTA_INSTANCE_TYPE" image="$LOTA_BASE_IMAGE" name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type)  type="$2";  shift 2 ;;
      --image) image="$2"; shift 2 ;;
      --name)  name="$2";  shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  require_incus
  [[ -z "$name" ]] && name="${LOTA_INCUS_PREFIX}-$(date +%s)"

  info "Creating $type instance: $name (base: $image)"

  case "$type" in
    container)
      "$INCUS_CMD" launch "$image" "$name"
      ;;
    vm)
      "$INCUS_CMD" launch "$image" "$name" --vm \
        --config limits.cpu=2 \
        --config limits.memory=2GiB
      ;;
    *)
      die "Unknown instance type: $type (valid: container, vm)"
      ;;
  esac

  # Install lota tools into the instance
  info "Installing lota tools into $name"
  "$INCUS_CMD" file push /usr/local/bin/lota "$name/usr/local/bin/lota" 2>/dev/null || true
  "$INCUS_CMD" file push /etc/lota/system.toml "$name/etc/lota/system.toml" 2>/dev/null || true

  info "Instance ready: $name"
  info "  Enter: $INCUS_CMD exec $name -- bash"
  echo "$name"
}

# ── test ──────────────────────────────────────────────────────────────────────
cmd_test() {
  local payload="" type="$LOTA_INSTANCE_TYPE" arch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --payload) payload="$2"; shift 2 ;;
      --type)    type="$2";    shift 2 ;;
      --arch)    arch="$2";    shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -z "$payload" ]] && die "--payload required"
  require_incus

  local name="${LOTA_INCUS_PREFIX}-test-$(date +%s)"
  local image="$LOTA_BASE_IMAGE"

  # Select arch-appropriate base image
  if [[ -n "$arch" ]]; then
    case "$arch" in
      arm64)   image="images:debian/trixie/arm64" ;;
      armhf)   image="images:debian/trixie/armhf" ;;
      riscv64) image="images:debian/trixie/riscv64" ;;
      *)       image="images:debian/trixie" ;;
    esac
  fi

  info "Testing update payload in $type instance (arch: ${arch:-native})"

  # Create instance
  local instance
  instance=$(cmd_stage --type "$type" --image "$image" --name "$name")

  # Push payload
  info "Pushing payload to instance"
  "$INCUS_CMD" file push "$payload" "${instance}/tmp/update.payload"

  # Run install
  info "Running install-handler in instance"
  "$INCUS_CMD" exec "$instance" -- bash -c \
    "lota install --payload /tmp/update.payload --dry-run" 2>&1 || {
    warn "Install test failed in instance $instance"
    "$INCUS_CMD" stop "$instance" --force 2>/dev/null || true
    return 1
  }

  info "Test passed in instance $instance"

  # Cleanup
  "$INCUS_CMD" stop "$instance" --force 2>/dev/null || true
  "$INCUS_CMD" delete "$instance" 2>/dev/null || true
  info "Test instance cleaned up"
}

# ── image ─────────────────────────────────────────────────────────────────────
cmd_image() {
  local payload="" out="" format="qcow2"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --payload) payload="$2"; shift 2 ;;
      --out)     out="$2";     shift 2 ;;
      --format)  format="$2";  shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -z "$payload" ]] && die "--payload required"
  [[ -z "$out"     ]] && die "--out required"
  require_incus

  info "Building Incus image from payload: $payload"

  case "$format" in
    qcow2)
      # Use qemu-img to convert raw payload to qcow2
      command -v qemu-img &>/dev/null || die "qemu-img not found"
      qemu-img convert -f raw -O qcow2 "$payload" "$out"
      info "QEMU image written: $out"
      ;;
    raw)
      cp "$payload" "$out"
      info "Raw image written: $out"
      ;;
    oci)
      # Import as Incus OCI image
      "$INCUS_CMD" image import "$payload" --alias "lota-update-$(date +%Y%m%d)"
      info "OCI image imported into Incus"
      ;;
    *)
      die "Unknown format: $format (valid: qcow2, raw, oci)"
      ;;
  esac
}

# ── clean ─────────────────────────────────────────────────────────────────────
cmd_clean() {
  local all=false name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)  all=true;  shift ;;
      --name) name="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  require_incus

  if [[ -n "$name" ]]; then
    info "Removing instance: $name"
    "$INCUS_CMD" stop "$name" --force 2>/dev/null || true
    "$INCUS_CMD" delete "$name"
  elif $all; then
    info "Removing all lota OTA instances"
    "$INCUS_CMD" list --format csv --columns n 2>/dev/null \
      | grep "^${LOTA_INCUS_PREFIX}-" \
      | while read -r inst; do
          info "  Removing: $inst"
          "$INCUS_CMD" stop "$inst" --force 2>/dev/null || true
          "$INCUS_CMD" delete "$inst" 2>/dev/null || true
        done
  else
    die "Specify --name NAME or --all"
  fi
}

# ── status ────────────────────────────────────────────────────────────────────
cmd_status() {
  require_incus
  echo "=== lota Incus instances ==="
  "$INCUS_CMD" list "${LOTA_INCUS_PREFIX}-" 2>/dev/null || \
    "$INCUS_CMD" list 2>/dev/null | grep "${LOTA_INCUS_PREFIX}" || \
    echo "(none)"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && { echo "Usage: incus-ota.sh <stage|test|image|clean|status> [options]"; exit 0; }
CMD="$1"; shift
case "$CMD" in
  stage)  cmd_stage  "$@" ;;
  test)   cmd_test   "$@" ;;
  image)  cmd_image  "$@" ;;
  clean)  cmd_clean  "$@" ;;
  status) cmd_status "$@" ;;
  *) die "Unknown command: $CMD" ;;
esac
