use crate::{capture::Session, hotkeys::Conflict, library::Library, settings::Settings};
use std::path::PathBuf;
use std::sync::Mutex;

pub struct AppState {
    pub settings: Mutex<Settings>,
    pub settings_path: PathBuf,
    pub library: Mutex<Library>,
    pub session: Mutex<Option<Session>>,
    /// Shortcuts Windows would not give us, for Settings to point out.
    pub conflicts: Mutex<Vec<Conflict>>,
}

impl AppState {
    pub fn settings(&self) -> Settings {
        self.settings.lock().unwrap().clone()
    }
}

/// `Pictures\Cue`, where captures go unless Settings says otherwise.
pub fn default_captures_folder() -> PathBuf {
    dirs_pictures().join("Cue")
}

fn dirs_pictures() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("Pictures")
}
