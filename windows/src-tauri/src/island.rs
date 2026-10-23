//! The Island: Cue's Dynamic Island, on Windows.
//!
//! A Windows display has no notch, so the island is a pill hanging from the top centre
//! of each display, as on the Mac's plain displays. Like the Mac's, its window never
//! resizes: it is made as large as the open panel plus room for its shadow, and only the
//! shape drawn inside it animates.
//!
//! Closed, the window lets every click through — it must never block the title bar of a
//! maximised window underneath — so the web view cannot see the pointer coming. A thread
//! here watches the pointer instead and tells the island when it is near; the island
//! then takes the mouse while it is open and gives it back as it closes.

use crate::library::CaptureItem;
use crate::state::AppState;
use serde::Serialize;
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};

/// The closed pill, in points: the Mac's plain-display pill.
pub const PILL_WIDTH: f64 = 140.0;
pub const STRIP_HEIGHT: f64 = 22.0;
/// The open panel at its largest (the Mac's `IslandPanel.size`), and what goes around it.
const PANEL_WIDTH: f64 = 780.0;
const PANEL_HEIGHT: f64 = 330.0;
const PANEL_PADDING: f64 = 8.0;
const OPEN_FLARE: f64 = 40.0;
const SHADOW_MARGIN: f64 = 44.0;

/// The window, in points.
pub const WINDOW_WIDTH: f64 = PANEL_WIDTH + PANEL_PADDING + OPEN_FLARE * 2.0 + SHADOW_MARGIN * 2.0;
pub const WINDOW_HEIGHT: f64 = STRIP_HEIGHT + PANEL_HEIGHT + PANEL_PADDING + SHADOW_MARGIN;

/// One island: its window and where it is, in physical pixels.
#[derive(Clone)]
struct Placed {
    label: String,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    scale: f64,
    /// Taking the mouse (open), rather than letting it through (closed).
    interactive: bool,
    /// Whether the pointer was over its window at the last look.
    near: bool,
}

#[derive(Default)]
pub struct Islands {
    placed: Mutex<Vec<Placed>>,
    /// The displays the islands were made for, to notice one being plugged in.
    signature: Mutex<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Pointer {
    /// In points, from the window's top left.
    x: f64,
    y: f64,
    in_window: bool,
    /// The left button is held: something may be being dragged onto the island.
    button: bool,
}

fn left_button_down() -> bool {
    #[cfg(windows)]
    unsafe {
        use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
        return (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000) != 0;
    }
    #[cfg(not(windows))]
    false
}

/// A moment's confirmation on the island — the Mac's `IslandStatus`.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// An SF Symbol name, as on the Mac; the island maps it to its icon.
    pub symbol: String,
    pub title: String,
    pub subtitle: Option<String>,
    /// A capture to show beside it.
    pub image: Option<String>,
    /// How long it stays, in seconds.
    pub duration: f64,
}

fn monitors_signature(app: &AppHandle) -> String {
    app.available_monitors()
        .unwrap_or_default()
        .iter()
        .map(|m| format!("{:?}{:?}{}", m.position(), m.size(), m.scale_factor()))
        .collect::<Vec<_>>()
        .join("|")
}

/// A display's name for Settings to remember: Windows' device name (`\\.\DISPLAY2`),
/// or its place in the list where there is none.
pub fn display_id(monitor: &tauri::Monitor, index: usize) -> String {
    monitor.name().cloned().unwrap_or_else(|| format!("display-{}", index + 1))
}

