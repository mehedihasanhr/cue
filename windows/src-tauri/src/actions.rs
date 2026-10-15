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
            "showSettings" => windows::open_settings(&app),
            _ => Ok(()),
        };
        if let Err(error) = result {
            log::error!("{action}: {error:#}");
            crate::notify::send(&app, "Klik", &format!("{error:#}"));
        }
    });
}

/// `--capture area|window|fullscreen|text` or `--open history|settings` on the command
/// line, as an action.
pub fn from_args(args: &[String]) -> Option<&'static str> {
    if let Some(index) = args.iter().position(|arg| arg == "--open") {
        return Some(match args.get(index + 1).map(|w| w.to_ascii_lowercase()).as_deref() {
            Some("settings") => "showSettings",
            _ => "showHistory",
        });
    }
    let index = args.iter().position(|arg| arg == "--capture")?;
    match args.get(index + 1).map(|mode| mode.to_ascii_lowercase()).as_deref() {
        Some("window") => Some("captureWindow"),
        Some("fullscreen") | Some("full-screen") | Some("screen") => Some("captureFullScreen"),
        Some("text") => Some("captureText"),
        _ => Some("captureArea"),
    }
}

#[cfg(test)]
mod tests {
    use super::from_args;

    #[test]
    fn reads_the_capture_flag() {
        let args = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(from_args(&args(&["klik.exe", "--capture", "window"])), Some("captureWindow"));
        assert_eq!(from_args(&args(&["klik.exe", "--capture"])), Some("captureArea"));
        assert_eq!(from_args(&args(&["klik.exe", "--autostart"])), None);
        assert_eq!(from_args(&args(&["klik.exe", "--open", "settings"])), Some("showSettings"));
    }
}
