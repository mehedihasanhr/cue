//! History: every capture, saved as a PNG in the captures folder, with an index beside
//! the app's data.
//!
//! The index mirrors the Mac's `library.json` field for field, minus the security-scoped
//! bookmark, which Windows has no use for: a file is found by its name in the folder.

use anyhow::{Context, Result};
use chrono::{DateTime, Local, Utc};
use image::{ImageFormat, RgbaImage};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CaptureItem {
    pub id: Uuid,
    pub file_name: String,
    pub created_at: DateTime<Utc>,
    pub pixel_width: u32,
    pub pixel_height: u32,
    /// The display's scale when it was taken: 1.5 at 150%.
    pub scale: f64,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default, rename = "groupID", skip_serializing_if = "Option::is_none")]
    pub group_id: Option<Uuid>,
}

pub struct Library {
    folder: PathBuf,
    index: PathBuf,
    thumbnails: PathBuf,
    items: Vec<CaptureItem>, // newest first
}

impl Library {
    pub fn open(folder: PathBuf, data_dir: &Path) -> Self {
        let index = data_dir.join("library.json");
        let items: Vec<CaptureItem> = std::fs::read(&index)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default();
        let mut library = Self { folder, index, thumbnails: data_dir.join("Thumbnails"), items };
        library.forget_missing();
        library
    }

    pub fn folder(&self) -> &Path {
        &self.folder
    }

    /// Points History at another folder. Captures that are not in it drop out of the
    /// list; their files are left where they are.
    pub fn set_folder(&mut self, folder: PathBuf) {
        if folder != self.folder {
            self.folder = folder;
            self.forget_missing();
            self.write_index().ok();
        }
    }

    pub fn items(&self) -> &[CaptureItem] {
        &self.items
    }

    pub fn item(&self, id: Uuid) -> Option<&CaptureItem> {
        self.items.iter().find(|item| item.id == id)
    }

    pub fn path(&self, id: Uuid) -> Option<PathBuf> {
        self.item(id).map(|item| self.folder.join(&item.file_name))
    }

    /// Saves `image` as a new capture and returns it.
    pub fn add(&mut self, image: &RgbaImage, scale: f64) -> Result<CaptureItem> {
        std::fs::create_dir_all(&self.folder).context("Could not create the captures folder")?;
        let now = Local::now();
        let path = unique_path(&self.folder, &file_name(now));
        image.save_with_format(&path, ImageFormat::Png).context("Could not save the capture")?;
        let item = CaptureItem {
            id: Uuid::new_v4(),
            file_name: path.file_name().unwrap().to_string_lossy().into_owned(),
            created_at: now.with_timezone(&Utc),
            pixel_width: image.width(),
            pixel_height: image.height(),
            scale,
            pinned: false,
            group_id: None,
        };
        self.items.insert(0, item.clone());
        self.write_index()?;
        Ok(item)
    }

    /// Replaces a capture's pixels — the editor saving over it.
    pub fn replace(&mut self, id: Uuid, image: &RgbaImage) -> Result<()> {
        let path = self.path(id).context("No such capture")?;
        image.save_with_format(&path, ImageFormat::Png)?;
        if let Some(item) = self.items.iter_mut().find(|item| item.id == id) {
            item.pixel_width = image.width();
            item.pixel_height = image.height();
        }
        std::fs::remove_file(self.thumbnail_path(id)).ok();
        self.write_index()
    }

    /// Moves the file to the Recycle Bin, not away for good.
    pub fn delete(&mut self, id: Uuid) -> Result<()> {
        if let Some(path) = self.path(id) {
            if path.exists() {
                trash::delete(&path).context("Could not move the capture to the Recycle Bin")?;
            }
        }
        std::fs::remove_file(self.thumbnail_path(id)).ok();
        self.items.retain(|item| item.id != id);
        self.write_index()
    }

    pub fn rename(&mut self, id: Uuid, title: &str) -> Result<CaptureItem> {
        let title = sanitize(title);
        anyhow::ensure!(!title.is_empty(), "A name can't be empty");
        let old = self.path(id).context("No such capture")?;
        let target = unique_path(&self.folder, &format!("{title}.png"));
        std::fs::rename(&old, &target).context("Could not rename the capture")?;
        let item = self.items.iter_mut().find(|item| item.id == id).unwrap();
        item.file_name = target.file_name().unwrap().to_string_lossy().into_owned();
        let item = item.clone();
        self.write_index()?;
        Ok(item)
    }

