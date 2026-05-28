//! engine.rs — concrete UpdateEngine implementation

use anyhow::Result;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use crate::{Phase, PayloadType, UpdateEngine, UpdateInfo};
use crate::config::EngineConfig;
use crate::hooks::{HookContext, HookRunner};
use crate::verify;
use crate::payload as payload_dl;

use delta_apply as delta;
use omaha_client::{OmahaClient, OmahaRequest, ServerBackend};
use slot_manager::{Slot, SlotManager};
use fwupd_client::{FirmwarePolicy, FwupdClient};

/// The main lota update engine.
pub struct LotaEngine {
    config: EngineConfig,
    phase: Arc<Mutex<Phase>>,
    slot_manager: Arc<dyn SlotManager>,
    omaha: OmahaClient,
    fwupd: Arc<dyn FwupdClient>,
    hooks: HookRunner,
    runtime_dir: PathBuf,
}

impl LotaEngine {
    pub fn new(
        config: EngineConfig,
        slot_manager: Arc<dyn SlotManager>,
        fwupd: Arc<dyn FwupdClient>,
        runtime_dir: PathBuf,
    ) -> Self {
        let backend = if config.channels.server_url.contains("hawkbit") {
            ServerBackend::HawkBit {
                url: config.channels.server_url.clone(),
                tenant: "default".into(),
                controller_id: config.system.name.clone(),
            }
        } else {
            ServerBackend::Omaha { url: config.channels.server_url.clone() }
        };

        let hook_script = runtime_dir.join("client/hooks/hook-runner.sh");
        let hooks = HookRunner::new(
            hook_script,
            config.hooks.hook_dir.clone(),
            config.hooks.timeout_secs,
        );

        Self {
            omaha: OmahaClient::new(backend),
            phase: Arc::new(Mutex::new(Phase::Idle)),
            config,
            slot_manager,
            fwupd,
            hooks,
            runtime_dir,
        }
    }

    fn set_phase(&self, p: Phase) {
        *self.phase.lock().unwrap() = p.clone();
        tracing::info!("Phase: {:?}", p);
    }

    fn hook_ctx(&self, version: &str, payload: &str) -> HookContext {
        HookContext {
            slot: "b".into(),
            payload: payload.to_string(),
            version: version.to_string(),
            channel: self.config.channels.active.clone(),
            filesystem: self.config.system.filesystem.clone(),
            distro: self.config.system.distro.clone(),
            arch: self.config.system.arch.clone(),
        }
    }

    fn machine_id() -> String {
        std::fs::read_to_string("/etc/machine-id")
            .unwrap_or_default()
            .trim()
            .to_string()
    }
}

#[async_trait::async_trait]
impl UpdateEngine for LotaEngine {
    async fn check_for_update(&self) -> Result<Option<UpdateInfo>> {
        self.set_phase(Phase::CheckingForUpdate);

        let req = OmahaRequest {
            app_id: self.config.system.distro.clone(),
            version: "0.0.0".into(), // real impl reads from /etc/lota/version
            arch: self.config.system.arch.clone(),
            channel: self.config.channels.active.clone(),
            machine_id: Self::machine_id(),
        };

        let resp = self.omaha.check(&req).await?;

        if !resp.update_available {
            self.set_phase(Phase::Idle);
            return Ok(None);
        }

        self.set_phase(Phase::UpdateAvailable);

        Ok(Some(UpdateInfo {
            version: resp.version.unwrap_or_default(),
            channel: self.config.channels.active.clone(),
            arch: self.config.system.arch.clone(),
            payload_url: resp.payload_url.unwrap_or_default(),
            payload_sha256: resp.payload_sha256.unwrap_or_default(),
            payload_size: resp.payload_size.unwrap_or(0),
            payload_type: if resp.is_delta { PayloadType::Delta } else { PayloadType::Full },
            is_delta: resp.is_delta,
        }))
    }

