//! The commands behind the island's tabs: the collections in `stores`, the clipboard
//! history, assets, notes, and grouping captures.

use crate::state::AppState;
use crate::stores::Stores;
use crate::{assets, cliphistory, notes, paste};
use serde_json::{Map, Value};
use std::path::PathBuf;
use tauri::{AppHandle, Emitter, Manager, State};
use uuid::Uuid;

type Result<T> = std::result::Result<T, String>;

fn text(error: impl std::fmt::Display) -> String {
    error.to_string()
}

// MARK: - Collections

#[tauri::command]
pub fn store_list(stores: State<Stores>, kind: String) -> Vec<Value> {
    stores.list(&kind)
}

#[tauri::command]
pub fn store_put(app: AppHandle, stores: State<Stores>, kind: String, item: Value) -> Result<Value> {
    stores.put(&app, &kind, item, None).ok_or_else(|| "That can't be saved.".into())
}

#[tauri::command]
pub fn store_update(app: AppHandle, stores: State<Stores>, kind: String, id: String, patch: Map<String, Value>) -> Result<Value> {
    stores.update(&app, &kind, &id, patch).ok_or_else(|| "That is gone.".into())
}

#[tauri::command]
pub fn store_delete(app: AppHandle, stores: State<Stores>, kind: String, ids: Vec<String>) {
    stores.delete(&app, &kind, &ids);
}

#[tauri::command]
pub fn store_clear_unpinned(app: AppHandle, stores: State<Stores>, kind: String) {
    stores.clear_unpinned(&app, &kind);
}

// MARK: - Clipboard

fn entry(stores: &Stores, id: &str) -> Result<Value> {
    stores.get("clipboard", id).ok_or_else(|| "That entry is gone.".into())
}

#[tauri::command]
pub async fn clip_copy(app: AppHandle, id: String) -> Result<()> {
    let item = entry(&app.state::<Stores>(), &id)?;
    cliphistory::copy_entry(&app, &item).map_err(text)
}

/// Copies `text` (a card's text, transformed or not) and, with `paste`, pastes it.
#[tauri::command]
pub async fn copy_text_and_paste(text_value: String, paste: bool) -> Result<bool> {
    crate::clipboard::copy_text(&text_value).map_err(text)?;
    Ok(paste && paste::press_paste())
}

/// Puts a clipboard entry, a capture or an asset on the clipboard and presses Ctrl+V.
/// False when pasting isn't possible here: it is copied, and the island says so.
#[tauri::command]
pub async fn paste_item(app: AppHandle, kind: String, id: String) -> Result<bool> {
    match kind.as_str() {
        "clipboard" => cliphistory::copy_entry(&app, &entry(&app.state::<Stores>(), &id)?).map_err(text)?,
        "captures" => {
            let id = Uuid::parse_str(&id).map_err(text)?;
            let path = app.state::<AppState>().library.lock().unwrap().path(id).ok_or("That capture is gone.")?;
            let image = image::open(path).map_err(text)?.to_rgba8();
            crate::clipboard::copy_image(&image).map_err(text)?;
        }
        "assets" => copy_asset(&app, &id)?,
        _ => return Err("That can't be pasted.".into()),
    }
    Ok(paste::press_paste())
}

#[tauri::command]
pub fn forget_front() {
    paste::forget_front();
}

// MARK: - Assets

#[tauri::command]
pub async fn assets_add_paths(app: AppHandle, paths: Vec<PathBuf>) -> usize {
    assets::add_paths(&app, &paths)
}

#[tauri::command]
pub async fn assets_add_clipboard(app: AppHandle) -> usize {
    assets::add_clipboard(&app)
}

fn copy_asset(app: &AppHandle, id: &str) -> Result<()> {
    let path = assets::path(app, id).ok_or("That asset is gone.")?;
    let is_image = app.state::<Stores>().get("assets", id).and_then(|a| a.get("kind").cloned()) == Some(Value::from("image"));
    if is_image {
        if let Ok(image) = image::open(&path) {
            return crate::clipboard::copy_image(&image.to_rgba8()).map_err(text);
        }
    }
    cliphistory::mark_own_copy();
    arboard::Clipboard::new().and_then(|mut c| c.set().file_list(&[path])).map_err(text)
}

