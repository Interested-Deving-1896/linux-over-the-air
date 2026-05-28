//! omaha-client — Omaha v3 protocol client
//!
//! Implements the Omaha v3 XML protocol for communicating with update servers:
//!   - Nebraska (local mock, for testing)
//!   - ChromeOS update server (production Omaha)
//!   - Custom Omaha-compatible endpoints
//!
//! Also supports hawkBit DDI API as an alternative backend.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Update server backend selection.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "type")]
pub enum ServerBackend {
    Omaha { url: String },
    HawkBit { url: String, tenant: String, controller_id: String },
    Nebraska { url: String },
}

/// Request sent to the Omaha server.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OmahaRequest {
    pub app_id: String,
    pub version: String,
    pub arch: String,
    pub channel: String,
    pub machine_id: String,
}

/// Parsed update response from the server.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OmahaResponse {
    pub update_available: bool,
    pub version: Option<String>,
    pub payload_url: Option<String>,
    pub payload_sha256: Option<String>,
    pub payload_size: Option<u64>,
    pub is_delta: bool,
}

/// Build an Omaha v3 XML request body.
pub fn build_request_xml(req: &OmahaRequest) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<request protocol="3.0" version="lota-0.1.0">
  <os version="linux" arch="{arch}" />
  <app id="{appid}" version="{version}" track="{channel}" arch="{arch}" machine_id="{machine_id}">
    <updatecheck />
  </app>
</request>"#,
        arch = req.arch,
        appid = req.app_id,
        version = req.version,
        channel = req.channel,
        machine_id = req.machine_id,
    )
}

/// Parse an Omaha v3 XML response.
pub fn parse_response_xml(xml: &str) -> Result<OmahaResponse> {
    // Minimal parser — extracts updatecheck status and package metadata.
    // A full implementation would use quick-xml's event reader.
    if xml.contains(r#"status="noupdate""#) {
        return Ok(OmahaResponse {
            update_available: false,
            version: None,
            payload_url: None,
            payload_sha256: None,
            payload_size: None,
            is_delta: false,
        });
    }

    // Extract codebase URL
    let payload_url = extract_attr(xml, "codebase").map(|base| format!("{}payload", base));
    let version = extract_attr(xml, "version");
    let sha256 = extract_attr(xml, "hash_sha256");
    let size = extract_attr(xml, "size").and_then(|s| s.parse().ok());
    let is_delta = xml.contains(r#"IsDeltaPayload="true""#);

    Ok(OmahaResponse {
        update_available: payload_url.is_some(),
        version,
        payload_url,
        payload_sha256: sha256,
        payload_size: size,
        is_delta,
    })
}

fn extract_attr(xml: &str, attr: &str) -> Option<String> {
    let needle = format!(r#"{}=""#, attr);
    let start = xml.find(&needle)? + needle.len();
    let end = xml[start..].find('"')? + start;
    Some(xml[start..end].to_string())
}

/// HTTP client for Omaha update checks.
pub struct OmahaClient {
    backend: ServerBackend,
    http: reqwest::Client,
}

impl OmahaClient {
    pub fn new(backend: ServerBackend) -> Self {
        Self {
            backend,
            http: reqwest::Client::new(),
        }
    }

    /// Perform an update check. Returns None if no update is available.
    pub async fn check(&self, req: &OmahaRequest) -> Result<OmahaResponse> {
        match &self.backend {
            ServerBackend::Omaha { url } | ServerBackend::Nebraska { url } => {
                let xml = build_request_xml(req);
                let resp = self.http
                    .post(format!("{}/update", url))
                    .header("Content-Type", "text/xml")
                    .body(xml)
                    .send()
                    .await
                    .context("Omaha request failed")?;
                let body = resp.text().await.context("Reading Omaha response")?;
                parse_response_xml(&body)
            }
            ServerBackend::HawkBit { url, tenant, controller_id } => {
                // hawkBit DDI: GET /{tenant}/controller/v1/{controllerId}
                let endpoint = format!("{}/{}/controller/v1/{}", url, tenant, controller_id);
                let resp = self.http.get(&endpoint).send().await
                    .context("hawkBit request failed")?;
                let body: serde_json::Value = resp.json().await
                    .context("Parsing hawkBit response")?;
                // Minimal hawkBit DDI parsing
                let has_update = body.pointer("/_links/deploymentBase").is_some();
                Ok(OmahaResponse {
                    update_available: has_update,
                    version: None,
                    payload_url: None,
                    payload_sha256: None,
                    payload_size: None,
                    is_delta: false,
                })
            }
        }
    }
}
