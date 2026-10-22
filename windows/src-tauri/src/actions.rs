//! The things a shortcut, the tray menu or a button can ask for, by name.

use crate::{capture, capture::Mode, windows};
use tauri::AppHandle;

pub fn run(app: &AppHandle, action: &str) {
    let app = app.clone();
    let action = action.to_string();
    // Off the event loop: grabbing and encoding every display takes a moment, and the
    // tray menu or shortcut handler should not wait for it.
    tauri::async_runtime::spawn_blocking(move || {
        let result = match action.as_str() {
            "captureArea" => capture::start(&app, Mode::Area),
            "captureWindow" => capture::start(&app, Mode::Window),
            "captureFullScreen" => capture::start(&app, Mode::FullScreen),
            "captureText" => capture::start(&app, Mode::Text),
            "showHistory" => windows::open_history(&app),
            "showSettings" => windows::open_settings(&app, None),
            "recordScreen" => crate::studio::record(&app),
            "openStudio" => crate::studio::open_library(&app),
            other => match other.strip_prefix("showSettings/") {
                Some(page) => windows::open_settings(&app, Some(page)),
                None => Ok(()),
            },
        };
        if let Err(error) = result {
            log::error!("{action}: {error:#}");
            crate::island::status(&app, "exclamationmark.triangle.fill", "Couldn't do that", Some(&format!("{error:#}")));
        }
    });
}

/// `--capture area|window|fullscreen|text` or `--open history|settings[/page]` on the
/// command line, as an action.
pub fn from_args(args: &[String]) -> Option<String> {
    if let Some(index) = args.iter().position(|arg| arg == "--open") {
        let what = args.get(index + 1).map(|w| w.to_ascii_lowercase()).unwrap_or_default();
        return Some(match what.split_once('/') {
            _ if what == "settings" => "showSettings".into(),
            Some(("settings", page)) => format!("showSettings/{page}"),
            _ => "showHistory".into(),
        });
    }
    let index = args.iter().position(|arg| arg == "--capture")?;
    let action = match args.get(index + 1).map(|mode| mode.to_ascii_lowercase()).as_deref() {
        Some("window") => "captureWindow",
        Some("fullscreen") | Some("full-screen") | Some("screen") => "captureFullScreen",
        Some("text") => "captureText",
        _ => "captureArea",
    };
    Some(action.into())
}

#[cfg(test)]
mod tests {
    use super::from_args;

    #[test]
    fn reads_the_capture_flag() {
        let args = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let action = |list: &[&str]| from_args(&args(list));
        assert_eq!(action(&["cue.exe", "--capture", "window"]).as_deref(), Some("captureWindow"));
        assert_eq!(action(&["cue.exe", "--capture"]).as_deref(), Some("captureArea"));
        assert_eq!(action(&["cue.exe", "--autostart"]), None);
        assert_eq!(action(&["cue.exe", "--open", "settings"]).as_deref(), Some("showSettings"));
        assert_eq!(action(&["cue.exe", "--open", "Settings/Island"]).as_deref(), Some("showSettings/island"));
        assert_eq!(action(&["cue.exe", "--open", "history"]).as_deref(), Some("showHistory"));
    }
}
