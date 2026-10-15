//! The export's file work, for the editor's WebCodecs pipeline:
//!
//! - Reading: the recording's H.264 samples straight out of `screen.mp4`, a batch at a
//!   time, so the web side decodes exactly the frames it needs without loading the file.
//! - Writing: the muxer's bytes, at the positions it asks for, into the chosen file.

use crate::commands::Result;
use mp4::{Mp4Reader, TrackType};
use serde::Serialize;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, Seek, SeekFrom, Write};
use std::sync::Mutex;
use tauri::ipc::{InvokeBody, Request, Response};
use tauri::State;

#[derive(Default)]
pub struct Media {
    readers: Mutex<HashMap<String, (Mp4Reader<BufReader<File>>, u32)>>,
    writers: Mutex<HashMap<String, File>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoInfo {
    width: u16,
    height: u16,
    timescale: u32,
    /// `avc1.PPCCLL`, for `VideoDecoder.configure`.
    codec: String,
    /// The AVCDecoderConfigurationRecord.
    description: Vec<u8>,
    /// Presentation time of every sample, in `timescale` units, in decode order.
    times: Vec<i64>,
    /// 1-based numbers of the samples a decoder can start from.
    syncs: Vec<u32>,
}

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// Opens a recording's picture: its codec, and when every frame is shown.
#[tauri::command]
pub async fn video_open(media: State<'_, Media>, path: String) -> Result<VideoInfo> {
    let file = File::open(&path).map_err(err)?;
    let size = file.metadata().map_err(err)?.len();
    let reader = Mp4Reader::read_header(BufReader::new(file), size).map_err(err)?;
    let (id, track) = reader
        .tracks()
        .iter()
        .find(|(_, t)| matches!(t.track_type(), Ok(TrackType::Video)))
        .ok_or("This recording has no picture.")?;
    let stbl = &track.trak.mdia.minf.stbl;
    let avc1 = stbl.stsd.avc1.as_ref().ok_or("This recording's picture isn't H.264.")?;
    let c = &avc1.avcc;
    let mut description = vec![1, c.avc_profile_indication, c.profile_compatibility, c.avc_level_indication, 0xFC | (c.length_size_minus_one & 3)];
    description.push(0xE0 | c.sequence_parameter_sets.len() as u8);
    for sps in &c.sequence_parameter_sets {
        description.extend_from_slice(&(sps.bytes.len() as u16).to_be_bytes());
        description.extend_from_slice(&sps.bytes);
    }
    description.push(c.picture_parameter_sets.len() as u8);
    for pps in &c.picture_parameter_sets {
        description.extend_from_slice(&(pps.bytes.len() as u16).to_be_bytes());
        description.extend_from_slice(&pps.bytes);
    }
    let codec = format!("avc1.{:02x}{:02x}{:02x}", c.avc_profile_indication, c.profile_compatibility, c.avc_level_indication);

    // Decode times from stts, shifted by ctts into presentation times.
    let mut times = Vec::with_capacity(track.sample_count() as usize);
    let mut t: i64 = 0;
    for entry in &stbl.stts.entries {
        for _ in 0..entry.sample_count {
            times.push(t);
            t += entry.sample_delta as i64;
        }
    }
    if let Some(ctts) = &stbl.ctts {
        let mut i = 0usize;
        for entry in &ctts.entries {
            for _ in 0..entry.sample_count {
                if let Some(time) = times.get_mut(i) {
                    *time += entry.sample_offset as i64;
                }
                i += 1;
            }
        }
    }
    let syncs = stbl.stss.as_ref().map(|s| s.entries.clone()).unwrap_or_else(|| (1..=times.len() as u32).collect());
    let info = VideoInfo { width: track.width(), height: track.height(), timescale: track.timescale(), codec, description, times, syncs };
    let id = *id;
    media.readers.lock().unwrap().insert(path, (reader, id));
    Ok(info)
}

/// Samples `from`… (1-based), up to `count` of them, as one buffer: for each, a flag byte
/// (1 for a sync sample) and its length (u32, little-endian), then its bytes.
#[tauri::command]
pub async fn video_read(media: State<'_, Media>, path: String, from: u32, count: u32) -> Result<Response> {
    let mut readers = media.readers.lock().unwrap();
    let (reader, id) = readers.get_mut(&path).ok_or("The recording isn't open.")?;
    let mut out = Vec::new();
    for sample in from..from.saturating_add(count) {
        match reader.read_sample(*id, sample).map_err(err)? {
            Some(s) => {
                out.push(s.is_sync as u8);
                out.extend_from_slice(&(s.bytes.len() as u32).to_le_bytes());
                out.extend_from_slice(&s.bytes);
            }
            None => break,
        }
    }
    Ok(Response::new(out))
}

#[tauri::command]
pub fn video_close(media: State<'_, Media>, path: String) {
    media.readers.lock().unwrap().remove(&path);
}

/// Starts a file the export writes into.
#[tauri::command]
pub fn export_begin(media: State<'_, Media>, path: String) -> Result<()> {
    let file = File::create(&path).map_err(|e| format!("Klik Studio can't write there: {e}"))?;
    media.writers.lock().unwrap().insert(path, file);
    Ok(())
}

/// Bytes for the file named in the `x-path` header, at the `x-position` header's offset.
#[tauri::command]
pub fn export_write(media: State<'_, Media>, request: Request<'_>) -> Result<()> {
    let header = |name: &str| request.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned);
    let path = header("x-path").map(|p| percent_decode(&p)).ok_or("No file was named.")?;
    let position: u64 = header("x-position").and_then(|p| p.parse().ok()).ok_or("No position was given.")?;
    let InvokeBody::Raw(bytes) = request.body() else { return Err("Expected bytes.".into()) };
    let mut writers = media.writers.lock().unwrap();
    let file = writers.get_mut(&path).ok_or("The export isn't open.")?;
    file.seek(SeekFrom::Start(position)).map_err(err)?;
    file.write_all(bytes).map_err(err)?;
    Ok(())
}

/// Finishes the file; when `keep` is false (cancelled, failed) it is removed.
#[tauri::command]
pub fn export_end(media: State<'_, Media>, path: String, keep: bool) -> Result<()> {
    if let Some(file) = media.writers.lock().unwrap().remove(&path) {
        file.sync_all().ok();
    }
    if !keep {
        std::fs::remove_file(&path).ok();
    }
    Ok(())
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&text[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}
