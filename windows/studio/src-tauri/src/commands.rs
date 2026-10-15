//! What the web side asks for.

use crate::record::package::{self, LibraryItem};
use crate::record::screen::{self, DisplayInfo, WindowInfo};
use crate::record::session::{Session, SessionState, StartOptions};
use crate::{windows, AppState};
use serde::Serialize;
use std::path::PathBuf;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, State};

pub type Result<T> = std::result::Result<T, String>;

fn text(error: impl std::fmt::Display) -> String {
    error.to_string()
}

#[tauri::command]
pub fn displays() -> Vec<DisplayInfo> {
    crate::record::session::displays()
}

#[tauri::command]
pub fn windows_list() -> Vec<WindowInfo> {
    screen::windows_list()
}

#[derive(Serialize)]
pub struct Microphone {
    id: String,
    name: String,
}

#[tauri::command]
pub fn microphones() -> Vec<Microphone> {
    crate::record::audio::microphones().into_iter().map(|(id, name)| Microphone { id, name }).collect()
}

#[tauri::command]
pub async fn start_recording(app: AppHandle, options: StartOptions) -> Result<()> {
    let state = app.state::<AppState>();
    if state.session.lock().unwrap().is_some() {
        return Err("A recording is already running.".into());
    }
    windows::close_pickers(&app);
    let session = Session::start(options).map_err(|e| format!("{e:#}"))?;
    // The timer starts with the picture.
    let session = tauri::async_runtime::spawn_blocking(move || {
        session.wait_for_first_frame(Duration::from_secs(3));
        session
    })
    .await
    .map_err(text)?;
    *state.session.lock().unwrap() = Some(session);
    app.emit("recording-changed", recording_state(app.state::<AppState>())).ok();
    Ok(())
}

#[tauri::command]
pub fn pause_recording(app: AppHandle, state: State<AppState>) {
    if let Some(session) = state.session.lock().unwrap().as_ref() {
        session.pause();
    }
    app.emit("recording-changed", recording_state(state)).ok();
}

#[tauri::command]
pub fn resume_recording(app: AppHandle, state: State<AppState>) {
    if let Some(session) = state.session.lock().unwrap().as_ref() {
        session.resume();
    }
    app.emit("recording-changed", recording_state(state)).ok();
}

/// Finishes the take and opens it in the editor.
#[tauri::command]
pub async fn stop_recording(app: AppHandle) -> Result<String> {
    let session = app.state::<AppState>().session.lock().unwrap().take().ok_or("Nothing is being recorded.")?;
    let package = tauri::async_runtime::spawn_blocking(move || session.stop()).await.map_err(text)?.map_err(|e| format!("{e:#}"))?;
    app.emit("recording-changed", SessionState { recording: false, paused: false, seconds: 0.0 }).ok();
    app.emit("library-changed", ()).ok();
    let path = package.to_string_lossy().into_owned();
    windows::open_editor(&app, &path).map_err(text)?;
    Ok(path)
}

#[tauri::command]
pub async fn cancel_recording(app: AppHandle) {
    let session = app.state::<AppState>().session.lock().unwrap().take();
    if let Some(session) = session {
        tauri::async_runtime::spawn_blocking(move || session.cancel()).await.ok();
    }
    app.emit("recording-changed", SessionState { recording: false, paused: false, seconds: 0.0 }).ok();
}

#[tauri::command]
pub fn recording_state(state: State<AppState>) -> SessionState {
    state.session.lock().unwrap().as_ref().map(Session::state).unwrap_or(SessionState { recording: false, paused: false, seconds: 0.0 })
}

#[tauri::command]
pub fn library() -> Vec<LibraryItem> {
    package::library()
}

#[tauri::command]
pub async fn open_editor(app: AppHandle, path: String) -> Result<()> {
    windows::open_editor(&app, &path).map_err(text)
}

/// Everything the editor needs to open a take: its manifest, its edit (if any), the
/// telemetry, and where its files are.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectFiles {
    path: String,
    manifest: serde_json::Value,
    project: Option<serde_json::Value>,
    pending_crop: Option<serde_json::Value>,
    cursor: String,
    input: String,
    cursor_artwork: Option<serde_json::Value>,
}

#[tauri::command]
pub async fn read_project(path: String) -> Result<ProjectFiles> {
    let package = PathBuf::from(&path);
    let json = |name: &str| std::fs::read(package.join(name)).ok().and_then(|d| serde_json::from_slice::<serde_json::Value>(&d).ok());
    let manifest = json("manifest.json").ok_or("This recording can't be opened: its manifest is missing.")?;
    Ok(ProjectFiles {
        path,
        project: json("project.json"),
        pending_crop: json("pending-crop.json"),
        cursor: std::fs::read_to_string(package.join("telemetry/cursor.jsonl")).unwrap_or_default(),
        input: std::fs::read_to_string(package.join("telemetry/input.jsonl")).unwrap_or_default(),
        cursor_artwork: json("telemetry/cursors.json"),
        manifest,
    })
}

/// Saves the edit, atomically.
#[tauri::command]
pub async fn write_project(path: String, project: serde_json::Value) -> Result<()> {
    let package = PathBuf::from(&path);
    package::write_json(&package.join("project.json"), &project).map_err(text)?;
    std::fs::remove_file(package.join("pending-crop.json")).ok();
    Ok(())
}

/// Opens a finished export in the default player.
#[tauri::command]
pub fn open_file(path: String) -> Result<()> {
    tauri_plugin_opener::open_path(path, None::<&str>).map_err(text)
}

#[tauri::command]
pub fn reveal_recording(path: String) -> Result<()> {
    tauri_plugin_opener::reveal_item_in_dir(path).map_err(text)
}

#[tauri::command]
pub async fn delete_recording(app: AppHandle, path: String) -> Result<()> {
    let package = PathBuf::from(&path);
    if package.extension().is_none_or(|e| e != package::EXTENSION) {
        return Err("That is not a recording.".into());
    }
    trash::delete(&package).map_err(text)?;
    app.emit("library-changed", ()).ok();
    Ok(())
}

#[tauri::command]
pub async fn open_picker(app: AppHandle, mode: String) -> Result<()> {
    windows::open_pickers(&app, &mode).map_err(text)
}

#[tauri::command]
pub async fn close_picker(app: AppHandle) {
    windows::close_pickers(&app);
}

#[tauri::command]
pub async fn show_bar(app: AppHandle) -> Result<()> {
    windows::show_bar(&app).map_err(text)
}

#[tauri::command]
pub async fn open_library(app: AppHandle) -> Result<()> {
    windows::open_library(&app).map_err(text)
}

/// A line from the web side for the log (script failures, mostly).
#[tauri::command]
pub fn log_line(text: String) {
    log::warn!("web: {text}");
    eprintln!("web: {text}");
}
