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
    pub island: IslandSettings,
    pub panels: PanelSettings,
    pub capture: CaptureSettings,
    pub clipboard: ClipboardSettings,
    pub updates: UpdateSettings,
    /// Settings › Studio: what Klik asks Klik Studio for.
    pub studio: crate::studio::StudioSettings,
    /// The editor's tool defaults, as the editor writes them (`editor.defaults` on the Mac).
    pub editor: serde_json::Value,
}

/// Settings › Island. Defaults are the Mac's, except that the closed pill shows: a
/// Windows desktop has no notch to sit in, so an invisible one would never be found.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct IslandSettings {
    pub enabled: bool,
    /// Which display the island is on: "primary", "all", or one display's name.
    pub display: String,
    /// Replaced by `display`; still read so an older file loads, and otherwise ignored.
    #[serde(skip_serializing)]
    pub all_displays: bool,
    /// Draw the pill while closed (the Mac's "notch background").
    pub show_pill: bool,
    /// "hover" or "click".
    pub open_mode: String,
    pub hover_delay: f64,
    pub close_on_leave: bool,
    pub close_delay: f64,
    /// The tab it opens on; empty means the last one used.
    pub opens_on: String,
    pub flash_captures: bool,
    pub flash_duration: f64,
    pub statuses: bool,
    /// "lively", "quick" or "none".
    pub animation: String,
}

impl Default for IslandSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            display: "primary".into(),
            all_displays: false,
            show_pill: true,
            open_mode: "hover".into(),
            hover_delay: 0.0,
            close_on_leave: true,
            close_delay: 0.25,
            opens_on: String::new(),
            flash_captures: true,
            flash_duration: 1.8,
            statuses: true,
            animation: "lively".into(),
        }
    }
}

/// Where the Klik panel opens (Alt+Shift+K, the tray).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct PanelSettings {
    /// "pointer", "top", "center", "bottom", "topLeft", "topRight", "bottomLeft", "bottomRight".
    pub position: String,
    pub columns: u32,
}

impl Default for PanelSettings {
    fn default() -> Self {
        Self { position: "pointer".into(), columns: 4 }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CaptureSettings {
    /// Play a sound after each capture.
    pub sound: bool,
}

impl Default for CaptureSettings {
    fn default() -> Self {
        Self { sound: true }
    }
}

/// Settings › About › Updates.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct UpdateSettings {
    /// Download newer versions quietly and install them when the PC is left alone (or
    /// Klik is quit); off, Klik only says there is one.
    pub automatic: bool,
}

impl Default for UpdateSettings {
    fn default() -> Self {
        Self { automatic: true }
    }
}

/// Settings › Clipboard.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ClipboardSettings {
    /// Keep a history of what is copied.
    pub enabled: bool,
    /// How many entries; pinned ones are kept beyond it.
    pub limit: u32,
}

impl Default for ClipboardSettings {
    fn default() -> Self {
        Self { enabled: true, limit: 200 }
    }
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
            island: Default::default(),
            panels: Default::default(),
            capture: Default::default(),
            clipboard: Default::default(),
            updates: Default::default(),
            studio: Default::default(),
            editor: serde_json::Value::Null,
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
    fn the_island_starts_on_the_main_display() {
        // 0.2's files said `allDisplays: true`; they now land on the main display.
        let old: Settings = serde_json::from_str(r#"{"island":{"enabled":true,"allDisplays":true}}"#).unwrap();
        assert_eq!(old.island.display, "primary");
        let written = serde_json::to_value(&old).unwrap();
        assert!(written["island"].get("allDisplays").is_none());
        assert_eq!(written["island"]["display"], "primary");
    }

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
