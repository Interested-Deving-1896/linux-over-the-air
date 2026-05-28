//! fwupd-client — D-Bus client for fwupd firmware update coordination
//!
//! Communicates with fwupd via its D-Bus interface (org.freedesktop.fwupd)
//! to check for firmware updates, apply them, and query device state.
//!
//! Mirrors the policy logic in runtime/firmware/fwupd-coordinator.sh but
//! as a native Rust D-Bus client for use within the engine process.
//!
//! Firmware policy (from config/system.toml [firmware].policy):
//!   before_os    — apply firmware before OS update
//!   after_os     — apply firmware after OS update
//!   independent  — fwupd manages its own schedule
//!   disabled     — skip all firmware updates

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Firmware update policy, mirrors system.toml [firmware].policy.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FirmwarePolicy {
    BeforeOs,
    AfterOs,
    Independent,
    Disabled,
}

impl Default for FirmwarePolicy {
    fn default() -> Self {
        FirmwarePolicy::Independent
    }
}

/// A firmware device with pending updates.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FirmwareDevice {
    pub device_id: String,
    pub name: String,
    pub version: String,
    pub update_version: Option<String>,
    pub has_pending: bool,
    pub requires_reboot: bool,
}

/// Result of a firmware update operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FirmwareUpdateResult {
    pub device_id: String,
    pub success: bool,
    pub error: Option<String>,
    pub requires_reboot: bool,
}

/// Core trait for fwupd interaction.
#[async_trait::async_trait]
pub trait FwupdClient: Send + Sync {
    /// List devices with available firmware updates.
    async fn list_updates(&self) -> Result<Vec<FirmwareDevice>>;

    /// Apply all pending firmware updates.
    async fn apply_updates(&self) -> Result<Vec<FirmwareUpdateResult>>;

    /// Check if any EFI capsule updates are pending (require reboot to apply).
    async fn has_pending_capsules(&self) -> Result<bool>;

    /// Return fwupd daemon version.
    async fn daemon_version(&self) -> Result<String>;
}

/// D-Bus implementation using zbus.
pub struct DBusFwupdClient {
    policy: FirmwarePolicy,
}

impl DBusFwupdClient {
    pub fn new(policy: FirmwarePolicy) -> Self {
        Self { policy }
    }

    pub fn policy(&self) -> &FirmwarePolicy {
        &self.policy
    }
}

#[async_trait::async_trait]
impl FwupdClient for DBusFwupdClient {
    async fn list_updates(&self) -> Result<Vec<FirmwareDevice>> {
        if self.policy == FirmwarePolicy::Disabled {
            tracing::info!("fwupd: policy=disabled, skipping update check");
            return Ok(vec![]);
        }

        // Connect to system D-Bus and call org.freedesktop.fwupd.GetUpdates
        let conn = zbus::Connection::system().await
            .context("Connecting to system D-Bus")?;

        // Call GetUpdates — returns array of device variant maps
        let reply = conn
            .call_method(
                Some("org.freedesktop.fwupd"),
                "/",
                Some("org.freedesktop.fwupd"),
                "GetUpdates",
                &(),
            )
            .await;

        match reply {
            Ok(msg) => {
                // Parse the variant array into FirmwareDevice structs.
                // Full implementation would deserialize the D-Bus variant map.
                // Stub returns empty — real impl uses zvariant deserialization.
                tracing::info!("fwupd: GetUpdates succeeded");
                let _ = msg;
                Ok(vec![])
            }
            Err(zbus::Error::MethodError(name, _, _))
                if name.as_str() == "org.freedesktop.fwupd.Error.NothingToDo" =>
            {
                tracing::info!("fwupd: no updates available");
                Ok(vec![])
            }
            Err(e) => Err(anyhow::anyhow!("fwupd GetUpdates failed: {}", e)),
        }
    }

    async fn apply_updates(&self) -> Result<Vec<FirmwareUpdateResult>> {
        if self.policy == FirmwarePolicy::Disabled {
            return Ok(vec![]);
        }

        let devices = self.list_updates().await?;
        if devices.is_empty() {
            tracing::info!("fwupd: no updates to apply");
            return Ok(vec![]);
        }

        let conn = zbus::Connection::system().await
            .context("Connecting to system D-Bus")?;

        let mut results = Vec::new();
        for device in &devices {
            tracing::info!("fwupd: updating device {} ({})", device.name, device.device_id);
            let reply = conn
                .call_method(
                    Some("org.freedesktop.fwupd"),
                    "/",
                    Some("org.freedesktop.fwupd"),
                    "Install",
                    &(&device.device_id, "", std::collections::HashMap::<String, zbus::zvariant::Value>::new()),
                )
                .await;

            results.push(FirmwareUpdateResult {
                device_id: device.device_id.clone(),
                success: reply.is_ok(),
                error: reply.err().map(|e| e.to_string()),
                requires_reboot: device.requires_reboot,
            });
        }

        Ok(results)
    }

    async fn has_pending_capsules(&self) -> Result<bool> {
        // Check /sys/firmware/efi/efivars for fwupd capsule update variables.
        // fwupd sets EFI variable "fwupd-EsrtEntry-*" when capsule is staged.
        let efi_vars = std::path::Path::new("/sys/firmware/efi/efivars");
        if !efi_vars.exists() {
            return Ok(false); // Non-EFI system
        }

        let mut rd = tokio::fs::read_dir(efi_vars).await
            .context("Reading EFI vars")?;
        while let Some(entry) = rd.next_entry().await? {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str.starts_with("fwupd-") || name_str.starts_with("fwupdate-") {
                tracing::info!("fwupd: pending EFI capsule: {}", name_str);
                return Ok(true);
            }
        }
        Ok(false)
    }

    async fn daemon_version(&self) -> Result<String> {
        let conn = zbus::Connection::system().await?;
        let reply = conn
            .call_method(
                Some("org.freedesktop.fwupd"),
                "/",
                Some("org.freedesktop.DBus.Properties"),
                "Get",
                &("org.freedesktop.fwupd", "DaemonVersion"),
            )
            .await
            .context("Getting fwupd DaemonVersion")?;
        let version: zbus::zvariant::OwnedValue = reply.body().deserialize()?;
        Ok(version.to_string())
    }
}

/// Shell-delegating client — calls fwupd-coordinator.sh for all operations.
/// Used when D-Bus is unavailable or for testing.
pub struct ShellFwupdClient {
    pub script_path: std::path::PathBuf,
    pub policy: FirmwarePolicy,
}

#[async_trait::async_trait]
impl FwupdClient for ShellFwupdClient {
    async fn list_updates(&self) -> Result<Vec<FirmwareDevice>> {
        let out = tokio::process::Command::new(&self.script_path)
            .arg("check")
            .output()
            .await?;
        // Stub: real impl parses JSON output from fwupd-coordinator.sh check --json
        let _ = out;
        Ok(vec![])
    }

    async fn apply_updates(&self) -> Result<Vec<FirmwareUpdateResult>> {
        let status = tokio::process::Command::new(&self.script_path)
            .arg("apply")
            .status()
            .await?;
        anyhow::ensure!(status.success(), "fwupd-coordinator.sh apply failed");
        Ok(vec![])
    }

    async fn has_pending_capsules(&self) -> Result<bool> {
        let status = tokio::process::Command::new(&self.script_path)
            .arg("boot-check")
            .status()
            .await?;
        // boot-check exits non-zero if capsules are pending
        Ok(!status.success())
    }

    async fn daemon_version(&self) -> Result<String> {
        let out = tokio::process::Command::new("fwupdmgr")
            .arg("--version")
            .output()
            .await?;
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    }
}
