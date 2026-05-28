//! payload.rs — payload download and staging

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

/// Download a payload from a URL to a local staging path.
///
/// Streams the response body to disk, reporting progress via tracing.
/// Resumes partial downloads if the staging file already exists and the
/// server supports Range requests.
pub async fn download(url: &str, dest: &Path, expected_size: Option<u64>) -> Result<()> {
    tracing::info!("Downloading payload: {} → {}", url, dest.display());

    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }

    // Check for partial download
    let resume_from = if dest.exists() {
        tokio::fs::metadata(dest).await?.len()
    } else {
        0
    };

    let client = reqwest::Client::new();
    let mut req = client.get(url);

    if resume_from > 0 {
        tracing::info!("Resuming download from byte {}", resume_from);
        req = req.header("Range", format!("bytes={}-", resume_from));
    }

    let resp = req.send().await.context("HTTP request failed")?;

    let status = resp.status();
    anyhow::ensure!(
        status.is_success() || status.as_u16() == 206,
        "HTTP {} downloading payload",
        status
    );

    let total = resp.content_length()
        .or(expected_size)
        .unwrap_or(0);

    use tokio::io::AsyncWriteExt;
    let mut file = tokio::fs::OpenOptions::new()
        .create(true)
        .append(resume_from > 0)
        .write(true)
        .open(dest)
        .await
        .with_context(|| format!("Opening staging file: {}", dest.display()))?;

    let mut downloaded: u64 = resume_from;
    let mut stream = resp.bytes_stream();

    use futures_util::StreamExt;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.context("Reading response chunk")?;
        file.write_all(&chunk).await?;
        downloaded += chunk.len() as u64;

        if total > 0 {
            let pct = downloaded * 100 / total;
            tracing::debug!("Download progress: {}% ({}/{})", pct, downloaded, total);
        }
    }

    file.flush().await?;
    tracing::info!("Download complete: {} bytes → {}", downloaded, dest.display());
    Ok(())
}

/// Staging directory for in-progress downloads.
pub fn staging_dir() -> PathBuf {
    PathBuf::from("/var/lib/lota/staging")
}

/// Path for a staged payload given a version string.
pub fn staged_payload_path(version: &str) -> PathBuf {
    staging_dir().join(format!("payload-{}", version))
}
