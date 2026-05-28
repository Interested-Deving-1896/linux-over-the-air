//! delta-apply — bsdiff/bspatch delta payload application
//!
//! Applies binary delta patches produced by bsdiff to produce a new
//! filesystem image from the current slot's image. Supports zstd-compressed
//! delta payloads (detected by magic bytes).
//!
//! For full image payloads, delegates to direct block-level write.

use anyhow::{Context, Result};
use std::path::Path;

/// Payload format detected from file content.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PayloadFormat {
    /// Raw bsdiff patch
    BsDiff,
    /// zstd-compressed bsdiff patch
    BsDiffZstd,
    /// Full filesystem image (raw write)
    FullImage,
    /// Tar archive
    Tar,
}

impl PayloadFormat {
    /// Detect format from the first few bytes of the payload.
    pub fn detect(header: &[u8]) -> Self {
        // bsdiff magic: "BSDIFF40"
        if header.starts_with(b"BSDIFF40") {
            return PayloadFormat::BsDiff;
        }
        // zstd magic: 0xFD2FB528 (little-endian)
        if header.starts_with(&[0xFD, 0x2F, 0xB5, 0x28]) {
            return PayloadFormat::BsDiffZstd;
        }
        // tar magic at offset 257: "ustar"
        if header.len() > 262 && &header[257..262] == b"ustar" {
            return PayloadFormat::Tar;
        }
        PayloadFormat::FullImage
    }
}

/// Apply a delta or full payload to the target block device or file.
///
/// - `payload`: path to the downloaded payload
/// - `source`: current slot's block device or image (for delta)
/// - `target`: inactive slot's block device or image
pub async fn apply(payload: &Path, source: &Path, target: &Path) -> Result<()> {
    // Read header to detect format
    let mut f = tokio::fs::File::open(payload).await?;
    let mut header = vec![0u8; 512];
    use tokio::io::AsyncReadExt;
    let n = f.read(&mut header).await?;
    drop(f);
    let format = PayloadFormat::detect(&header[..n]);

    match format {
        PayloadFormat::BsDiff => {
            apply_bsdiff(payload, source, target).await
        }
        PayloadFormat::BsDiffZstd => {
            let decompressed = decompress_zstd(payload).await?;
            apply_bsdiff(&decompressed, source, target).await
        }
        PayloadFormat::FullImage => {
            write_full_image(payload, target).await
        }
        PayloadFormat::Tar => {
            extract_tar(payload, target).await
        }
    }
}

async fn apply_bsdiff(patch: &Path, source: &Path, target: &Path) -> Result<()> {
    tracing::info!("Applying bsdiff patch: {:?} → {:?}", source, target);
    let old = tokio::fs::read(source).await
        .with_context(|| format!("Reading source: {:?}", source))?;
    let patch_data = tokio::fs::read(patch).await
        .with_context(|| format!("Reading patch: {:?}", patch))?;
    let new = bsdiff::patch(&old, &mut std::io::Cursor::new(patch_data))
        .context("bspatch failed")?;
    tokio::fs::write(target, &new).await
        .with_context(|| format!("Writing target: {:?}", target))?;
    tracing::info!("bsdiff applied: {} bytes → {} bytes", old.len(), new.len());
    Ok(())
}

async fn decompress_zstd(src: &Path) -> Result<std::path::PathBuf> {
    let dest = src.with_extension("bsdiff");
    let status = tokio::process::Command::new("zstd")
        .arg("-d")
        .arg(src)
        .arg("-o")
        .arg(&dest)
        .arg("--force")
        .status()
        .await
        .context("zstd not found")?;
    anyhow::ensure!(status.success(), "zstd decompression failed");
    Ok(dest)
}

async fn write_full_image(payload: &Path, target: &Path) -> Result<()> {
    tracing::info!("Writing full image: {:?} → {:?}", payload, target);
    // Use dd for block device targets, tokio::fs::copy for file targets
    let status = tokio::process::Command::new("dd")
        .arg(format!("if={}", payload.display()))
        .arg(format!("of={}", target.display()))
        .arg("bs=4M")
        .arg("conv=fsync")
        .status()
        .await
        .context("dd not found")?;
    anyhow::ensure!(status.success(), "dd write failed");
    Ok(())
}

async fn extract_tar(payload: &Path, target: &Path) -> Result<()> {
    tracing::info!("Extracting tar: {:?} → {:?}", payload, target);
    tokio::fs::create_dir_all(target).await?;
    let status = tokio::process::Command::new("tar")
        .arg("-xf")
        .arg(payload)
        .arg("-C")
        .arg(target)
        .status()
        .await
        .context("tar not found")?;
    anyhow::ensure!(status.success(), "tar extraction failed");
    Ok(())
}
