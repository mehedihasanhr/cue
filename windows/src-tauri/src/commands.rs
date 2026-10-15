//! What the web side can call.

use crate::capture::{self, geometry::Rect, Mode, OverlayInfo};
use crate::hotkeys::{self, Conflict};
use crate::library::CaptureItem;
use crate::settings::Settings;
use crate::state::{default_captures_folder, AppState};
use crate::{actions, clipboard, protocol, tray, windows};
use serde::Serialize;
use tauri::ipc::{InvokeBody, Request};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_autostart::ManagerExt;
use uuid::Uuid;

type Result<T> = std::result::Result<T, String>;

fn text(error: impl std::fmt::Display) -> String {
    error.to_string()
}

// MARK: - Settings

#[tauri::command]
pub fn get_settings(state: State<AppState>) -> Settings {
    state.settings()
}

#[tauri::command]
pub fn set_settings(app: AppHandle, state: State<AppState>, settings: Settings) -> Result<Vec<Conflict>> {
    settings.save(&state.settings_path).map_err(text)?;
    let islands_changed = {
        let old = &state.settings.lock().unwrap().island;
        old.enabled != settings.island.enabled || old.display != settings.island.display
    };
    let folder = settings.save_folder.clone().unwrap_or_else(default_captures_folder);
    *state.settings.lock().unwrap() = settings;
    state.library.lock().unwrap().set_folder(folder);
    let conflicts = hotkeys::apply(&app);
    *state.conflicts.lock().unwrap() = conflicts.clone();
    tray::refresh(&app);
    if islands_changed {
        crate::island::rebuild(&app);
    }
    app.emit("settings-changed", ()).ok();
    app.emit("library-changed", ()).ok();
    Ok(conflicts)
}

#[tauri::command]
pub fn shortcut_conflicts(state: State<AppState>) -> Vec<Conflict> {
    state.conflicts.lock().unwrap().clone()
}

/// Turns every global shortcut off while one is being recorded in Settings, so pressing
/// the current combination records it instead of taking a capture.
#[tauri::command]
pub fn pause_shortcuts(app: AppHandle, paused: bool) {
    use tauri_plugin_global_shortcut::GlobalShortcutExt;
    if paused {
        app.global_shortcut().unregister_all().ok();
    } else {
        hotkeys::apply(&app);
    }
}

#[tauri::command]
pub fn default_folder() -> String {
    default_captures_folder().to_string_lossy().into_owned()
}

