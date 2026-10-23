//! The app's windows. There is no main window: Cue lives in the tray, and each window
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

/// Settings: the Mac's 920 × 640 window, drawn edge to edge by the page — its own
/// caption buttons, Mica behind the sidebar and page on Windows 11.
/// `page` opens it on that page ("island", "shortcuts", …).
pub fn open_settings(app: &AppHandle, page: Option<&str>) -> Result<()> {
    use tauri::Emitter;
    if let Some(window) = app.get_webview_window("settings") {
        if let Some(page) = page {
            app.emit_to("settings", "settings:go", page).ok();
        }
        window.unminimize().ok();
        window.show()?;
        window.set_focus()?;
        return Ok(());
    }
    // A new window reads the page from its address, being too young to hear an event.
    let url = format!("index.html#{}", page.unwrap_or(""));
    let builder = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App(url.into()))
        .title("Cue Settings")
        .inner_size(920.0, 640.0)
        .min_inner_size(760.0, 480.0)
        .center()
        .decorations(false)
        .transparent(true)
        // Keeps Windows 11's rounded corners and shadow on a window without a frame.
        .shadow(true)
        .visible(false);
    #[cfg(windows)]
    let builder = builder.effects(tauri::utils::config::WindowEffectsConfig {
        effects: vec![tauri::window::Effect::Mica],
        ..Default::default()
    });
    builder.build()?;
    Ok(())
}

/// The Cue panel: the Mac's floating panel, opened where Settings › Island › Panels
/// says — at the pointer by default. Made once and kept, so it opens instantly.
pub fn open_history(app: &AppHandle) -> Result<()> {
    use crate::state::AppState;
    use tauri::{LogicalPosition, LogicalSize, Emitter};
    const SIZE: (f64, f64) = (700.0 + 48.0, 520.0 + 48.0);
    let window = match app.get_webview_window("panel") {
        Some(window) => window,
        None => WebviewWindowBuilder::new(app, "panel", WebviewUrl::App("index.html".into()))
            .title("Cue")
            .inner_size(SIZE.0, SIZE.1)
            .decorations(false)
            .transparent(true)
            .shadow(false)
            .resizable(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .visible(false)
            .build()?,
    };
    let position = app.state::<AppState>().settings().panels.position;
    if let (Ok(cursor), Ok(Some(monitor))) = (app.cursor_position(), app.monitor_from_point(
        app.cursor_position().map(|c| c.x).unwrap_or(0.0),
        app.cursor_position().map(|c| c.y).unwrap_or(0.0),
    )) {
        let scale = monitor.scale_factor();
        let area = monitor.work_area();
        let (left, top) = (area.position.x as f64 / scale, area.position.y as f64 / scale);
        let (width, height) = (area.size.width as f64 / scale, area.size.height as f64 / scale);
        let (pointer_x, pointer_y) = (cursor.x / scale, cursor.y / scale);
        let (x, y) = match position.as_str() {
            "top" => (left + (width - SIZE.0) / 2.0, top),
            "center" => (left + (width - SIZE.0) / 2.0, top + (height - SIZE.1) / 2.0),
            "bottom" => (left + (width - SIZE.0) / 2.0, top + height - SIZE.1),
            "topLeft" => (left, top),
            "topRight" => (left + width - SIZE.0, top),
            "bottomLeft" => (left, top + height - SIZE.1),
            "bottomRight" => (left + width - SIZE.0, top + height - SIZE.1),
            _ => (pointer_x - SIZE.0 / 2.0, pointer_y - 60.0),
        };
        let x = x.clamp(left, left + width - SIZE.0);
        let y = y.clamp(top, top + height - SIZE.1);
        window.set_size(LogicalSize::new(SIZE.0, SIZE.1)).ok();
        window.set_position(LogicalPosition::new(x, y)).ok();
    }
    window.show()?;
    window.set_focus()?;
    app.emit_to("panel", "panel:shown", ()).ok();
    Ok(())
}

pub fn open_editor(app: &AppHandle, id: Uuid) -> Result<()> {
    show(app, &format!("editor-{id}"), "Cue Editor", (1100.0, 760.0), (720.0, 480.0)).map(|_| ())
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
        .title("Cue Pin")
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
