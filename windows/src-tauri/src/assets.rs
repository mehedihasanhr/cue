//! Assets: files and pictures kept to hand on the island — the Mac's `AssetStore`. Each
//! one is copied into `Assets\<id>\<its name>`; the index is the `assets` store.

use crate::stores::Stores;
use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "avif"];

fn is_image(path: &Path) -> bool {
    path.extension().and_then(|e| e.to_str()).is_some_and(|e| IMAGE_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
}

/// Copies `paths` in as assets; returns how many were saved. Folders are skipped.
pub fn add_paths(app: &AppHandle, paths: &[PathBuf]) -> usize {
    paths.iter().filter(|p| p.is_file()).filter(|p| add_file(app, p).is_ok()).count()
}

fn add_file(app: &AppHandle, source: &Path) -> Result<Value> {
    let stores = app.state::<Stores>();
    let id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let name = source.file_name().context("No file name")?.to_string_lossy().into_owned();
    let folder = stores.assets_folder().join(&id);
    std::fs::create_dir_all(&folder)?;
    let target = folder.join(&name);
    std::fs::copy(source, &target).context("Could not copy the file")?;
    Ok(record(app, &id, &name, &target))
}

/// The clipboard's files, or its picture saved as "Image <date>.png".
pub fn add_clipboard(app: &AppHandle) -> usize {
    let Ok(mut clipboard) = arboard::Clipboard::new() else { return 0 };
    if let Ok(files) = clipboard.get().file_list() {
        if !files.is_empty() {
            return add_paths(app, &files);
        }
    }
    let Ok(image) = clipboard.get_image() else { return 0 };
    let Some(rgba) = image::RgbaImage::from_raw(image.width as u32, image.height as u32, image.bytes.into_owned()) else { return 0 };
    add_image(app, &rgba).map(|_| 1).unwrap_or(0)
}

pub fn add_image(app: &AppHandle, image: &image::RgbaImage) -> Result<Value> {
    let stores = app.state::<Stores>();
    let id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let name = format!("Image {}.png", chrono::Local::now().format("%Y-%m-%d at %H.%M.%S"));
    let folder = stores.assets_folder().join(&id);
    std::fs::create_dir_all(&folder)?;
    let target = folder.join(&name);
    image.save_with_format(&target, image::ImageFormat::Png)?;
    Ok(record(app, &id, &name, &target))
}

fn record(app: &AppHandle, id: &str, name: &str, path: &Path) -> Value {
    let byte_size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let image = is_image(path);
    let mut item = json!({
        "id": id,
        "fileName": name,
        "kind": if image { "image" } else { "file" },
        "byteSize": byte_size,
        "pinned": false,
    });
    if image {
        if let Ok((w, h)) = image::image_dimensions(path) {
            item["pixelWidth"] = json!(w);
            item["pixelHeight"] = json!(h);
        }
    }
    app.state::<Stores>().put(app, "assets", item.clone(), None);
    item
}

/// Where an asset's file is.
pub fn path(app: &AppHandle, id: &str) -> Option<PathBuf> {
    let item = app.state::<Stores>().get("assets", id)?;
    let name = item.get("fileName")?.as_str()?;
    Some(app.state::<Stores>().assets_folder().join(id).join(name))
}

/// Renames an asset's file, keeping its extension when the new name has none.
pub fn rename(app: &AppHandle, id: &str, title: &str) -> Result<()> {
    let old = path(app, id).context("That asset is gone")?;
    let clean: String = title.chars().filter(|c| !r#"<>:"/\|?*"#.contains(*c) && !c.is_control()).collect();
    let clean = clean.trim();
    anyhow::ensure!(!clean.is_empty(), "That name is empty");
    let mut name = clean.to_string();
    if Path::new(clean).extension().is_none() {
        if let Some(ext) = old.extension() {
            name = format!("{clean}.{}", ext.to_string_lossy());
        }
    }
    std::fs::rename(&old, old.with_file_name(&name)).context("Could not rename the file")?;
    let mut patch = serde_json::Map::new();
    patch.insert("fileName".into(), json!(name));
    app.state::<Stores>().update(app, "assets", id, patch);
    Ok(())
}