#[tauri::command]
pub fn get_autostart(app: AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
pub fn set_autostart(app: AppHandle, enabled: bool) -> Result<()> {
    let manager = app.autolaunch();
    if enabled { manager.enable() } else { manager.disable() }.map_err(text)
}

#[tauri::command]
pub fn run_action(app: AppHandle, action: String) {
    actions::run(&app, &action);
}

// MARK: - Capturing

#[tauri::command]
pub fn start_capture(app: AppHandle, mode: Mode) {
    let action = match mode {
        Mode::Area => "captureArea",
        Mode::Window => "captureWindow",
        Mode::FullScreen => "captureFullScreen",
        Mode::Text => "captureText",
    };
    actions::run(&app, action);
}

#[tauri::command]
pub fn overlay_info(app: AppHandle, index: usize) -> Result<OverlayInfo> {
    capture::overlay_info(&app, index).map_err(|e| format!("{e:#}"))
}

#[tauri::command]
pub fn overlay_ready(app: AppHandle, index: usize, focus: bool) -> Result<()> {
    capture::overlay_ready(&app, index, focus).map_err(|e| format!("{e:#}"))
}

// Async, like every command here that opens or closes a window: building a window inside a
// synchronous command deadlocks on Windows, whose main thread is the one running it.
#[tauri::command]
pub async fn finish_capture(app: AppHandle, index: usize, rect: Rect) -> Result<()> {
    capture::finish(&app, index, rect).map_err(|e| format!("{e:#}"))
}

#[tauri::command]
pub async fn cancel_capture(app: AppHandle) {
    capture::cancel(&app);
}

// MARK: - History

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryItem {
    #[serde(flatten)]
    pub item: CaptureItem,
    pub url: String,
    pub thumbnail_url: String,
    pub path: String,
}

fn history_item(state: &AppState, item: CaptureItem) -> HistoryItem {
    let path = state.library.lock().unwrap().path(item.id).unwrap_or_default();
    HistoryItem {
        url: protocol::url(&format!("capture/{}", item.id)),
        thumbnail_url: protocol::url(&format!("thumb/{}", item.id)),
        path: path.to_string_lossy().into_owned(),
        item,
    }
}

#[tauri::command]
pub fn history_items(state: State<AppState>) -> Vec<HistoryItem> {
    let items = state.library.lock().unwrap().items().to_vec();
    items.into_iter().map(|item| history_item(&state, item)).collect()
}

#[tauri::command]
pub fn history_item_by_id(state: State<AppState>, id: Uuid) -> Result<HistoryItem> {
    let item = state.library.lock().unwrap().item(id).cloned().ok_or("That capture is gone.")?;
    Ok(history_item(&state, item))
}

#[tauri::command]
pub async fn history_delete(app: AppHandle, state: State<'_, AppState>, id: Uuid) -> Result<()> {
    state.library.lock().unwrap().delete(id).map_err(|e| format!("{e:#}"))?;
    if let Some(window) = app.get_webview_window(&format!("editor-{id}")) {
        window.destroy().ok();
    }
    app.emit("library-changed", ()).ok();
    Ok(())
}

#[tauri::command]
pub fn history_rename(app: AppHandle, state: State<AppState>, id: Uuid, title: String) -> Result<()> {
    state.library.lock().unwrap().rename(id, &title).map_err(|e| format!("{e:#}"))?;
    app.emit("library-changed", ()).ok();
    Ok(())
}

#[tauri::command]
pub fn history_set_pinned(app: AppHandle, state: State<AppState>, id: Uuid, pinned: bool) -> Result<()> {
    state.library.lock().unwrap().set_pinned(id, pinned).map_err(text)?;
    app.emit("library-changed", ()).ok();
    Ok(())
}

#[tauri::command]
pub async fn history_copy(state: State<'_, AppState>, id: Uuid) -> Result<()> {
    let path = state.library.lock().unwrap().path(id).ok_or("That capture is gone.")?;
    let image = image::open(path).map_err(text)?.to_rgba8();
    clipboard::copy_image(&image).map_err(|e| format!("{e:#}"))
}

#[tauri::command]
pub fn history_reveal(state: State<AppState>, id: Uuid) -> Result<()> {
    let path = state.library.lock().unwrap().path(id).ok_or("That capture is gone.")?;
    tauri_plugin_opener::reveal_item_in_dir(path).map_err(text)
}

#[tauri::command]
pub fn history_open_folder(app: AppHandle, state: State<AppState>) -> Result<()> {
    use tauri_plugin_opener::OpenerExt;
    let folder = state.library.lock().unwrap().folder().to_path_buf();
    std::fs::create_dir_all(&folder).ok();
    app.opener().open_path(folder.to_string_lossy(), None::<&str>).map_err(text)
}

#[tauri::command]
pub async fn history_float(app: AppHandle, id: Uuid) -> Result<()> {
    windows::open_pin(&app, id).map_err(|e| format!("{e:#}"))
}

#[tauri::command]
pub async fn history_edit(app: AppHandle, id: Uuid) -> Result<()> {
    windows::open_editor(&app, id).map_err(text)
}

// MARK: - Editor

fn raw_body<'a>(request: &'a Request<'_>) -> Result<&'a [u8]> {
    match request.body() {
        InvokeBody::Raw(data) => Ok(data),
        _ => Err("Expected image data.".into()),
    }
}

fn header_id(request: &Request<'_>) -> Result<Uuid> {
    request
        .headers()
        .get("x-capture-id")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| "Missing capture id.".into())
}

/// Saves the edited picture over the capture. Body: PNG bytes; header `x-capture-id`.
#[tauri::command]
pub async fn editor_save(app: AppHandle, state: State<'_, AppState>, request: Request<'_>) -> Result<()> {
    let id = header_id(&request)?;
    let image = image::load_from_memory(raw_body(&request)?).map_err(text)?.to_rgba8();
    state.library.lock().unwrap().replace(id, &image).map_err(|e| format!("{e:#}"))?;
    app.emit("library-changed", ()).ok();
    Ok(())
}

/// Copies a picture the editor rendered. Body: PNG bytes.
#[tauri::command]
pub async fn editor_copy(request: Request<'_>) -> Result<()> {
    let image = image::load_from_memory(raw_body(&request)?).map_err(text)?.to_rgba8();
    clipboard::copy_image(&image).map_err(|e| format!("{e:#}"))
}

/// Writes bytes the editor rendered to a path the user chose. Header `x-path`.
#[tauri::command]
pub async fn editor_write_file(request: Request<'_>) -> Result<()> {
    let path = request
        .headers()
        .get("x-path")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| urlencoding::decode(value).ok())
        .map(|value| value.into_owned())
        .ok_or("Missing path.")?;
    std::fs::write(path, raw_body(&request)?).map_err(text)
}

#[tauri::command]
pub fn copy_text(text_value: String) -> Result<()> {
    clipboard::copy_text(&text_value).map_err(|e| format!("{e:#}"))
}

/// A script error in a window, written to the log so it can be found after the fact.
#[tauri::command]
pub fn log_error(window: tauri::WebviewWindow, text_value: String) {
    log::error!("[{}] {}", window.label(), text_value);
    eprintln!("[{}] {}", window.label(), text_value);
}