/// Makes the islands Settings asks for, replacing any there were.
pub fn rebuild(app: &AppHandle) {
    let islands = app.state::<Islands>();
    for placed in islands.placed.lock().unwrap().drain(..) {
        if let Some(window) = app.get_webview_window(&placed.label) {
            window.destroy().ok();
        }
    }
    *islands.signature.lock().unwrap() = monitors_signature(app);
    let settings = app.state::<AppState>().settings().island;
    if !settings.enabled {
        return;
    }
    let primary = app.primary_monitor().ok().flatten();
    let monitors = app.available_monitors().unwrap_or_default();
    // A chosen display that isn't plugged in now leaves the island on the main one.
    let chosen = monitors.iter().enumerate().any(|(i, m)| display_id(m, i) == settings.display);
    let mut placed = Vec::new();
    for (index, monitor) in monitors.iter().enumerate() {
        let is_primary = primary.as_ref().is_some_and(|p| p.position() == monitor.position()) || (primary.is_none() && index == 0);
        let wanted = match settings.display.as_str() {
            "all" => true,
            id if chosen => display_id(monitor, index) == id,
            _ => is_primary,
        };
        if !wanted && monitors.len() > 1 {
            continue;
        }
        let scale = monitor.scale_factor();
        let width = (WINDOW_WIDTH * scale).round() as u32;
        let height = (WINDOW_HEIGHT * scale).round() as u32;
        let x = monitor.position().x + (monitor.size().width as i32 - width as i32) / 2;
        let y = monitor.position().y;
        let label = format!("island-{index}");
        let built = WebviewWindowBuilder::new(app, &label, WebviewUrl::App("index.html".into()))
            .title("Cue Island")
            .decorations(false)
            .transparent(true)
            .shadow(false)
            .resizable(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .focused(false)
            // Never taking the keyboard is a Windows behaviour here (WS_EX_NOACTIVATE); on
            // the Mac, where this is only ever run to test, it would keep it off screen.
            .focusable(!cfg!(windows))
            .visible(false)
            .build();
        let Ok(window) = built else { continue };
        window.set_position(PhysicalPosition::new(x, y)).ok();
        window.set_size(PhysicalSize::new(width, height)).ok();
        if cfg!(windows) || std::env::var_os("CUE_ISLAND_CLICK_THROUGH").is_some() {
            window.set_ignore_cursor_events(true).ok();
        }
        placed.push(Placed { label, x, y, width, height, scale, interactive: false, near: false });
    }
    *islands.placed.lock().unwrap() = placed;
}

/// The island's page has drawn: put it on screen without taking the keyboard.
pub fn ready(app: &AppHandle, label: &str) {
    if let Some(window) = app.get_webview_window(label) {
        window.show().ok();
        // macOS only orders a window of an inactive app on screen once it is focused;
        // Windows needs no such nudge, and must not have the keyboard taken.
        if !cfg!(windows) {
            window.set_focus().ok();
        }
    }
}

/// Open islands take the mouse; closed ones let it through.
pub fn set_interactive(app: &AppHandle, label: &str, interactive: bool) {
    let islands = app.state::<Islands>();
    if let Some(placed) = islands.placed.lock().unwrap().iter_mut().find(|p| p.label == label) {
        placed.interactive = interactive;
    }
    if let Some(window) = app.get_webview_window(label) {
        window.set_ignore_cursor_events(!interactive).ok();
        if !interactive {
            // Typing in the search field made it focusable; closed, it goes back to
            // never taking the keyboard from the app underneath.
            window.set_focusable(false).ok();
        }
    }
}

/// The search field was clicked: the island takes the keyboard.
pub fn take_keyboard(app: &AppHandle, label: &str) {
    if let Some(window) = app.get_webview_window(label) {
        crate::paste::remember_front();
        window.set_focusable(true).ok();
        window.set_focus().ok();
    }
}

/// Watches the pointer for the islands, and the displays for changes, until the app ends.
pub fn watch(app: AppHandle) {
    std::thread::spawn(move || {
        let mut ticks: u64 = 0;
        loop {
            std::thread::sleep(Duration::from_millis(33));
            ticks += 1;
            if ticks % 60 == 0 {
                let changed = *app.state::<Islands>().signature.lock().unwrap() != monitors_signature(&app);
                if changed {
                    let handle = app.clone();
                    app.run_on_main_thread(move || rebuild(&handle)).ok();
                    continue;
                }
            }
            let Ok(cursor) = app.cursor_position() else { continue };
            let islands = app.state::<Islands>();
            let mut placed = islands.placed.lock().unwrap();
            for island in placed.iter_mut() {
                let inside = cursor.x >= island.x as f64
                    && cursor.x < (island.x + island.width as i32) as f64
                    && cursor.y >= island.y as f64
                    && cursor.y < (island.y + island.height as i32) as f64;
                // Only near the island, or the moment it leaves: nothing is sent while the
                // pointer is elsewhere.
                if inside || island.near || island.interactive {
                    let pointer = Pointer {
                        x: (cursor.x - island.x as f64) / island.scale,
                        y: (cursor.y - island.y as f64) / island.scale,
                        in_window: inside,
                        button: left_button_down(),
                    };
                    app.emit_to(&island.label, "island:pointer", pointer).ok();
                }
                island.near = inside;
            }
        }
    });
}

/// The island on the display the pointer is on, else the first.
fn active_label(app: &AppHandle) -> Option<String> {
    let islands = app.state::<Islands>();
    let placed = islands.placed.lock().unwrap();
    let cursor = app.cursor_position().ok();
    placed
        .iter()
        .find(|p| {
            // Islands span their display's width only in part; the display is what counts,
            // so compare against the column the island is centred in.
            cursor.is_some_and(|c| {
                let centre = p.x as f64 + p.width as f64 / 2.0;
                (c.x - centre).abs() < 4000.0 && c.y >= p.y as f64 && app.monitor_from_point(c.x, c.y).ok().flatten().is_some_and(|m| {
                    let left = m.position().x as f64;
                    centre >= left && centre < left + m.size().width as f64
                })
            })
        })
        .or_else(|| placed.first())
        .map(|p| p.label.clone())
}

/// Flashes a new capture on the island, if Settings says to. Returns whether it did.
pub fn flash(app: &AppHandle, item: &CaptureItem, url: String, copied: bool) -> bool {
    let settings = app.state::<AppState>().settings().island;
    if !settings.enabled || !settings.flash_captures {
        return false;
    }
    let Some(label) = active_label(app) else { return false };
    #[derive(Clone, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Flash {
        url: String,
        width: u32,
        height: u32,
        copied: bool,
        duration: f64,
    }
    app.emit_to(
        &label,
        "island:flash",
        Flash { url, width: item.pixel_width, height: item.pixel_height, copied, duration: settings.flash_duration },
    )
    .is_ok()
}

