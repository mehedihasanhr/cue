//! Global shortcuts, from Settings.

use crate::{actions, state::AppState};
use serde::Serialize;
use tauri::{AppHandle, Manager};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

/// A shortcut that could not be registered — usually because another app holds it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Conflict {
    pub action: String,
    pub accelerator: String,
    pub message: String,
}

/// Registers every shortcut in Settings, replacing whatever was registered before.
pub fn apply(app: &AppHandle) -> Vec<Conflict> {
    let shortcuts = app.global_shortcut();
    shortcuts.unregister_all().ok();
    let settings = app.state::<AppState>().settings();
    let mut conflicts = Vec::new();
    for (action, accelerator) in settings.shortcuts {
        if accelerator.trim().is_empty() {
            continue;
        }
        let name = action.clone();
        let result = shortcuts.on_shortcut(accelerator.as_str(), move |app, _shortcut, event| {
            if event.state == ShortcutState::Pressed {
                actions::run(app, &name);
            }
        });
        if let Err(error) = result {
            conflicts.push(Conflict { action, accelerator, message: error.to_string() });
        }
    }
    conflicts
}
