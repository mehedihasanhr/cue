//! The app's windows. There is no main window: Klik lives in the tray, and each window
//! here is made when it is asked for. The web side picks what to draw from the label.

use anyhow::Result;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use uuid::Uuid;

/// Shows the window `label`, making it first if there is none.
fn show(app: &AppHandle, label: &str, title: &str, size: (f64, f64), min: (f64, f64)) -> Result<WebviewWindow> {
    if let Some(window) = app.get_webview_window(label) {
        window.unminimize().ok();
        window.show()?;
        window.set_focus()?;
        return Ok(window);
    }
    let window = WebviewWindowBuilder::new(app, label, WebviewUrl::App("index.html".into()))
        .title(title)
        .inner_size(size.0, size.1)
        .min_inner_size(min.0, min.1)
        .center()
        .visible(false) // shown by the page once it has drawn, so it never flashes white
        .build()?;
    Ok(window)
}

pub fn open_settings(app: &AppHandle) -> Result<()> {
    show(app, "settings", "Klik Settings", (760.0, 560.0), (640.0, 440.0)).map(|_| ())
}

pub fn open_history(app: &AppHandle) -> Result<()> {
    show(app, "history", "Klik History", (900.0, 620.0), (520.0, 400.0)).map(|_| ())
}

pub fn open_editor(app: &AppHandle, id: Uuid) -> Result<()> {
    show(app, &format!("editor-{id}"), "Klik Editor", (1100.0, 760.0), (720.0, 480.0)).map(|_| ())
}

/// A capture floating above every window, at its real size — for keeping a reference in
/// view while working in another app.
pub fn open_pin(app: &AppHandle, id: Uuid) -> Result<()> {
    use crate::state::AppState;
    let label = format!("pin-{id}");
    if let Some(window) = app.get_webview_window(&label) {
        window.show()?;
        window.set_focus()?;
        return Ok(());
    }
    let item = app.state::<AppState>().library.lock().unwrap().item(id).cloned();
    let item = item.ok_or_else(|| anyhow::anyhow!("That capture is gone."))?;
    // Its size in points, no larger than most of the screen.
    let mut width = item.pixel_width as f64 / item.scale.max(1.0);
    let mut height = item.pixel_height as f64 / item.scale.max(1.0);
    if let Ok(Some(monitor)) = app.primary_monitor() {
        let screen = monitor.size().to_logical::<f64>(monitor.scale_factor());
        let fit = (screen.width * 0.6 / width).min(screen.height * 0.6 / height).min(1.0);
        width *= fit;
        height *= fit;
    }
    WebviewWindowBuilder::new(app, &label, WebviewUrl::App("index.html".into()))
        .title("Klik Pin")
        .inner_size(width.max(80.0), height.max(60.0))
        .min_inner_size(60.0, 40.0)
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .transparent(true)
        .center()
        .visible(false)
        .build()?;
    Ok(())
}
