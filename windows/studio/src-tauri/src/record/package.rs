//! The `.cuerec` package — a folder, laid out as the Mac's:
//!
//! ```text
//! Recording 2026-10-15 at 18.04.12.cuerec/
//!   manifest.json     what was recorded
//!   project.json      the edit, once there is one
//!   media/            screen.mp4, system-audio.wav, microphone-1.wav
//!   telemetry/        cursor.jsonl, input.jsonl, cursors.json, cursors/
//!   derived/          caches that can be made again
//! ```
//!
//! JSON is written pretty-printed with sorted keys (serde_json's maps are sorted), to a
//! temporary file that is then swapped in.

use anyhow::{Context, Result};
use chrono::{DateTime, Local, Utc};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const EXTENSION: &str = "cuerec";
pub const IN_PROGRESS: &str = "in-progress.json";

/// Where recordings go: `Videos\Cue Studio`.
pub fn library_folder() -> PathBuf {
    let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    home.join("Videos").join("Cue Studio")
}

/// "Recording 2026-10-15 at 18.04.12", the Mac's name for a take.
pub fn take_name(at: DateTime<Local>) -> String {
    format!("Recording {}", at.format("%Y-%m-%d at %H.%M.%S"))
}

/// A new, empty package for a take, numbered if the name is taken.
pub fn create(folder: &Path, name: &str) -> Result<PathBuf> {
    std::fs::create_dir_all(folder).context("Could not make the recordings folder")?;
    let mut path = folder.join(format!("{name}.{EXTENSION}"));
    let mut n = 2;
    while path.exists() {
        path = folder.join(format!("{name} {n}.{EXTENSION}"));
        n += 1;
    }
    for sub in ["media", "telemetry", "derived"] {
        std::fs::create_dir_all(path.join(sub))?;
    }
    Ok(path)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    /// `screen`, `webcam`, `microphone`, `systemAudio`.
    pub kind: String,
    /// Relative to the package, with forward slashes.
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pixel_size: Option<[f64; 2]>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frame_rate: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(rename = "deviceID", skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetryFiles {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor_artwork: Option<String>,
    /// Seconds, already added to every time in the files.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pointer_latency: Option<f64>,
    /// `recorded` or `notPermitted`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keys: Option<String>,
}

/// `manifest.json` — the Mac's `RecordingManifest`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub format_version: u32,
    pub name: String,
    pub created_at: DateTime<Utc>,
    /// Seconds.
    pub duration: f64,
    /// Pixels per point: Windows' display scale (1.5 at 150%).
    pub display_scale: f64,
    /// The area chosen, in points of the recorded display, for an area take.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_rect: Option<[[f64; 2]; 2]>,
    pub tracks: Vec<Track>,
    pub telemetry: TelemetryFiles,
    pub recorded_by: String,
}

pub fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    // Through a Value, so object keys come out sorted, as the Mac writes them.
    let value = serde_json::to_value(value)?;
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, serde_json::to_vec_pretty(&value)?)?;
    std::fs::rename(&temporary, path)?;
    Ok(())
}

pub fn read_manifest(package: &Path) -> Result<Manifest> {
    let data = std::fs::read(package.join("manifest.json")).context("This recording has no manifest")?;
    serde_json::from_slice(&data).context("This recording's manifest can't be read")
}

/// One recording in the library, for its list.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryItem {
    pub path: String,
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub duration: f64,
    pub width: f64,
    pub height: f64,
    pub edited: bool,
    /// A take that did not finish (Studio quit or crashed while recording).
    pub unfinished: bool,
}

pub fn library() -> Vec<LibraryItem> {
    let Ok(entries) = std::fs::read_dir(library_folder()) else { return Vec::new() };
    let mut items: Vec<LibraryItem> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == EXTENSION) && p.is_dir())
        .filter_map(|path| {
            let unfinished = path.join(IN_PROGRESS).exists();
            let manifest = read_manifest(&path).ok();
            let size = manifest.as_ref().and_then(|m| m.tracks.iter().find(|t| t.kind == "screen")).and_then(|t| t.pixel_size).unwrap_or([0.0, 0.0]);
            Some(LibraryItem {
                name: path.file_stem()?.to_string_lossy().into_owned(),
                created_at: manifest.as_ref().map(|m| m.created_at).unwrap_or_else(|| std::fs::metadata(&path).and_then(|m| m.created()).map(Into::into).unwrap_or_else(|_| Utc::now())),
                duration: manifest.as_ref().map(|m| m.duration).unwrap_or(0.0),
                width: size[0],
                height: size[1],
                edited: path.join("project.json").exists(),
                unfinished,
                path: path.to_string_lossy().into_owned(),
            })
        })
        .collect();
    items.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    items
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_numbers_takes() {
        let at = Local.with_ymd_and_hms(2026, 10, 15, 18, 4, 12).unwrap();
        assert_eq!(take_name(at), "Recording 2026-10-15 at 18.04.12");
        let dir = std::env::temp_dir().join(format!("cue-studio-{}", uuid::Uuid::new_v4()));
        let a = create(&dir, "Take").unwrap();
        let b = create(&dir, "Take").unwrap();
        assert!(a.ends_with("Take.cuerec") && b.ends_with("Take 2.cuerec"));
        assert!(b.join("telemetry").is_dir());
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn writes_the_macs_field_names() {
        let manifest = Manifest {
            format_version: 1,
            name: "Take".into(),
            created_at: Utc::now(),
            duration: 2.5,
            display_scale: 1.5,
            source_rect: None,
            tracks: vec![Track { kind: "screen".into(), path: "media/screen.mp4".into(), pixel_size: Some([1920.0, 1080.0]), frame_rate: Some(60), codec: Some("avc1".into()), name: None, device_id: None }],
            telemetry: TelemetryFiles { cursor: Some("telemetry/cursor.jsonl".into()), ..Default::default() },
            recorded_by: "Cue Studio".into(),
        };
        let text = serde_json::to_string(&manifest).unwrap();
        for key in ["formatVersion", "displayScale", "pixelSize", "frameRate", "recordedBy", "\"cursor\""] {
            assert!(text.contains(key), "{key} in {text}");
        }
        assert!(!text.contains("sourceRect"));
    }

    use chrono::TimeZone;
}
