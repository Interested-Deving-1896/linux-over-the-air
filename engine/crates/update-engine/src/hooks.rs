//! hooks.rs — lifecycle hook execution from within the engine

use anyhow::Result;
use std::path::{Path, PathBuf};

/// Run hooks for a given lifecycle phase via hook-runner.sh.
pub struct HookRunner {
    script: PathBuf,
    hook_dir: PathBuf,
    timeout_secs: u64,
}

impl HookRunner {
    pub fn new(script: PathBuf, hook_dir: PathBuf, timeout_secs: u64) -> Self {
        Self { script, hook_dir, timeout_secs }
    }

    /// Run all hooks for `phase`, injecting update context as env vars.
    pub async fn run(&self, phase: &str, ctx: &HookContext) -> Result<()> {
        if !self.hook_dir.exists() {
            tracing::debug!("No hook dir, skipping phase: {}", phase);
            return Ok(());
        }

        tracing::info!("Running hooks: phase={}", phase);

        let mut cmd = tokio::process::Command::new(&self.script);
        cmd.arg("--phase").arg(phase);

        if !ctx.slot.is_empty()    { cmd.arg("--slot").arg(&ctx.slot); }
        if !ctx.payload.is_empty() { cmd.arg("--payload").arg(&ctx.payload); }
        if !ctx.version.is_empty() { cmd.arg("--version").arg(&ctx.version); }
        if !ctx.channel.is_empty() { cmd.arg("--channel").arg(&ctx.channel); }
        if !ctx.filesystem.is_empty() { cmd.arg("--filesystem").arg(&ctx.filesystem); }
        if !ctx.distro.is_empty()  { cmd.arg("--distro").arg(&ctx.distro); }
        if !ctx.arch.is_empty()    { cmd.arg("--arch").arg(&ctx.arch); }

        cmd.env("LOTA_HOOK_DIR", &self.hook_dir)
           .env("LOTA_HOOK_TIMEOUT", self.timeout_secs.to_string());

        let status = cmd.status().await?;
        anyhow::ensure!(status.success(), "Hooks failed for phase: {}", phase);
        Ok(())
    }
}

/// Context passed to hooks as environment variables.
#[derive(Debug, Default, Clone)]
pub struct HookContext {
    pub slot: String,
    pub payload: String,
    pub version: String,
    pub channel: String,
    pub filesystem: String,
    pub distro: String,
    pub arch: String,
}