#[tauri::command]
pub async fn asset_copy(app: AppHandle, id: String) -> Result<()> {
    copy_asset(&app, &id)
}

#[tauri::command]
pub fn asset_open(app: AppHandle, id: String) -> Result<()> {
    use tauri_plugin_opener::OpenerExt;
    let path = assets::path(&app, &id).ok_or("That asset is gone.")?;
    app.opener().open_path(path.to_string_lossy(), None::<&str>).map_err(text)
}

#[tauri::command]
pub fn asset_reveal(app: AppHandle, id: String) -> Result<()> {
    let path = assets::path(&app, &id).ok_or("That asset is gone.")?;
    tauri_plugin_opener::reveal_item_in_dir(path).map_err(text)
}

#[tauri::command]
pub fn asset_rename(app: AppHandle, id: String, title: String) -> Result<()> {
    assets::rename(&app, &id, &title).map_err(text)
}

// MARK: - Notes

pub struct NotesFolder(pub PathBuf);

#[tauri::command]
pub fn notes_list(folder: State<NotesFolder>) -> Vec<notes::Note> {
    notes::list(&folder.0)
}

#[tauri::command]
pub fn note_save(app: AppHandle, folder: State<NotesFolder>, id: Option<String>, text_value: String) -> Result<String> {
    let id = notes::save(&folder.0, id.as_deref(), &text_value).map_err(text)?;
    app.emit("store-changed", "notes").ok();
    Ok(id)
}

#[tauri::command]
pub fn note_delete(app: AppHandle, folder: State<NotesFolder>, id: String) -> Result<()> {
    notes::delete(&folder.0, &id).map_err(text)?;
    app.emit("store-changed", "notes").ok();
    Ok(())
}

#[tauri::command]
pub fn note_reveal(folder: State<NotesFolder>, id: String) -> Result<()> {
    let path = folder.0.join(format!("{id}.md"));
    tauri_plugin_opener::reveal_item_in_dir(if path.exists() { path } else { folder.0.clone() }).map_err(text)
}

// MARK: - Captures

#[tauri::command]
pub fn history_set_group(app: AppHandle, state: State<AppState>, id: Uuid, group: Option<Uuid>) -> Result<()> {
    state.library.lock().unwrap().set_group(id, group).map_err(text)?;
    app.emit("library-changed", ()).ok();
    Ok(())
}

/// Deletes captures that are neither pinned nor grouped ("Clear Unpinned Captures").
#[tauri::command]
pub async fn history_clear_unpinned(app: AppHandle) -> Result<usize> {
    let state = app.state::<AppState>();
    let ids: Vec<Uuid> = state.library.lock().unwrap().items().iter().filter(|i| !i.pinned && i.group_id.is_none()).map(|i| i.id).collect();
    let mut removed = 0;
    for id in ids {
        if state.library.lock().unwrap().delete(id).is_ok() {
            removed += 1;
        }
    }
    app.emit("library-changed", ()).ok();
    Ok(removed)
}

// MARK: - Links

/// Opens a web or mail link from a clipboard card.
#[tauri::command]
pub fn open_link(app: AppHandle, url: String) -> Result<()> {
    use tauri_plugin_opener::OpenerExt;
    let lower = url.to_ascii_lowercase();
    if !["http://", "https://", "mailto:", "ftp://"].iter().any(|s| lower.starts_with(s)) {
        return Err("Only web and mail links open.".into());
    }
    app.opener().open_url(url, None::<&str>).map_err(text)
}

/// Opens a path from a Files clipboard entry, or shows it in Explorer.
#[tauri::command]
pub fn reveal_path(path: PathBuf) -> Result<()> {
    tauri_plugin_opener::reveal_item_in_dir(path).map_err(text)
}
