//! A quiet check for a newer Klik a little after launch. Installing is the user's call,
//! from Settings › About; this only says there is something to install.

use std::time::Duration;
use tauri::AppHandle;
use tauri_plugin_updater::UpdaterExt;

pub fn check_later(app: AppHandle) {
    if cfg!(debug_assertions) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        tokio_sleep(Duration::from_secs(20)).await;
        let Ok(updater) = app.updater() else { return };
        match updater.check().await {
            Ok(Some(update)) => crate::notify::send(
                &app,
                &format!("Klik {} is available", update.version),
                "Install it from Settings › About.",
            ),
            Ok(None) => {}
            Err(error) => log::info!("Update check failed: {error}"),
        }
    });
}

async fn tokio_sleep(duration: Duration) {
    let (sender, receiver) = std::sync::mpsc::channel::<()>();
    std::thread::spawn(move || {
        std::thread::sleep(duration);
        sender.send(()).ok();
    });
    tauri::async_runtime::spawn_blocking(move || receiver.recv().ok()).await.ok();
}
