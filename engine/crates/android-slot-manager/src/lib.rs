//! android-slot-manager — Android A/B slot management
//!
//! Implements the SlotManager trait for Android devices using:
//!   - `bootctl` CLI (on-device, via adb shell or direct)
//!   - BCB (Boot Control Block) direct manipulation via /dev/block/by-name/misc
//!   - Virtual A/B snapshot merge state tracking
//!
//! Slot device naming follows Android convention:
//!   boot_a / boot_b, system_a / system_b, vendor_a / vendor_b, vbmeta_a / vbmeta_b
//!
//! AVB mode is read from config and determines whether vbmeta is re-signed
//! after slot writes.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use slot_manager::{Slot, SlotManager, SlotState};

/// Android-specific slot configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AndroidSlotConfig {
    /// How to reach bootctl: Local (on-device) or Adb (from host).
    pub transport: BootctlTransport,
    /// AVB signing mode.
    pub avb_mode: AvbMode,
    /// Path to AVB signing key (required when avb_mode = Signed).
    pub avb_key: Option<String>,
    /// Virtual A/B: track snapshot merge state.
    pub virtual_ab: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BootctlTransport {
    /// Run bootctl directly (on-device).
    Local,
    /// Run bootctl via `adb -s <serial> shell bootctl`.
    Adb { serial: String },
    /// Manipulate BCB directly (no bootctl available).
    Bcb { misc_device: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AvbMode {
    Signed,
    Unlocked,
}

/// Virtual A/B snapshot merge status (mirrors IBootControl 1.1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SnapshotMergeStatus {
    None,
    Unknown,
    Snapshotted,
    Merging,
    Cancelled,
}

/// Android slot manager — delegates to bootctl-wrapper.sh.
pub struct AndroidSlotManager {
    config: AndroidSlotConfig,
    script_path: std::path::PathBuf,
}

impl AndroidSlotManager {
    pub fn new(config: AndroidSlotConfig, script_path: std::path::PathBuf) -> Self {
        Self { config, script_path }
    }

    /// Build the base command for bootctl-wrapper.sh, injecting ADB serial if needed.
    fn base_cmd(&self) -> tokio::process::Command {
        let mut cmd = tokio::process::Command::new(&self.script_path);
        match &self.config.transport {
            BootctlTransport::Adb { serial } => {
                cmd.env("LOTA_ANDROID_SERIAL", serial);
            }
            BootctlTransport::Bcb { misc_device } => {
                cmd.env("LOTA_BCB_DEVICE", misc_device);
            }
            BootctlTransport::Local => {}
        }
        if self.config.avb_mode == AvbMode::Unlocked {
            cmd.env("LOTA_AVB_MODE", "unlocked");
        } else {
            cmd.env("LOTA_AVB_MODE", "signed");
        }
        cmd
    }

    /// Get snapshot merge status (Virtual A/B).
    pub async fn snapshot_merge_status(&self) -> Result<SnapshotMergeStatus> {
        let out = self.base_cmd()
            .arg("get-snapshot-merge-status")
            .output()
            .await?;
        let s = String::from_utf8_lossy(&out.stdout).trim().to_lowercase();
        Ok(match s.as_str() {
            "snapshotted" => SnapshotMergeStatus::Snapshotted,
            "merging"     => SnapshotMergeStatus::Merging,
            "cancelled"   => SnapshotMergeStatus::Cancelled,
            "none" | ""   => SnapshotMergeStatus::None,
            _             => SnapshotMergeStatus::Unknown,
        })
    }

    /// Set snapshot merge status (Virtual A/B).
    pub async fn set_snapshot_merge_status(&self, status: SnapshotMergeStatus) -> Result<()> {
        let s = match status {
            SnapshotMergeStatus::None        => "none",
            SnapshotMergeStatus::Snapshotted => "snapshotted",
            SnapshotMergeStatus::Merging     => "merging",
            SnapshotMergeStatus::Cancelled   => "cancelled",
            SnapshotMergeStatus::Unknown     => "none",
        };
        let status = self.base_cmd()
            .arg("set-snapshot-merge-status")
            .arg(s)
            .status()
            .await?;
        anyhow::ensure!(status.success(), "set-snapshot-merge-status failed");
        Ok(())
    }

    /// Return the block device path for a named Android partition + slot suffix.
    /// e.g. partition="system", slot=B → /dev/block/by-name/system_b
    pub fn partition_device(partition: &str, slot: Slot) -> String {
        format!("/dev/block/by-name/{}_{}", partition, slot.as_str())
    }
}

#[async_trait::async_trait]
impl SlotManager for AndroidSlotManager {
    async fn state(&self) -> Result<SlotState> {
        let current_out = self.base_cmd()
            .arg("get-current-slot")
            .output()
            .await?;
        let current_str = String::from_utf8_lossy(&current_out.stdout).trim().to_lowercase();
        let active = match current_str.as_str() {
            "a" => Slot::A,
            "b" => Slot::B,
            _   => anyhow::bail!("Unexpected slot: {}", current_str),
        };
        let inactive = active.other();

        // Check if current slot is marked successful
        let succ_out = self.base_cmd()
            .arg("is-successful")
            .arg(active.as_str())
            .output()
            .await?;
        let boot_confirmed = succ_out.status.success();

        Ok(SlotState {
            active,
            inactive,
            boot_attempts: 0, // Android tracks this in bootloader, not exposed via bootctl CLI
            boot_confirmed,
            active_version: String::new(), // populated by engine from build props
            inactive_version: None,
        })
    }

    async fn set_next_boot(&self, slot: Slot) -> Result<()> {
        // On Android, before switching slots we must ensure no VAB merge is in progress
        if self.config.virtual_ab {
            let merge = self.snapshot_merge_status().await?;
            if merge == SnapshotMergeStatus::Merging {
                anyhow::bail!("Cannot switch slots: Virtual A/B merge in progress");
            }
        }

        let status = self.base_cmd()
            .arg("set-active")
            .arg(slot.as_str())
            .status()
            .await?;
        anyhow::ensure!(status.success(), "set-active failed for slot {}", slot.as_str());
        Ok(())
    }

    async fn confirm_boot(&self) -> Result<()> {
        let status = self.base_cmd()
            .arg("mark-successful")
            .status()
            .await?;
        anyhow::ensure!(status.success(), "mark-successful failed");
        Ok(())
    }

    async fn rollback(&self) -> Result<()> {
        let state = self.state().await?;
        // Switch back to the previously active slot
        self.set_next_boot(state.inactive).await?;
        tracing::info!("Android rollback: switching to slot {}", state.inactive.as_str());
        Ok(())
    }

    async fn slot_device(&self, slot: Slot) -> Result<String> {
        // Android uses by-name symlinks; system partition is the primary rootfs
        Ok(Self::partition_device("system", slot))
    }
}

/// BCB (Boot Control Block) layout in the `misc` partition.
/// Used when bootctl is unavailable (e.g. flashing from a Linux host).
#[repr(C)]
pub struct BootloaderMessage {
    pub command: [u8; 32],
    pub status: [u8; 32],
    pub recovery: [u8; 768],
    pub stage: [u8; 32],
    pub reserved: [u8; 1184],
}

impl BootloaderMessage {
    pub const SIZE: usize = 2048;

    /// Write a BCB to the misc partition device.
    pub async fn write_to_device(device: &str, msg: &BootloaderMessage) -> Result<()> {
        use tokio::io::AsyncWriteExt;
        let bytes = unsafe {
            std::slice::from_raw_parts(
                msg as *const _ as *const u8,
                Self::SIZE,
            )
        };
        let mut f = tokio::fs::OpenOptions::new()
            .write(true)
            .open(device)
            .await
            .with_context(|| format!("Opening misc device: {}", device))?;
        f.write_all(bytes).await?;
        f.flush().await?;
        Ok(())
    }

    /// Set the BCB command to boot into recovery for sideload.
    pub fn for_sideload() -> Self {
        let mut msg = Self::zeroed();
        let cmd = b"boot-recovery";
        msg.command[..cmd.len()].copy_from_slice(cmd);
        let recovery = b"\nrecovery\n--sideload\n";
        msg.recovery[..recovery.len()].copy_from_slice(recovery);
        msg
    }

    fn zeroed() -> Self {
        Self {
            command: [0u8; 32],
            status: [0u8; 32],
            recovery: [0u8; 768],
            stage: [0u8; 32],
            reserved: [0u8; 1184],
        }
    }
}