    pub fn set_pinned(&mut self, id: Uuid, pinned: bool) -> Result<()> {
        if let Some(item) = self.items.iter_mut().find(|item| item.id == id) {
            item.pinned = pinned;
        }
        self.write_index()
    }

    pub fn thumbnail_path(&self, id: Uuid) -> PathBuf {
        self.thumbnails.join(format!("{id}.jpg"))
    }

    /// A 480-pixel-wide JPEG of the capture, made the first time it is asked for.
    pub fn thumbnail(&self, id: Uuid) -> Result<Vec<u8>> {
        let cached = self.thumbnail_path(id);
        if let Ok(data) = std::fs::read(&cached) {
            return Ok(data);
        }
        let source = image::open(self.path(id).context("No such capture")?)?;
        let small = source.thumbnail(480, 480).to_rgb8();
        let mut data = Vec::new();
        small.write_to(&mut std::io::Cursor::new(&mut data), ImageFormat::Jpeg)?;
        std::fs::create_dir_all(&self.thumbnails).ok();
        std::fs::write(&cached, &data).ok();
        Ok(data)
    }

    fn forget_missing(&mut self) {
        let folder = self.folder.clone();
        self.items.retain(|item| folder.join(&item.file_name).exists());
    }

    fn write_index(&self) -> Result<()> {
        if let Some(parent) = self.index.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let temporary = self.index.with_extension("json.tmp");
        std::fs::write(&temporary, serde_json::to_vec(&self.items)?)?;
        std::fs::rename(temporary, &self.index)?;
        Ok(())
    }
}

/// "Screenshot 2026-10-15 at 14.03.27.png" — the Mac's name for a capture, so a folder
/// of both sorts the same way.
pub fn file_name(at: DateTime<Local>) -> String {
    format!("Screenshot {}.png", at.format("%Y-%m-%d at %H.%M.%S"))
}

/// `name` in `folder`, or "name (2)", "name (3)"… when it is taken.
pub fn unique_path(folder: &Path, name: &str) -> PathBuf {
    let candidate = folder.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let path = Path::new(name);
    let stem = path.file_stem().unwrap_or_default().to_string_lossy();
    let extension = path.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    (2..)
        .map(|n| folder.join(format!("{stem} ({n}){extension}")))
        .find(|candidate| !candidate.exists())
        .unwrap()
}

/// A name Windows will accept as a file name.
fn sanitize(title: &str) -> String {
    title
        .chars()
        .map(|c| if r#"<>:"/\|?*"#.contains(c) || c.is_control() { '-' } else { c })
        .collect::<String>()
        .trim()
        .trim_end_matches('.')
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn names_like_the_mac() {
        let at = Local.with_ymd_and_hms(2026, 10, 15, 14, 3, 7).unwrap();
        assert_eq!(file_name(at), "Screenshot 2026-10-15 at 14.03.07.png");
    }

    #[test]
    fn numbers_a_taken_name() {
        let dir = std::env::temp_dir().join(format!("klik-names-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.png"), b"").unwrap();
        std::fs::write(dir.join("a (2).png"), b"").unwrap();
        assert_eq!(unique_path(&dir, "a.png"), dir.join("a (3).png"));
        assert_eq!(unique_path(&dir, "b.png"), dir.join("b.png"));
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn cleans_names() {
        assert_eq!(sanitize(" a/b:c? "), "a-b-c-");
        assert_eq!(sanitize("report."), "report");
    }

    #[test]
    fn adds_renames_and_lists() {
        let root = std::env::temp_dir().join(format!("klik-library-{}", std::process::id()));
        let mut library = Library::open(root.join("captures"), &root.join("data"));
        let item = library.add(&RgbaImage::new(4, 3), 1.5).unwrap();
        assert_eq!((item.pixel_width, item.pixel_height), (4, 3));
        let renamed = library.rename(item.id, "Bug report").unwrap();
        assert_eq!(renamed.file_name, "Bug report.png");
        let reopened = Library::open(root.join("captures"), &root.join("data"));
        assert_eq!(reopened.items().len(), 1);
        assert!(reopened.thumbnail(item.id).is_ok());
        std::fs::remove_dir_all(root).ok();
    }
}
