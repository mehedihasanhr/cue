//! Preferences, kept as one JSON file in `%APPDATA%\Klik\settings.json`.
//!
//! Key names follow the Mac app's (`capture.after` there is `afterCapture` here) so the
//! two read alike, but the file is this app's own: nothing on Windows reads macOS
//! defaults.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AfterCapture {
    /// Open the editor on the new capture.
    Edit,
    /// Only copy it (and keep it in History).
    Copy,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub after_capture: AfterCapture,
    /// Copy every capture to the clipboard as it is taken.
    pub copy_to_clipboard: bool,
    /// Where captures are saved; `None` is `Pictures\Klik`.
    pub save_folder: Option<PathBuf>,
    /// Action → accelerator, in Tauri's syntax ("Alt+Shift+4"). Empty means none.
    pub shortcuts: BTreeMap<String, String>,
    /// "system", "light" or "dark".
    pub appearance: String,
    pub share: crate::share::ShareSettings,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            after_capture: AfterCapture::Edit,
            copy_to_clipboard: true,
            save_folder: None,
            shortcuts: default_shortcuts(),
            appearance: "system".into(),
            share: Default::default(),
        }
    }
}

/// The Mac's ⌥⇧ set, as Alt+Shift: 3 full screen, 4 area, 6 window, T text, K Klik.
/// Win+Shift+S is left to Windows' own Snipping Tool.
pub fn default_shortcuts() -> BTreeMap<String, String> {
    [
        ("captureArea", "Alt+Shift+4"),
        ("captureWindow", "Alt+Shift+6"),
        ("captureFullScreen", "Alt+Shift+3"),
        ("captureText", "Alt+Shift+T"),
        ("showHistory", "Alt+Shift+K"),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

impl Settings {
    pub fn load(path: &PathBuf) -> Self {
        let mut settings: Settings = std::fs::read(path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default();
        // A shortcut added in a later version shows up with its default.
        for (action, accelerator) in default_shortcuts() {
            settings.shortcuts.entry(action).or_insert(accelerator);
        }
        settings
    }

    pub fn save(&self, path: &PathBuf) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let data = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
        let temporary = path.with_extension("json.tmp");
        std::fs::write(&temporary, data)?;
        std::fs::rename(temporary, path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_fields_take_defaults() {
        let settings: Settings = serde_json::from_str(r#"{"afterCapture":"copy"}"#).unwrap();
        assert_eq!(settings.after_capture, AfterCapture::Copy);
        assert!(settings.copy_to_clipboard);
        assert_eq!(settings.shortcuts["captureArea"], "Alt+Shift+4");
    }

    #[test]
    fn round_trips() {
        let dir = std::env::temp_dir().join(format!("klik-settings-{}", std::process::id()));
        let path = dir.join("settings.json");
        let mut settings = Settings::default();
        settings.shortcuts.insert("captureArea".into(), String::new());
        settings.save(&path).unwrap();
        assert_eq!(Settings::load(&path), settings);
        std::fs::remove_dir_all(dir).ok();
    }
}
