//! config.rs — engine configuration loaded from system.toml

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Top-level engine configuration, mirrors system.toml structure.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineConfig {
    pub system: SystemConfig,
    pub slots: SlotsConfig,
    pub bootloader: BootloaderConfig,
    pub channels: ChannelsConfig,
    pub firmware: FirmwareConfig,
    pub dlc: DlcConfig,
    pub incus: IncusConfig,
    pub hooks: HooksConfig,
    pub logging: LoggingConfig,
    #[serde(default)]
    pub android: AndroidConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemConfig {
    pub name: String,
    pub arch: String,
    pub distro: String,
    pub filesystem: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlotsConfig {
    pub layout: SlotLayout,
    pub a: SlotDef,
    pub b: SlotDef,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SlotLayout {
    Ab,
    Single,
    Recovery,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlotDef {
    pub device: String,
    pub mountpoint: String,
    pub filesystem: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BootloaderConfig {
    #[serde(rename = "type")]
    pub bootloader_type: String,
    pub confirm_timeout_secs: u64,
    pub confirm_command: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChannelsConfig {
    pub active: String,
    pub server_url: String,
    pub lvfs_enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FirmwareConfig {
    pub policy: String,
    pub firmware_required: bool,
    pub dbus_service: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DlcConfig {
    pub enabled: bool,
    pub install_dir: PathBuf,
    pub manifest_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IncusConfig {
    pub enabled: bool,
    pub socket: PathBuf,
    pub instance_type: String,
    pub base_image: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HooksConfig {
    pub hook_dir: PathBuf,
    pub timeout_secs: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoggingConfig {
    pub level: String,
    pub destination: String,
    pub log_file: PathBuf,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AndroidConfig {
    pub enabled: bool,
    pub avb_mode: String,
    pub avb_key: String,
    pub avb_algorithm: String,
    pub bootctl_transport: String,
    pub adb_serial: String,
    pub bcb_device: String,
    pub virtual_ab: bool,
    pub payload_format: String,
    pub transport: String,
    #[serde(default)]
    pub waydroid: WaydroidConfig,
    #[serde(default)]
    pub halium: HaliumConfig,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct WaydroidConfig {
    pub enabled: bool,
    pub images_dir: String,
    pub channel: String,
    pub use_incus: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HaliumConfig {
    pub enabled: bool,
    pub distro: String,
    pub boot_device: String,
    pub system_device: String,
    pub vendor_device: String,
    pub rootfs_device: String,
}

impl EngineConfig {
    /// Load config from a TOML file, falling back to built-in defaults.
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("Reading config: {}", path.display()))?;
        toml::from_str(&text)
            .with_context(|| format!("Parsing config: {}", path.display()))
    }

    /// Load from the default search path:
    ///   1. /etc/lota/system.toml
    ///   2. ./config/system.toml (dev/test)
    pub fn load_default() -> Result<Self> {
        let candidates = [
            Path::new("/etc/lota/system.toml"),
            Path::new("config/system.toml"),
        ];
        for path in &candidates {
            if path.exists() {
                return Self::load(path);
            }
        }
        anyhow::bail!("No config found. Create /etc/lota/system.toml or config/system.toml")
    }

    /// Return the active channel's server URL.
    pub fn server_url(&self) -> &str {
        &self.channels.server_url
    }

    /// Return the inactive slot device path.
    pub fn inactive_slot_device(&self) -> &str {
        // Simplified: real impl reads current slot from slot-state.json
        &self.slots.b.device
    }
}
