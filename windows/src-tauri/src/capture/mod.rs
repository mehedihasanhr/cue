//! Taking a capture.
//!
//! Like the Mac app, the screen is frozen first: every display is grabbed the moment the
//! shortcut is pressed, and the selection is made over those pictures, one borderless
//! window per display. What is chosen is then cut out of the picture already taken, so
//! the capture is exactly what was on screen when the user asked — not what a menu or
//! tooltip changed it to while they were dragging.

pub mod geometry;
mod grab;

use crate::state::AppState;
use anyhow::{Context, Result};
use geometry::Rect;
use image::RgbaImage;
use serde::Serialize;
use std::sync::Arc;
use tauri::{AppHandle, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Area,
    Window,
    FullScreen,
    Text,
}

/// One display, as it looked when the shortcut was pressed.
pub struct Frame {
    /// The display's place on the desktop, in physical pixels.
    pub bounds: Rect,
    pub scale: f64,
    pub image: RgbaImage,
    /// The picture as PNG, for the overlay to draw.
    pub png: Arc<Vec<u8>>,
}

/// A window the selection can snap to, in physical desktop pixels.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowInfo {
    pub rect: Rect,
    pub title: String,
    pub app: String,
}

pub struct Session {
    pub id: String,
    pub mode: Mode,
    pub frames: Vec<Frame>,
    /// Front to back.
    pub windows: Vec<WindowInfo>,
}

/// What an overlay needs to draw its display.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OverlayInfo {
    pub mode: Mode,
    pub image_url: String,
    /// The display, in physical pixels.
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    /// Windows on this display, relative to its top left, front to back.
    pub windows: Vec<WindowInfo>,
    /// Where the pointer is, relative to this display, if it is on it.
    pub pointer: Option<(i32, i32)>,
}

fn overlay_label(index: usize) -> String {
    format!("overlay-{index}")
}

/// Starts a capture in `mode`. Full screen is taken at once; the others freeze the
/// screens and put up the overlays.
pub fn start(app: &AppHandle, mode: Mode) -> Result<()> {
    let state = app.state::<AppState>();
    if state.session.lock().unwrap().is_some() {
        // A second press while choosing does nothing, rather than stacking overlays.
        return Ok(());
    }

    if mode == Mode::FullScreen {
        let pointer = app.cursor_position().ok().map(|p| (p.x as i32, p.y as i32)).unwrap_or((0, 0));
        let (image, scale) = grab::display_at(pointer)?;
        return crate::finish::deliver(app, image, scale, mode);
    }

    let frames = grab::all_displays()?;
    let windows = if matches!(mode, Mode::Area | Mode::Window) { grab::windows() } else { Vec::new() };
    let session = Session { id: uuid::Uuid::new_v4().simple().to_string(), mode, frames, windows };
    let bounds: Vec<Rect> = session.frames.iter().map(|frame| frame.bounds).collect();
    *state.session.lock().unwrap() = Some(session);

    for (index, rect) in bounds.into_iter().enumerate() {
        let label = overlay_label(index);
        let window = WebviewWindowBuilder::new(app, &label, WebviewUrl::App("index.html".into()))
            .title("Klik")
            .decorations(false)
            .resizable(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .shadow(false)
            .visible(false)
            .background_color(tauri::window::Color(0, 0, 0, 255))
            .build()
            .context("Could not open the capture overlay")?;
        window.set_position(PhysicalPosition::new(rect.x, rect.y))?;
        window.set_size(PhysicalSize::new(rect.width, rect.height))?;
    }
    Ok(())
}

pub fn overlay_info(app: &AppHandle, index: usize) -> Result<OverlayInfo> {
    let state = app.state::<AppState>();
    let session = state.session.lock().unwrap();
    let session = session.as_ref().context("No capture under way")?;
    let frame = session.frames.get(index).context("No such display")?;
    let windows = session
        .windows
        .iter()
        .filter_map(|window| {
            let visible = window.rect.intersection(&frame.bounds)?;
            Some(WindowInfo { rect: visible.offset(-frame.bounds.x, -frame.bounds.y), ..window.clone() })
        })
        .collect();
    let pointer = app
        .cursor_position()
        .ok()
        .map(|p| (p.x as i32, p.y as i32))
        .filter(|&(x, y)| frame.bounds.contains(x, y))
        .map(|(x, y)| (x - frame.bounds.x, y - frame.bounds.y));
    Ok(OverlayInfo {
        mode: session.mode,
        image_url: crate::protocol::url(&format!("frame/{}/{index}.png", session.id)),
        width: frame.bounds.width,
        height: frame.bounds.height,
        scale: frame.scale,
        windows,
        pointer,
    })
}

/// The overlay has drawn its picture: show it, and give the one under the pointer the
/// keyboard so Esc and Return work straight away.
pub fn overlay_ready(app: &AppHandle, index: usize, focus: bool) -> Result<()> {
    if let Some(window) = app.get_webview_window(&overlay_label(index)) {
        window.show()?;
        if focus {
            window.set_focus()?;
        }
    }
    Ok(())
}

/// The user chose `rect` (physical pixels, relative to display `index`).
pub fn finish(app: &AppHandle, index: usize, rect: Rect) -> Result<()> {
    let state = app.state::<AppState>();
    let (image, scale, mode) = {
        let mut session = state.session.lock().unwrap();
        let current = session.as_ref().context("No capture under way")?;
        let frame = current.frames.get(index).context("No such display")?;
        let area = rect
            .intersection(&Rect::new(0, 0, frame.bounds.width, frame.bounds.height))
            .context("The selection is off the screen")?;
        let image = image::imageops::crop_imm(&frame.image, area.x as u32, area.y as u32, area.width, area.height)
            .to_image();
        let result = (image, frame.scale, current.mode);
        *session = None;
        result
    };
    close_overlays(app);
    crate::finish::deliver(app, image, scale, mode)
}

pub fn cancel(app: &AppHandle) {
    *app.state::<AppState>().session.lock().unwrap() = None;
    close_overlays(app);
}

fn close_overlays(app: &AppHandle) {
    for (label, window) in app.webview_windows() {
        if label.starts_with("overlay-") {
            window.destroy().ok();
        }
    }
}

/// The frozen picture of display `index`, for the `klik://` protocol.
pub fn frame_png(app: &AppHandle, session_id: &str, index: usize) -> Option<Arc<Vec<u8>>> {
    let state = app.state::<AppState>();
    let session = state.session.lock().unwrap();
    let session = session.as_ref().filter(|s| s.id == session_id)?;
    session.frames.get(index).map(|frame| frame.png.clone())
}
