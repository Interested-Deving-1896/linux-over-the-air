//! slot-manager — A/B slot state and bootloader integration
//!
//! Abstracts over bootloader-specific slot management:
//!   - GRUB2 (grub-editenv, grubenv)
//!   - systemd-boot (loader/entries)
//!   - U-Boot (fw_setenv/fw_printenv)
//!   - Barebox (barebox-state)
//!   - RAUC (rauc status)
//!   - Custom (shell hook delegation)
//!
//! Slot state is persisted in /var/lib/lota/slot-state.json.

use anyhow::Result;
use serde::{Deserialize, Serialize};

/// Which A/B slot is active.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Slot {
    A,
    B,
}

impl Slot {
    pub fn other(self) -> Self {
        match self {
            Slot::A => Slot::B,
            Slot::B => Slot::A,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Slot::A => "a",
            Slot::B => "b",
        }
    }
}

/// Persistent slot state written to disk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlotState {
    pub active: Slot,
    pub inactive: Slot,
    pub boot_attempts: u8,
    pub boot_confirmed: bool,
    pub active_version: String,
    pub inactive_version: Option<String>,
}

/// Bootloader backend variants.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Bootloader {
    Grub2,
    SystemdBoot,
    UBoot,
    Barebox,
    Rauc,
    EfiStub,
    Custom,
}

/// Core trait for slot management operations.
#[async_trait::async_trait]
pub trait SlotManager: Send + Sync {
    /// Return current slot state.
    async fn state(&self) -> Result<SlotState>;

    /// Mark the inactive slot as the next boot target.
    async fn set_next_boot(&self, slot: Slot) -> Result<()>;

    /// Confirm the current boot (prevent rollback).
    async fn confirm_boot(&self) -> Result<()>;

    /// Roll back: set the previous slot as next boot.
    async fn rollback(&self) -> Result<()>;

    /// Return the device path for a given slot (e.g. /dev/sda2).
    async fn slot_device(&self, slot: Slot) -> Result<String>;
}

/// Shell-delegating slot manager — calls confirm-boot.sh for all operations.
pub struct ShellSlotManager {
    pub script_path: std::path::PathBuf,
    pub bootloader: Bootloader,
}

#[async_trait::async_trait]
impl SlotManager for ShellSlotManager {
    async fn state(&self) -> Result<SlotState> {
        // Reads /var/lib/lota/slot-state.json
        let path = std::path::Path::new("/var/lib/lota/slot-state.json");
        let data = tokio::fs::read_to_string(path).await?;
        Ok(serde_json::from_str(&data)?)
    }

    async fn set_next_boot(&self, slot: Slot) -> Result<()> {
        let status = tokio::process::Command::new(&self.script_path)
            .arg("--set-next")
            .arg(slot.as_str())
            .status()
            .await?;
        anyhow::ensure!(status.success(), "confirm-boot.sh --set-next failed");
        Ok(())
    }

    async fn confirm_boot(&self) -> Result<()> {
        let status = tokio::process::Command::new(&self.script_path)
            .arg("--confirm")
            .status()
            .await?;
        anyhow::ensure!(status.success(), "confirm-boot.sh --confirm failed");
        Ok(())
    }

    async fn rollback(&self) -> Result<()> {
        let status = tokio::process::Command::new(&self.script_path)
            .arg("--rollback")
            .status()
            .await?;
        anyhow::ensure!(status.success(), "confirm-boot.sh --rollback failed");
        Ok(())
    }

    async fn slot_device(&self, slot: Slot) -> Result<String> {
        // Reads from /etc/lota/slot-devices.conf: "a=/dev/sda2\nb=/dev/sda3"
        let conf = std::fs::read_to_string("/etc/lota/slot-devices.conf")
            .unwrap_or_default();
        for line in conf.lines() {
            if let Some((k, v)) = line.split_once('=') {
                if k.trim() == slot.as_str() {
                    return Ok(v.trim().to_string());
                }
            }
        }
        anyhow::bail!("No device configured for slot {}", slot.as_str())
    }
}
