//! update-engine — core OTA orchestration
//!
//! Coordinates the full update lifecycle:
//!   1. Check for updates via Omaha/hawkBit
//!   2. Apply firmware updates (pre-OS, per policy)
//!   3. Download and verify the payload
//!   4. Write payload to the inactive slot
//!   5. Confirm boot after successful first boot
//!   6. Apply firmware updates (post-OS, per policy)
//!
//! The engine is distro-, arch-, and filesystem-agnostic. All
//! platform-specific behaviour is delegated to the slot-manager,
//! delta-apply, and fwupd-client crates, plus shell hooks.

use anyhow::Result;
use serde::{Deserialize, Serialize};

pub mod config;
pub mod engine;
pub mod hooks;
pub mod payload;
pub mod verify;

/// Update lifecycle phases, in execution order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Idle,
    CheckingForUpdate,
    UpdateAvailable,
    Downloading,
    Verifying,
    FirmwarePreOs,
    Installing,
    BootConfirmPending,
    FirmwarePostOs,
    Updated,
    Error,
    RolledBack,
}

/// Describes an available update returned by the update server.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateInfo {
    pub version: String,
    pub channel: String,
    pub arch: String,
    pub payload_url: String,
    pub payload_sha256: String,
    pub payload_size: u64,
    pub payload_type: PayloadType,
    pub is_delta: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PayloadType {
    Full,
    Delta,
    Tar,
    OstreeCommit,
}

/// Core trait implemented by the update engine.
#[async_trait::async_trait]
pub trait UpdateEngine: Send + Sync {
    /// Check the update server for a newer version.
    async fn check_for_update(&self) -> Result<Option<UpdateInfo>>;

    /// Download the payload to a local staging path.
    async fn download(&self, info: &UpdateInfo, dest: &std::path::Path) -> Result<()>;

    /// Verify payload integrity and signature.
    async fn verify(&self, info: &UpdateInfo, payload: &std::path::Path) -> Result<()>;

    /// Install the payload into the inactive slot.
    async fn install(&self, info: &UpdateInfo, payload: &std::path::Path) -> Result<()>;

    /// Mark the inactive slot as the next boot target and reboot.
    async fn schedule_reboot(&self) -> Result<()>;

    /// Confirm the current boot is good (called post-reboot).
    async fn confirm_boot(&self) -> Result<()>;

    /// Roll back to the previous slot.
    async fn rollback(&self) -> Result<()>;

    /// Return the current engine phase.
    fn phase(&self) -> Phase;
}
