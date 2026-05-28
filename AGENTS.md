# AGENTS.md — linux-over-the-air

Guidance for AI agents working in this repository.

## Repository purpose

Unified OTA update engine for Linux and Android/AOSP systems. Distro-, arch-,
filesystem-, and bootloader-agnostic. Replaces Docker/Podman with Incus throughout.

## Language map

| Path | Language | Role |
|---|---|---|
| `engine/` | Rust | Core update orchestration, slot management, delta application |
| `client/cli/` | Go | `lota` CLI, delegates to runtime scripts and engine daemon |
| `server/nebraska/` | Python | Omaha v3 mock server for testing |
| `server/hawkbit/` | Python | hawkBit DDI server for fleet management |
| `runtime/` | Bash | All device interactions (bootloader, filesystem, firmware, Android) |
| `packaging/bundle/` | Bash | Bundle creation and verification |
| `config/` | TOML | System and channel configuration |

## Architecture rules

- **Incus replaces Docker/Podman everywhere.** Never add Docker or Podman dependencies.
- **Shell scripts are the device interface.** Rust/Go code calls shell scripts for all
  hardware interactions. This keeps the engine portable and testable without hardware.
- **Android is first-class.** All new features must consider both Linux and Android paths.
  Android-specific code lives in `runtime/android/`, `engine/crates/android-slot-manager/`,
  and `client/cli/cmd/lota/android.go`.
- **No distro assumptions in the engine.** Distro-specific logic belongs in hooks
  (`/etc/lota/hooks.d/`) or in `penguins-over-the-air`.

## Rust engine

Workspace root: `engine/Cargo.toml`. Seven crates:

| Crate | Purpose |
|---|---|
| `update-engine` | Orchestration, `UpdateEngine` trait, `Phase` enum |
| `slot-manager` | `SlotManager` trait, `ShellSlotManager` |
| `delta-apply` | bsdiff/zstd/tar/full-image payload application |
| `omaha-client` | Omaha v3 XML + hawkBit DDI HTTP client |
| `fwupd-client` | D-Bus fwupd client + `ShellFwupdClient` fallback |
| `android-slot-manager` | Android bootctl HAL impl, BCB struct |
| `payload-bin` | CrAU format reader/writer, `update_metadata.proto` |

Adding a new crate: add it to `engine/Cargo.toml` `[workspace] members`, add shared
deps to `[workspace.dependencies]`, reference with `dep.workspace = true`.

## Shell scripts

All scripts follow this pattern:
- `set -euo pipefail` at the top
- `CMD="${1:-}"` + `shift` for subcommand dispatch
- `info()` / `warn()` / `die()` helpers
- Exit 0 on success, non-zero on failure
- Environment variables for configuration (`LOTA_*` prefix)

Scripts must pass `shellcheck --severity=warning`. Run:
```
find runtime/ client/hooks/ packaging/ -name '*.sh' | xargs shellcheck --severity=warning
```

## Android support

Four transport modes are supported: `fastboot`, `adb`, `network`, `all`.

AVB mode is controlled by `config/system.toml` `[android].avb_mode`:
- `signed` — requires `avb_key` PEM path
- `unlocked` — produces `VERIFICATION_DISABLED` vbmeta, no key needed

Android app IDs in Omaha requests:
- `{android-*}` — standard Android device
- `{waydroid-*}` — Waydroid container on Linux
- `{halium-*}` — Halium hardware adaptation layer

## Python server

Nebraska (`server/nebraska/nebraska.py`) is the primary Omaha server.
hawkBit (`server/hawkbit/server.py`) is the fleet management server.
Both share `PackageRegistry` from Nebraska.

Android routing is in `server/omaha/android.py`, loaded dynamically by Nebraska.

Run Nebraska:
```
python3 server/nebraska/nebraska.py --port 8080 --packages-dir ./packages
```

Run hawkBit:
```
python3 server/hawkbit/server.py --port 8081 --packages-dir ./packages
```

## Configuration

`config/system.toml` — system config (slots, bootloader, firmware, Android)
`config/channels.toml` — channel definitions

Override at runtime: `/etc/lota/system.toml`

## Testing

```bash
# Rust
cd engine && cargo test --all

# Go
cd client/cli && go test ./...

# Python smoke test
python3 -c "import sys; sys.path.insert(0,'server/nebraska'); from nebraska import parse_omaha_request"

# Shell
find runtime/ -name '*.sh' | xargs shellcheck --severity=warning

# Bundle smoke test
packaging/bundle/bundle.sh create --version 0.0.1-test --arch amd64 --payload /dev/urandom --output /tmp/test
```

## Commit conventions

Follow conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`.
Scope with the subsystem: `feat(android):`, `fix(engine):`, `chore(ci):`.

## Related repositories

- `penguins-over-the-air` — Debian/Devuan fork with fwupd hooks and penguins-eggs integration
- `penguins-eggs` — `all-features` branch wires penguins-over-the-air as a component
- `btrfs-dwarfs-framework` — fwupd integration (PR #12)
- `xanmod-unified-kernel` — kernel build system that produces update payloads
