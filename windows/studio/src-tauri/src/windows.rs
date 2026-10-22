//! Studio's windows, made when asked for:
//!
//! - `bar`: the recorder bar, a floating pill at the bottom of the main display.
//! - `picker-N`: a clear overlay on display N for choosing a display, a window or an area.
//! - `library`: every recording.
//! - `editor-<n>`: one recording being edited.
//!
//! And the ways in: a plain launch shows the bar; Cue's `cue-studio://record?request=…`
//! shows it ready for what Cue asked; a `.cuerec` folder opens in the editor.

use anyhow::Result;
use std::hash::{Hash, Hasher};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};

const BAR_SIZE: (f64, f64) = (560.0, 76.0);

pub fn handle_args(app: &AppHandle, args: &[String]) {
    if let Some(link) = args.iter().find(|a| a.starts_with("cue-studio://")) {
        handle_link(app, link);
        return;
    }
    if let Some(package) = args.iter().skip(1).find(|a| a.trim_end_matches(['/', '\\']).ends_with(".cuerec")) {
        // A debug build can be told where to put the playhead or what to export, so the
        // editor can be checked without anyone clicking (`--demo=t=2.5;export=out.mp4`).
        let demo = if cfg!(debug_assertions) { args.iter().find_map(|a| a.strip_prefix("--demo=")) } else { None };
        match demo {
            Some(spec) => open_editor(app, &format!("{package}|{spec}")).ok(),
            None => open_editor(app, package).ok(),
        };
        return;
    }
    if args.iter().any(|a| a == "--library") {
        open_library(app).ok();
        return;
    }
    show_bar(app).ok();
}

/// `cue-studio://record?request=<path>`: Cue's request — what to record, with sound or
/// not — as a JSON file (the Mac's AddOnKit `RecordingRequest`).
fn handle_link(app: &AppHandle, link: &str) {
    if link.trim_end_matches('/').ends_with("://library") {
        open_library(app).ok();
        return;
    }
    let request = link
        .split_once("request=")
        .map(|(_, path)| urlencoding_decode(path))
        // Cue's request is a file for this one hand-off; it goes once read.
        .and_then(|path| std::fs::read(&path).ok().inspect(|_| drop(std::fs::remove_file(&path))))
        .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok());
    show_bar(app).ok();
    if let Some(request) = request {
        // The bar reads it: target, microphone, system audio, countdown.
        let app = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(600));
            app.emit_to("bar", "studio:request", request).ok();
        });
    }
}

fn urlencoding_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&text[i + 1..i + 3], 16) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(if bytes[i] == b'+' { b' ' } else { bytes[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn show_bar(app: &AppHandle) -> Result<()> {
    if let Some(window) = app.get_webview_window("bar") {
        window.show()?;
        window.set_focus()?;
        return Ok(());
    }
    let window = WebviewWindowBuilder::new(app, "bar", WebviewUrl::App("index.html".into()))
        .title("Cue Studio")
        .inner_size(BAR_SIZE.0, BAR_SIZE.1)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(false)
        .visible(false)
        .build()?;
    // At the bottom centre of the main display, clear of the taskbar.
    if let Ok(Some(monitor)) = window.primary_monitor() {
        let area = monitor.work_area();
        let scale = monitor.scale_factor();
        let (w, h) = ((BAR_SIZE.0 * scale) as i32, (BAR_SIZE.1 * scale) as i32);
        window
            .set_position(PhysicalPosition::new(area.position.x + (area.size.width as i32 - w) / 2, area.position.y + area.size.height as i32 - h - (24.0 * scale) as i32))
            .ok();
    }
    Ok(())
}

/// One clear overlay per display for choosing what to record (`mode`: display, window
/// or area). They are shut as recording starts or the choice is called off.
pub fn open_pickers(app: &AppHandle, mode: &str) -> Result<()> {
    close_pickers(app);
    let monitors = app.available_monitors()?;
    for (index, monitor) in monitors.iter().enumerate() {
        let label = format!("picker-{index}");
        let window = WebviewWindowBuilder::new(app, &label, WebviewUrl::App(format!("index.html#{mode}").into()))
            .title("Choose what to record")
            .decorations(false)
            .transparent(true)
            .shadow(false)
            .resizable(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .visible(false)
            .build()?;
        window.set_position(*monitor.position()).ok();
        window.set_size(PhysicalSize::new(monitor.size().width, monitor.size().height)).ok();
    }
    // The bar stays above the overlays, to change the mode or call it off.
    if let Some(bar) = app.get_webview_window("bar") {
        // Off and on again lifts it above the overlays made after it.
        bar.set_always_on_top(false).ok();
        bar.set_always_on_top(true).ok();
        bar.set_focus().ok();
    }
    Ok(())
}

pub fn close_pickers(app: &AppHandle) {
    for (label, window) in app.webview_windows() {
        if label.starts_with("picker-") {
            window.destroy().ok();
        }
    }
}

pub fn open_library(app: &AppHandle) -> Result<()> {
    if let Some(window) = app.get_webview_window("library") {
        window.unminimize().ok();
        window.show()?;
        window.set_focus()?;
        return Ok(());
    }
    WebviewWindowBuilder::new(app, "library", WebviewUrl::App("index.html".into()))
        .title("Recordings — Cue Studio")
        .inner_size(960.0, 640.0)
        .min_inner_size(640.0, 420.0)
        .center()
        .visible(false)
        .build()?;
    Ok(())
}

/// The editor for a recording; one window per recording.
pub fn open_editor(app: &AppHandle, path: &str) -> Result<()> {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    path.hash(&mut hasher);
    let label = format!("editor-{:x}", hasher.finish());
    if let Some(window) = app.get_webview_window(&label) {
        window.unminimize().ok();
        window.show()?;
        window.set_focus()?;
        return Ok(());
    }
    let name = std::path::Path::new(path).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let encoded: String = path.bytes().map(|b| if b.is_ascii_alphanumeric() { (b as char).to_string() } else { format!("%{b:02X}") }).collect();
    WebviewWindowBuilder::new(app, &label, WebviewUrl::App(format!("index.html#{encoded}").into()))
        .title(format!("{name} — Cue Studio"))
        .inner_size(1280.0, 820.0)
        .min_inner_size(900.0, 600.0)
        .center()
        .visible(false)
        .build()?;
    Ok(())
}
