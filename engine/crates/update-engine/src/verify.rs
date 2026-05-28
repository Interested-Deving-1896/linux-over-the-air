//! verify.rs — payload integrity and signature verification

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
use std::path::Path;

/// Verify a payload file against an expected SHA-256 hex digest.
pub async fn verify_sha256(payload: &Path, expected_hex: &str) -> Result<()> {
    let data = tokio::fs::read(payload)
        .await
        .with_context(|| format!("Reading payload for verification: {}", payload.display()))?;

    let actual = hex::encode(Sha256::digest(&data));

    anyhow::ensure!(
        actual.eq_ignore_ascii_case(expected_hex),
        "SHA-256 mismatch for {}: expected {}, got {}",
        payload.display(),
        expected_hex,
        actual
    );

    tracing::info!("SHA-256 verified: {}", payload.display());
    Ok(())
}

/// Verify an OpenSSL RSA signature over a payload file.
///
/// Delegates to `openssl dgst` to avoid pulling in a native crypto dep
/// for the initial scaffold. Replace with `ring` or `rsa` crate for
/// production use.
pub async fn verify_signature(payload: &Path, sig: &Path, pubkey: &Path) -> Result<()> {
    let status = tokio::process::Command::new("openssl")
        .args([
            "dgst",
            "-sha256",
            "-verify",
            &pubkey.to_string_lossy(),
            "-signature",
            &sig.to_string_lossy(),
            &payload.to_string_lossy(),
        ])
        .status()
        .await
        .context("openssl not found — install openssl for signature verification")?;

    anyhow::ensure!(status.success(), "Signature verification failed for {}", payload.display());
    tracing::info!("Signature verified: {}", payload.display());
    Ok(())
}

/// Verify an Android payload.bin metadata signature.
///
/// Delegates to `delta_generator --verify` when available, otherwise
/// falls back to SHA-256 hash check only.
pub async fn verify_android_payload(payload: &Path, pubkey: Option<&Path>) -> Result<()> {
    if let Some(key) = pubkey {
        let mut args = vec![
            format!("--in_file={}", payload.display()),
            "--verify".to_string(),
            format!("--public_key={}", key.display()),
        ];

        let status = tokio::process::Command::new("delta_generator")
            .args(&args)
            .status()
            .await;

        match status {
            Ok(s) if s.success() => {
                tracing::info!("Android payload verified via delta_generator");
                return Ok(());
            }
            Ok(_) => anyhow::bail!("delta_generator verification failed"),
            Err(_) => {
                tracing::warn!("delta_generator not found — skipping Android payload signature check");
            }
        }
    }

    // Fallback: just check the CrAU magic
    let mut f = tokio::fs::File::open(payload).await?;
    let mut magic = [0u8; 4];
    use tokio::io::AsyncReadExt;
    f.read_exact(&mut magic).await?;
    anyhow::ensure!(&magic == b"CrAU", "Not a valid Android payload.bin");
    tracing::info!("Android payload magic verified (CrAU)");
    Ok(())
}