// MARK: - Sharing

/// Uploads a capture where Settings › Sharing says, and copies the link.
#[tauri::command]
pub async fn history_share(state: State<'_, AppState>, id: Uuid) -> Result<String> {
    let (path, created_at) = {
        let library = state.library.lock().unwrap();
        let item = library.item(id).cloned().ok_or("That capture is gone.")?;
        (library.path(id).unwrap_or_default(), item.created_at)
    };
    let settings = state.settings().share;
    let png = std::fs::read(path).map_err(text)?;
    let name = crate::share::object_name(&settings, created_at);
    let link = crate::share::upload(&settings, png, &name).await.map_err(|e| format!("{e:#}"))?;
    clipboard::copy_text(&link).map_err(|e| format!("{e:#}"))?;
    Ok(link)
}

/// Which secrets are stored — never the secrets themselves.
#[tauri::command]
pub fn share_secret_status() -> std::collections::BTreeMap<String, bool> {
    crate::secrets::NAMES.iter().map(|name| (name.to_string(), crate::secrets::get(name).is_some())).collect()
}

#[tauri::command]
pub fn set_share_secret(name: String, value: String) -> Result<()> {
    crate::secrets::set(&name, &value).map_err(|e| format!("{e:#}"))
}

// MARK: - Island

#[tauri::command]
pub fn island_ready(app: AppHandle, window: tauri::WebviewWindow) {
    crate::island::ready(&app, window.label());
}

#[tauri::command]
pub fn island_interactive(app: AppHandle, window: tauri::WebviewWindow, interactive: bool) {
    crate::island::set_interactive(&app, window.label(), interactive);
}

#[tauri::command]
pub fn island_take_keyboard(app: AppHandle, window: tauri::WebviewWindow) {
    crate::island::take_keyboard(&app, window.label());
}

/// The island's fixed measures, so the page and the pointer thread agree.
#[tauri::command]
pub fn island_geometry() -> serde_json::Value {
    serde_json::json!({
        "pillWidth": crate::island::PILL_WIDTH,
        "stripHeight": crate::island::STRIP_HEIGHT,
        "windowWidth": crate::island::WINDOW_WIDTH,
        "windowHeight": crate::island::WINDOW_HEIGHT,
    })
}

/// The shortcuts Klik starts with, for Settings › Shortcuts › Restore Defaults.
#[tauri::command]
pub fn default_shortcuts() -> std::collections::BTreeMap<String, String> {
    crate::settings::default_shortcuts()
}

/// What Settings › About shows: where Klik is, and the system it runs on.
#[tauri::command]
pub fn app_info() -> serde_json::Value {
    let exe = std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    serde_json::json!({ "exe": exe, "os": os_description() })
}

#[tauri::command]
pub fn reveal_app() -> Result<()> {
    let exe = std::env::current_exe().map_err(text)?;
    tauri_plugin_opener::reveal_item_in_dir(exe).map_err(text)
}

fn os_description() -> String {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // The build number tells Windows 11 (22000 and up) from 10; `ver` prints it.
        let build = std::process::Command::new("cmd")
            .args(["/C", "ver"])
            .creation_flags(0x0800_0000)
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .and_then(|v| v.trim().rsplit('.').nth(1).and_then(|b| b.parse::<u32>().ok()));
        return match build {
            Some(b) if b >= 22000 => format!("Windows 11 (build {b})"),
            Some(b) => format!("Windows 10 (build {b})"),
            None => "Windows".into(),
        };
    }
    #[cfg(not(windows))]
    std::env::consts::OS.to_string()
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayChoice {
    id: String,
    title: String,
    primary: bool,
}

/// The displays, for Settings › Island's choice of where the island goes.
#[tauri::command]
pub fn island_displays(app: AppHandle) -> Vec<DisplayChoice> {
    let primary = app.primary_monitor().ok().flatten();
    app.available_monitors()
        .unwrap_or_default()
        .iter()
        .enumerate()
        .map(|(index, m)| {
            let is_primary = primary.as_ref().is_some_and(|p| p.position() == m.position());
            let size = m.size();
            DisplayChoice {
                id: crate::island::display_id(m, index),
                title: format!("Display {} \u{2014} {} \u{d7} {}{}", index + 1, size.width, size.height, if is_primary { " (main)" } else { "" }),
                primary: is_primary,
            }
        })
        .collect()
}

/// Opens a page of Windows Settings that a Klik setting depends on.
#[tauri::command]
pub fn open_windows_settings(app: AppHandle, page: String) -> Result<()> {
    use tauri_plugin_opener::OpenerExt;
    let uri = match page.as_str() {
        "keyboard" => "ms-settings:easeofaccess-keyboard",
        "language" => "ms-settings:regionlanguage",
        _ => return Err("No such page.".into()),
    };
    app.opener().open_url(uri, None::<&str>).map_err(text)
}