    async fn download(&self, info: &UpdateInfo, dest: &Path) -> Result<()> {
        self.set_phase(Phase::Downloading);

        let ctx = self.hook_ctx(&info.version, &dest.to_string_lossy());
        self.hooks.run("pre-download", &ctx).await?;

        payload_dl::download(&info.payload_url, dest, Some(info.payload_size)).await?;

        self.hooks.run("post-download", &ctx).await?;
        Ok(())
    }

    async fn verify(&self, info: &UpdateInfo, payload: &Path) -> Result<()> {
        self.set_phase(Phase::Verifying);

        let ctx = self.hook_ctx(&info.version, &payload.to_string_lossy());
        self.hooks.run("pre-verify", &ctx).await?;

        verify::verify_sha256(payload, &info.payload_sha256).await?;

        // Check for signature file alongside payload
        let sig_path = payload.with_extension("sig");
        let pubkey_path = PathBuf::from("/etc/lota/update-pubkey.pem");
        if sig_path.exists() && pubkey_path.exists() {
            verify::verify_signature(payload, &sig_path, &pubkey_path).await?;
        }

        self.hooks.run("post-verify", &ctx).await?;
        Ok(())
    }

    async fn install(&self, info: &UpdateInfo, payload: &Path) -> Result<()> {
        self.set_phase(Phase::Installing);

        let state = self.slot_manager.state().await?;
        let target_slot = state.inactive;
        let source_device = self.slot_manager.slot_device(state.active).await?;
        let target_device = self.slot_manager.slot_device(target_slot).await?;

        let ctx = self.hook_ctx(&info.version, &payload.to_string_lossy());
        self.hooks.run("pre-install", &ctx).await?;

        // Mark target slot unbootable before writing
        self.slot_manager.set_next_boot(target_slot).await
            .unwrap_or_else(|e| tracing::warn!("set_next_boot pre-install: {}", e));

        delta::apply(payload, Path::new(&source_device), Path::new(&target_device)).await?;

        self.hooks.run("post-install", &ctx).await?;
        Ok(())
    }

    async fn schedule_reboot(&self) -> Result<()> {
        let state = self.slot_manager.state().await?;
        self.slot_manager.set_next_boot(state.inactive).await?;

        self.set_phase(Phase::BootConfirmPending);

        let ctx = self.hook_ctx("", "");
        self.hooks.run("pre-reboot", &ctx).await?;

        tracing::info!("Scheduling reboot into slot {}", state.inactive.as_str());
        // Actual reboot deferred to caller / systemd
        Ok(())
    }

    async fn confirm_boot(&self) -> Result<()> {
        // Check for pending EFI firmware capsules before confirming
        if self.fwupd.has_pending_capsules().await.unwrap_or(false) {
            tracing::info!("Pending EFI capsules — deferring boot confirmation");
            return Ok(());
        }

        self.slot_manager.confirm_boot().await?;
        self.set_phase(Phase::Updated);

        let ctx = self.hook_ctx("", "");
        self.hooks.run("post-reboot", &ctx).await?;

        // Apply post-OS firmware updates if policy requires
        let policy = match self.config.firmware.policy.as_str() {
            "after_os" => FirmwarePolicy::AfterOs,
            _ => FirmwarePolicy::Independent,
        };
        if policy == FirmwarePolicy::AfterOs {
            self.set_phase(Phase::FirmwarePostOs);
            self.fwupd.apply_updates().await?;
        }

        self.set_phase(Phase::Updated);
        Ok(())
    }

    async fn rollback(&self) -> Result<()> {
        self.set_phase(Phase::RolledBack);
        self.slot_manager.rollback().await?;

        let ctx = self.hook_ctx("", "");
        self.hooks.run("rollback", &ctx).await?;
        Ok(())
    }

    fn phase(&self) -> Phase {
        self.phase.lock().unwrap().clone()
    }
}
