//! payload-bin — Android payload.bin (CrAU format) reader and writer
//!
//! Implements the binary format used by Android's update_engine:
//!
//!   Offset  Size  Field
//!   0       4     Magic "CrAU"
//!   4       8     file_format_version (u64 big-endian) — currently 2
//!   12      8     manifest_size (u64 big-endian)
//!   20      4     metadata_signature_size (u32 big-endian) — major v2 only
//!   24      N     DeltaArchiveManifest (protobuf)
//!   24+N    S     metadata_signatures (Signatures protobuf)
//!   24+N+S  ...   blobs (raw operation data)
//!   end-8   8     payload_signatures_size (u64 big-endian)
//!   end     P     payload_signatures (Signatures protobuf)
//!
//! The metadata signature covers bytes [0, 24+N).
//! The payload signature covers everything except the metadata sig block.

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
use std::io::{Read, Seek, SeekFrom, Write};

pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/chromeos_update_engine.rs"));
}

pub use proto::{DeltaArchiveManifest, InstallOperation, PartitionUpdate};

/// Magic bytes at the start of every payload.bin.
pub const PAYLOAD_MAGIC: &[u8; 4] = b"CrAU";
/// Current major format version.
pub const PAYLOAD_FORMAT_VERSION: u64 = 2;

/// Parsed payload.bin header + manifest.
#[derive(Debug)]
pub struct PayloadHeader {
    pub format_version: u64,
    pub manifest: DeltaArchiveManifest,
    pub manifest_size: u64,
    pub metadata_signature_size: u32,
    /// Byte offset where the blobs section begins.
    pub blobs_offset: u64,
}

impl PayloadHeader {
    /// Read and parse the header + manifest from a payload.bin file.
    pub fn read<R: Read + Seek>(reader: &mut R) -> Result<Self> {
        // Magic
        let mut magic = [0u8; 4];
        reader.read_exact(&mut magic).context("Reading magic")?;
        anyhow::ensure!(&magic == PAYLOAD_MAGIC, "Not a payload.bin (bad magic)");

        // file_format_version (8 bytes, big-endian)
        let format_version = read_u64_be(reader).context("Reading format version")?;
        anyhow::ensure!(
            format_version == PAYLOAD_FORMAT_VERSION,
            "Unsupported payload format version: {}",
            format_version
        );

        // manifest_size (8 bytes, big-endian)
        let manifest_size = read_u64_be(reader).context("Reading manifest size")?;

        // metadata_signature_size (4 bytes, big-endian) — v2 only
        let metadata_signature_size = read_u32_be(reader).context("Reading metadata sig size")?;

        // DeltaArchiveManifest protobuf
        let mut manifest_bytes = vec![0u8; manifest_size as usize];
        reader.read_exact(&mut manifest_bytes).context("Reading manifest")?;

        use prost::Message;
        let manifest = DeltaArchiveManifest::decode(manifest_bytes.as_slice())
            .context("Decoding DeltaArchiveManifest")?;

        // blobs start after: magic(4) + version(8) + manifest_size(8) + meta_sig_size(4) + manifest(N) + meta_sig(S)
        let blobs_offset = 4 + 8 + 8 + 4 + manifest_size + metadata_signature_size as u64;

        Ok(Self {
            format_version,
            manifest,
            manifest_size,
            metadata_signature_size,
            blobs_offset,
        })
    }

    /// Return the byte offset of the metadata (for signature coverage).
    pub fn metadata_size(&self) -> u64 {
        4 + 8 + 8 + 4 + self.manifest_size
    }
}

/// Compute SHA-256 of the metadata section (bytes [0, metadata_size)).
pub fn metadata_sha256<R: Read + Seek>(reader: &mut R, header: &PayloadHeader) -> Result<Vec<u8>> {
    reader.seek(SeekFrom::Start(0))?;
    let mut buf = vec![0u8; header.metadata_size() as usize];
    reader.read_exact(&mut buf)?;
    Ok(Sha256::digest(&buf).to_vec())
}

/// Compute SHA-256 of the entire payload (for payload_properties.txt FILE_HASH).
pub fn payload_sha256(path: &std::path::Path) -> Result<Vec<u8>> {
    let mut f = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 65536];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 { break; }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().to_vec())
}

/// Write payload_properties.txt content for a given payload.bin.
///
/// update_engine_client reads this file to know the payload hash and size
/// before downloading/applying.
pub fn write_payload_properties(
    payload_path: &std::path::Path,
    header: &PayloadHeader,
    out: &mut impl Write,
) -> Result<()> {
    let file_size = std::fs::metadata(payload_path)?.len();
    let file_hash = payload_sha256(payload_path)?;
    let file_hash_b64 = base64_encode(&file_hash);

    // Metadata hash (covers bytes [0, metadata_size))
    let mut f = std::fs::File::open(payload_path)?;
    let meta_hash = metadata_sha256(&mut f, header)?;
    let meta_hash_b64 = base64_encode(&meta_hash);

    writeln!(out, "FILE_HASH={}", file_hash_b64)?;
    writeln!(out, "FILE_SIZE={}", file_size)?;
    writeln!(out, "METADATA_HASH={}", meta_hash_b64)?;
    writeln!(out, "METADATA_SIZE={}", header.metadata_size())?;
    Ok(())
}