/// Shows a status on the island, or as a Windows notification when the island is off.
pub fn status(app: &AppHandle, symbol: &str, title: &str, subtitle: Option<&str>) {
    let settings = app.state::<AppState>().settings().island;
    if settings.enabled && settings.statuses {
        if let Some(label) = active_label(app) {
            let status = Status {
                symbol: symbol.into(),
                title: title.into(),
                subtitle: subtitle.map(String::from),
                image: None,
                duration: 1.8,
            };
            if app.emit_to(&label, "island:status", status).is_ok() {
                return;
            }
        }
    }
    crate::notify::send(app, title, subtitle.unwrap_or(""));
}

/// Debug builds only: the island in an ordinary window, in a phase given on the command
/// line (`--island-demo expanded|flash|status|collapsed`), to look at without the pointer.
#[cfg(debug_assertions)]
pub fn demo(app: &AppHandle, phase: &str) {
    let label = "island-demo";
    if app.get_webview_window(label).is_none() {
        let built = WebviewWindowBuilder::new(app, label, WebviewUrl::App("index.html".into()))
            .title("Cue Island Demo")
            .inner_size(WINDOW_WIDTH, WINDOW_HEIGHT)
            .resizable(false)
            .visible(true)
            .build();
        if built.is_err() {
            return;
        }
    }
    let app = app.clone();
    let phase = phase.to_string();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(1500));
        app.emit_to("island-demo", "island:demo", phase).ok();
    });
}
