//! Klik Studio, from Klik — the Mac's AddOnKit bridge on Windows. Klik asks Studio to
//! record by writing a `RecordingRequest` (the Mac's JSON) to a file and opening
//! `klik-studio://record?request=<path>`; Studio shows its bar ready for it.

use crate::state::AppState;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::{AppHandle, Manager};
use tauri_plugin_opener::OpenerExt;

/// Settings › Studio.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct StudioSettings {
    /// Seconds before the first frame: 0, 3, 5 or 10.
    pub countdown_seconds: u32,
    pub system_audio: bool,
    pub microphone: bool,
    pub opens_editor_after_recording: bool,
}

impl Default for StudioSettings {
    fn default() -> Self {
        Self { countdown_seconds: 3, system_audio: true, microphone: false, opens_editor_after_recording: true }
    }
}

/// Where Klik Studio's installer puts it, for this user or for everyone.
fn installed_at() -> Option<PathBuf> {
    let roots = [std::env::var_os("LOCALAPPDATA").map(|p| PathBuf::from(p).join("Klik Studio")), std::env::var_os("ProgramFiles").map(|p| PathBuf::from(p).join("Klik Studio"))];
    roots.into_iter().flatten().flat_map(|root| [root.join("Klik Studio.exe"), root.join("klik-studio.exe")]).find(|exe| exe.is_file())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StudioState {
    installed: bool,
    path: Option<String>,
}

#[tauri::command]
pub fn studio_state() -> StudioState {
    let path = installed_at();
    StudioState { installed: path.is_some(), path: path.map(|p| p.to_string_lossy().into_owned()) }
}

/// Starts a recording in Studio (it shows its bar, ready to choose what to record), or
/// opens Settings › Studio when Studio isn't installed.
pub fn record(app: &AppHandle) -> Result<()> {
    if installed_at().is_none() {
        return crate::windows::open_settings(app, Some("studio"));
    }
    let settings = app.state::<AppState>().settings().studio;
    let request = serde_json::json!({
        "target": { "ask": {} },
        "microphone": settings.microphone,
        "systemAudio": settings.system_audio,
        "webcam": false,
        "countdownSeconds": settings.countdown_seconds,
        "opensEditorWhenFinished": settings.opens_editor_after_recording,
        "correlationID": uuid::Uuid::new_v4().to_string().to_uppercase(),
    });
    let path = std::env::temp_dir().join(format!("klik-studio-request-{}.json", uuid::Uuid::new_v4()));
    std::fs::write(&path, serde_json::to_vec_pretty(&request)?).context("Couldn't write the request for Klik Studio")?;
    let encoded: String = path.to_string_lossy().bytes().map(|b| if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect();
    app.opener().open_url(format!("klik-studio://record?request={encoded}"), None::<&str>).context("Couldn't open Klik Studio")?;
    Ok(())
}

/// Opens Studio's recordings.
pub fn open_library(app: &AppHandle) -> Result<()> {
    if installed_at().is_none() {
        return crate::windows::open_settings(app, Some("studio"));
    }
    app.opener().open_url("klik-studio://library", None::<&str>).context("Couldn't open Klik Studio")?;
    Ok(())
}

#[tauri::command]
pub fn studio_record(app: AppHandle) -> std::result::Result<(), String> {
    record(&app).map_err(|e| format!("{e:#}"))
}

#[tauri::command]
pub fn studio_library(app: AppHandle) -> std::result::Result<(), String> {
    open_library(&app).map_err(|e| format!("{e:#}"))
}