/// Minimal payload.bin writer for full (non-delta) payloads.
///
/// Produces a valid CrAU v2 file with REPLACE_XZ operations for each
/// partition image provided. Signing is done externally via delta_generator
/// or avbtool — this writer produces an unsigned payload.
pub struct PayloadWriter {
    partitions: Vec<PartitionEntry>,
}

pub struct PartitionEntry {
    pub name: String,
    pub image_path: std::path::PathBuf,
    pub filesystem_type: String,
}

impl PayloadWriter {
    pub fn new() -> Self {
        Self { partitions: Vec::new() }
    }

    pub fn add_partition(mut self, entry: PartitionEntry) -> Self {
        self.partitions.push(entry);
        self
    }

    /// Write the payload to `out`. Returns the PayloadHeader for further processing.
    pub fn write<W: Write + Seek>(&self, out: &mut W) -> Result<PayloadHeader> {
        use prost::Message;

        // Build manifest
        let mut manifest = DeltaArchiveManifest::default();
        manifest.block_size = Some(4096);
        manifest.minor_version = Some(0); // full payload

        let mut blobs: Vec<u8> = Vec::new();
        let mut blob_offset: u64 = 0;

        for entry in &self.partitions {
            let image_data = std::fs::read(&entry.image_path)
                .with_context(|| format!("Reading partition image: {:?}", entry.image_path))?;

            let image_size = image_data.len() as u64;
            let block_size: u64 = 4096;
            let num_blocks = (image_size + block_size - 1) / block_size;

            // Compress with xz for REPLACE_XZ
            let compressed = compress_xz(&image_data)?;
            let data_len = compressed.len() as u32;

            let op = proto::InstallOperation {
                r#type: proto::install_operation::Type::ReplaceXz as i32,
                data_offset: Some(blob_offset as u32),
                data_length: Some(data_len),
                dst_extents: vec![proto::Extent {
                    start_block: Some(0),
                    num_blocks: Some(num_blocks),
                }],
                ..Default::default()
            };

            let new_hash = Sha256::digest(&image_data).to_vec();
            let part = proto::PartitionUpdate {
                partition_name: entry.name.clone(),
                filesystem_type: Some(entry.filesystem_type.clone()),
                new_partition_info: Some(proto::PartitionInfo {
                    size: Some(image_size),
                    hash: Some(new_hash),
                }),
                operations: vec![op],
                ..Default::default()
            };

            manifest.partitions.push(part);
            blobs.extend_from_slice(&compressed);
            blob_offset += data_len as u64;
        }

        // Encode manifest
        let mut manifest_bytes = Vec::new();
        manifest.encode(&mut manifest_bytes)?;
        let manifest_size = manifest_bytes.len() as u64;

        // Write header
        out.write_all(PAYLOAD_MAGIC)?;
        write_u64_be(out, PAYLOAD_FORMAT_VERSION)?;
        write_u64_be(out, manifest_size)?;
        write_u32_be(out, 0u32)?; // metadata_signature_size = 0 (unsigned)
        out.write_all(&manifest_bytes)?;
        // No metadata signatures (unsigned)
        out.write_all(&blobs)?;
        // No payload signatures (unsigned)
        write_u64_be(out, 0u64)?;

        let blobs_offset = 4 + 8 + 8 + 4 + manifest_size;
        Ok(PayloadHeader {
            format_version: PAYLOAD_FORMAT_VERSION,
            manifest,
            manifest_size,
            metadata_signature_size: 0,
            blobs_offset,
        })
    }
}

impl Default for PayloadWriter {
    fn default() -> Self { Self::new() }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn read_u64_be<R: Read>(r: &mut R) -> Result<u64> {
    let mut buf = [0u8; 8];
    r.read_exact(&mut buf)?;
    Ok(u64::from_be_bytes(buf))
}

fn read_u32_be<R: Read>(r: &mut R) -> Result<u32> {
    let mut buf = [0u8; 4];
    r.read_exact(&mut buf)?;
    Ok(u32::from_be_bytes(buf))
}

fn write_u64_be<W: Write>(w: &mut W, v: u64) -> Result<()> {
    Ok(w.write_all(&v.to_be_bytes())?)
}

fn write_u32_be<W: Write>(w: &mut W, v: u32) -> Result<()> {
    Ok(w.write_all(&v.to_be_bytes())?)
}

fn base64_encode(data: &[u8]) -> String {
    // Minimal base64 without external dep — use standard alphabet
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = if chunk.len() > 1 { chunk[1] as usize } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as usize } else { 0 };
        out.push(ALPHABET[(b0 >> 2)] as char);
        out.push(ALPHABET[((b0 & 3) << 4) | (b1 >> 4)] as char);
        out.push(if chunk.len() > 1 { ALPHABET[((b1 & 0xf) << 2) | (b2 >> 6)] as char } else { '=' });
        out.push(if chunk.len() > 2 { ALPHABET[b2 & 0x3f] as char } else { '=' });
    }
    out
}

fn compress_xz(data: &[u8]) -> Result<Vec<u8>> {
    // Shell out to xz for compression — avoids a heavy native dep
    use std::io::Write as _;
    let mut child = std::process::Command::new("xz")
        .args(["-c", "-9", "--check=crc32"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .context("xz not found")?;
    child.stdin.as_mut().unwrap().write_all(data)?;
    let out = child.wait_with_output()?;
    anyhow::ensure!(out.status.success(), "xz compression failed");
    Ok(out.stdout)
}
