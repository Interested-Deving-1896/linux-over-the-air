# linux-over-the-air

Unified OTA update engine for Linux and Android/AOSP systems.

Distro-, arch-, filesystem-, and bootloader-agnostic. Synthesises the update
mechanisms from ~25 upstream projects (ChromeOS update_engine, RAUC, SWUpdate,
hawkBit, fwupd, Omaha, Nebraska, and others) into a single coherent system.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  lota CLI (Go)          lota android (Go)                   │
│  update / status /      flash / sideload / sign /           │
│  rollback / channel     waydroid / halium / payload         │
└──────────────┬──────────────────────┬───────────────────────┘
               │                      │
┌──────────────▼──────────────────────▼───────────────────────┐
│  update-engine (Rust)                                        │
│  ┌─────────────┐ ┌──────────────┐ ┌────────────────────┐   │
│  │ omaha-client│ │ slot-manager │ │   fwupd-client     │   │
│  │ hawkBit DDI │ │ android-slot │ │   D-Bus / shell    │   │
│  └─────────────┘ └──────────────┘ └────────────────────┘   │
│  ┌─────────────┐ ┌──────────────┐ ┌────────────────────┐   │
│  │ delta-apply │ │  payload-bin │ │   hooks runner     │   │
│  │ bsdiff/zstd │ │  CrAU format │ │   /etc/lota/hooks.d│   │
│  └─────────────┘ └──────────────┘ └────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────────────────┐
│  Runtime shell scripts                                       │
│  Linux:   confirm-boot  install-handler  fwupd-coordinator  │
│           incus-ota     hook-runner                         │
│  Android: avb-sign  bootctl-wrapper  fastboot-flash         │
│           adb-sideload  payload-tool  waydroid-ota          │
│           halium-ota                                        │
└──────────────────────────────────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────────────────┐
│  Update servers                                              │
│  Nebraska (Omaha v3 mock)    hawkBit DDI (fleet management) │
└──────────────────────────────────────────────────────────────┘
```

## Features

**Linux OTA**
- A/B slot updates with automatic rollback on boot failure
- Delta payloads (bsdiff/zstd) and full image updates
- Filesystem-agnostic: ext4, btrfs, xfs, f2fs, squashfs, erofs, ubifs, raw
- Bootloader-agnostic: GRUB2, systemd-boot, U-Boot, Barebox, RAUC, EFI stub
- fwupd firmware coordination (before/after OS update, EFI capsule awareness)
- Incus-based isolated staging (replaces Docker/Podman)
- Pre/post update hooks with phase routing and retry support
- DLC (Downloadable Content) subsystem

**Android/AOSP OTA**
- A/B slot management via bootctl HAL
- payload.bin (CrAU format) — produce and consume
- AVB 2.0 signing: signed (avbtool) and unlocked (VERIFICATION_DISABLED) modes
- Virtual A/B with snapshot merge state tracking
- Transport matrix: fastboot, fastbootd, ADB sideload, network OTA
- GSI (Generic System Image) flashing workflow
- Waydroid container image updates + APK/OBB sideload
- Halium hardware adaptation layer updates (Droidian, Ubuntu Touch, postmarketOS)

**Update servers**
- Nebraska: lightweight Omaha v3 mock server for local testing and CI
- hawkBit DDI: fleet management with rollout campaigns and device feedback
- Both serve Linux and Android bundles from the same package directory

## Quick start

### Build the engine

```bash
cd engine
cargo build --release
```

### Build the CLI

```bash
cd client/cli
go build -o lota ./cmd/lota/
```

### Run the update server

```bash
# Omaha (Nebraska)
python3 server/nebraska/nebraska.py --port 8080 --packages-dir ./packages

# hawkBit DDI
python3 server/hawkbit/server.py --port 8081 --packages-dir ./packages
```

### Create an update bundle

```bash
# Linux bundle
packaging/bundle/bundle.sh create \
  --version 1.2.0 \
  --arch amd64 \
  --payload rootfs.img \
  --output ./bundles

# Android bundle
packaging/bundle/android-bundle.sh create \
  --version 1.2.0 \
  --arch arm64 \
  --system system.img \
  --boot boot.img \
  --avb-mode unlocked \
  --transport all \
  --output ./bundles
```

### Apply an update

```bash
# Check for update
lota update --check-only

# Apply update
lota update

# Android: flash via fastboot
lota android flash --bundle ./bundles/android-bundle-1.2.0-arm64.lota --serial ABC123

# Android: sideload via ADB
lota android sideload --package ./bundles/android-bundle-1.2.0-arm64.lota/update.zip
```

## Configuration

Copy `config/system.toml` to `/etc/lota/system.toml` and edit:

```toml
[system]
arch = "amd64"
distro = "debian"
filesystem = "ext4"

[channels]
active = "stable"
server_url = "http://your-server:8080"

[firmware]
policy = "before_os"

[android]
enabled = false   # set true for Android targets
avb_mode = "unlocked"
```

## Supported architectures

Linux: amd64, arm64, armhf, armel, riscv64, s390x, ppc64el, mips64el, loong64, i386

Android: arm64, arm, x86_64, x86, riscv64

## Related projects

- [penguins-over-the-air](https://github.com/Interested-Deving-1896/penguins-over-the-air) — Debian/Devuan fork
- [btrfs-dwarfs-framework](https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework) — fwupd integration
- [xanmod-unified-kernel](https://github.com/Interested-Deving-1896/xanmod-unified-kernel) — kernel build system

## License

Apache-2.0
