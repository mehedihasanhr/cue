//! A Windows notification, for things that finish with no window open — a capture copied,
//! text recognised — the way the Mac app flashes its menu bar icon.

use tauri::AppHandle;
use tauri_plugin_notification::NotificationExt;

pub fn send(app: &AppHandle, title: &str, body: &str) {
    if let Err(error) = app.notification().builder().title(title).body(body).show() {
        log::warn!("Could not show a notification: {error}");
    }
}
