//! Updates, as Settings › About › Updates says:
//!
//! - **Install automatically** (the default): a newer Cue is downloaded quietly and
//!   installed when the PC has been left alone for a few minutes, or when Cue is quit
//!   from the tray — never in the middle of a capture. The installer reopens Cue.
//! - **Ask first**: Cue only says there is one, on the island and as a notification;
//!   Settings › About installs it.
//!
//! Cue looks a little after it starts and then every six hours.

use crate::state::AppState;
use serde::Serialize;
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_updater::{Update, UpdaterExt};

const FIRST_LOOK: Duration = Duration::from_secs(20);
const EVERY: Duration = Duration::from_secs(6 * 60 * 60);
/// How long the PC must be left alone before an update installs by itself.
const IDLE_BEFORE_INSTALL: Duration = Duration::from_secs(5 * 60);

/// A newer version, and its installer once downloaded.
#[derive(Default)]
pub struct Updates {
    found: Mutex<Option<Update>>,
    downloaded: Mutex<Option<Vec<u8>>>,
    /// The version last announced, so "Ask first" says it once.
    announced: Mutex<Option<String>>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateState {
    /// The newer version, if there is one.
    pub version: Option<String>,
    /// Downloaded and waiting to install.
    pub ready: bool,
}

pub fn state(app: &AppHandle) -> UpdateState {
    let updates = app.state::<Updates>();
    let version = updates.found.lock().unwrap().as_ref().map(|u| u.version.clone());
    let ready = updates.downloaded.lock().unwrap().is_some();
    UpdateState { version, ready }
}

pub fn start(app: AppHandle) {
    if cfg!(debug_assertions) {
        return;
    }
    let watcher = app.clone();
    tauri::async_runtime::spawn(async move {
        sleep(FIRST_LOOK).await;
        loop {
            look(&app).await;
            sleep(EVERY).await;
        }
    });
    // Installs a downloaded update once the PC has been left alone.
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(60));
        let automatic = watcher.state::<AppState>().settings().updates.automatic;
        let ready = watcher.state::<Updates>().downloaded.lock().unwrap().is_some();
        let capturing = watcher.state::<AppState>().session.lock().unwrap().is_some();
        if automatic && ready && !capturing && idle_for() >= IDLE_BEFORE_INSTALL {
            install_now(&watcher).ok();
        }
    });
}

/// Looks for a newer version and, as Settings says, downloads it or announces it.
pub async fn look(app: &AppHandle) {
    let Ok(updater) = app.updater() else { return };
    let update = match updater.check().await {
        Ok(Some(update)) => update,
        Ok(None) => return,
        Err(error) => {
            log::info!("Update check failed: {error}");
            return;
        }
    };
    let version = update.version.clone();
    let updates = app.state::<Updates>();
    let already = updates.found.lock().unwrap().as_ref().is_some_and(|u| u.version == version)
        && updates.downloaded.lock().unwrap().is_some();
    *updates.found.lock().unwrap() = Some(update.clone());
    app.emit("update-changed", state(app)).ok();
    if already {
        return;
    }

    if app.state::<AppState>().settings().updates.automatic {
        *updates.downloaded.lock().unwrap() = None;
        match update.download(|_, _| {}, || {}).await {
            Ok(bytes) => {
                *updates.downloaded.lock().unwrap() = Some(bytes);
                app.emit("update-changed", state(app)).ok();
                crate::island::status(app, "arrow.down.fill", &format!("Cue {version} is ready"), Some("It installs when you step away, or when you quit Cue."));
            }
            Err(error) => log::warn!("Update download failed: {error}"),
        }
    } else if updates.announced.lock().unwrap().as_deref() != Some(&version) {
        *updates.announced.lock().unwrap() = Some(version.clone());
        crate::island::status(app, "arrow.down.fill", &format!("Cue {version} is available"), Some("Install it from Settings › About."));
        crate::notify::send(app, &format!("Cue {version} is available"), "Install it from Settings › About.");
    }
}

/// Installs the newer version now: from the download if there is one, else downloading
/// it first. On Windows the installer closes Cue and opens the new one.
pub async fn install(app: &AppHandle) -> anyhow::Result<()> {
    let update = app.state::<Updates>().found.lock().unwrap().clone().ok_or_else(|| anyhow::anyhow!("There is no update to install."))?;
    let waiting = app.state::<Updates>().downloaded.lock().unwrap().take();
    let bytes = match waiting {
        Some(bytes) => bytes,
        None => update.download(|_, _| {}, || {}).await?,
    };
    update.install(bytes)?;
    Ok(())
}

/// `install`, from a thread that isn't the async runtime's (the idle watcher, the tray).
pub fn install_now(app: &AppHandle) -> anyhow::Result<()> {
    tauri::async_runtime::block_on(install(app))
}

/// Quitting from the tray installs a waiting update on the way out.
pub fn quit(app: &AppHandle) {
    let ready = app.state::<Updates>().downloaded.lock().unwrap().is_some();
    if ready && app.state::<AppState>().settings().updates.automatic && install_now(app).is_ok() {
        return;
    }
    app.exit(0);
}

/// How long since the last key press or mouse move anywhere.
fn idle_for() -> Duration {
    #[cfg(windows)]
    unsafe {
        use windows::Win32::System::SystemInformation::GetTickCount;
        use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
        let mut info = LASTINPUTINFO { cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
        if GetLastInputInfo(&mut info).as_bool() {
            return Duration::from_millis(GetTickCount().wrapping_sub(info.dwTime) as u64);
        }
    }
    Duration::ZERO
}

async fn sleep(duration: Duration) {
    let (sender, receiver) = std::sync::mpsc::channel::<()>();
    std::thread::spawn(move || {
        std::thread::sleep(duration);
        sender.send(()).ok();
    });
    tauri::async_runtime::spawn_blocking(move || receiver.recv().ok()).await.ok();
}

// MARK: - Commands

#[tauri::command]
pub fn update_state(app: AppHandle) -> UpdateState {
    state(&app)
}

#[tauri::command]
pub async fn update_check(app: AppHandle) -> UpdateState {
    look(&app).await;
    state(&app)
}

#[tauri::command]
pub async fn update_install(app: AppHandle) -> Result<(), String> {
    install(&app).await.map_err(|e| e.to_string())
}
