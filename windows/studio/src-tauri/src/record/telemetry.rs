//! What the pointer and keyboard did during a take, for Studio to draw its own smoothed
//! pointer, click rings and zooms — the Mac's `CursorTracker`.
//!
//! - The pointer's place is sampled at 120 Hz, with the shape it had (each new shape is
//!   saved once, as a PNG in `telemetry/cursors/`).
//! - Clicks and keys come from low-level hooks, stamped with the event's own place and
//!   the moment the hook heard it.
//! - Keys are timed, never recorded: a key's identity is kept only for a shortcut (Ctrl
//!   or Win held) or a named key (Enter, Tab, arrows…), as on the Mac.
//!
//! Everything is on the take's clock, and lines reach the disk every half second.

use super::clock::{Clock, TICKS_PER_SECOND};
use anyhow::Result;
use serde::Serialize;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

/// The area being recorded, in desktop pixels, and its display's scale: telemetry is
/// written in points from the area's top left, as on the Mac (pixels = points × scale).
#[derive(Clone, Copy, Debug, Serialize)]
pub struct Area {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub scale: f64,
}

impl Area {
    fn point(&self, x: f64, y: f64) -> (f64, f64) {
        ((x - self.x as f64) / self.scale, (y - self.y as f64) / self.scale)
    }
}

/// One line of `cursor.jsonl`: `{"shape":"arrow","t":1.2345,"x":512.5,"y":300}`.
#[derive(Serialize, Clone)]
pub struct CursorSample {
    pub shape: &'static str,
    pub t: f64,
    pub x: f64,
    pub y: f64,
}

/// One line of `input.jsonl`, keyed by its kind as the Mac writes it:
/// `{"mouseDown":{"button":0,"t":…,"x":…,"y":…}}`.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub enum InputSample {
    MouseDown { button: u8, t: f64, x: f64, y: f64 },
    MouseUp { button: u8, t: f64, x: f64, y: f64 },
    Scroll { dx: f64, dy: f64, t: f64 },
    /// A key with no identity: only its time, and macOS's modifier bits (Shift only,
    /// for typing), so the Mac's editor reads it as typing.
    Key { modifiers: u64, t: f64 },
    /// A shortcut or a named key, by name: `{"key":"P","modifiers":["control","shift"]}`.
    Shortcut { key: String, modifiers: Vec<&'static str>, t: f64 },
}

impl InputSample {
    fn stamp(&mut self, time: f64, area: &Area) {
        match self {
            Self::MouseDown { t, x, y, .. } | Self::MouseUp { t, x, y, .. } => {
                *t = time;
                (*x, *y) = area.point(*x, *y);
            }
            Self::Scroll { t, .. } | Self::Key { t, .. } | Self::Shortcut { t, .. } => *t = time,
        }
    }
}

/// `cursors.json`: each shape's picture, its size in points and its hotspot as a
/// fraction of it.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CursorArtwork {
    pub width: f64,
    pub height: f64,
    pub hotspot_x: f64,
    pub hotspot_y: f64,
    pub path: String,
}

pub struct Telemetry {
    stop: Arc<AtomicBool>,
    threads: Vec<JoinHandle<()>>,
    artwork: Arc<Mutex<HashMap<&'static str, CursorArtwork>>>,
    folder: PathBuf,
    latency: f64,
}

struct Writer {
    file: BufWriter<File>,
}

impl Writer {
    fn create(path: &Path) -> Result<Self> {
        Ok(Self { file: BufWriter::new(File::create(path)?) })
    }

    fn line<T: Serialize>(&mut self, value: &T) {
        if let Ok(text) = serde_json::to_string(value) {
            self.file.write_all(text.as_bytes()).ok();
            self.file.write_all(b"\n").ok();
        }
    }
}

fn seconds(ticks: i64) -> f64 {
    ticks as f64 / TICKS_PER_SECOND as f64
}

impl Telemetry {
    pub fn start(folder: PathBuf, area: Area, clock: Arc<Clock>) -> Result<Self> {
        std::fs::create_dir_all(folder.join("cursors"))?;
        let stop = Arc::new(AtomicBool::new(false));
        let mut threads = Vec::new();

        // The pointer, 120 times a second.
        let cursor = Arc::new(Mutex::new(Writer::create(&folder.join("cursor.jsonl"))?));
        let artwork: Arc<Mutex<HashMap<&'static str, CursorArtwork>>> = Arc::default();
        // The screen shows the pointer one refresh after Windows knows where it is.
        let latency = platform::refresh_latency();
        {
            let (stop, clock, cursor, folder, artwork) = (stop.clone(), clock.clone(), cursor.clone(), folder.clone(), artwork.clone());
            threads.push(std::thread::spawn(move || {
                let mut seen: HashMap<isize, &'static str> = HashMap::new();
                let mut last_flush = std::time::Instant::now();
                while !stop.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_micros(8_333));
                    let now = Clock::now();
                    let Some(t) = clock.take_time(now) else { continue };
                    let Some((x, y, handle, visible)) = platform::pointer() else { continue };
                    if !visible {
                        continue;
                    }
                    let shape = *seen.entry(handle).or_insert_with(|| platform::shape_of(handle));
                    // Each shape's picture once, at its full size.
                    if handle != 0 && !artwork.lock().unwrap().contains_key(shape) {
                        if let Some(art) = platform::save_cursor(handle, &folder.join("cursors"), shape, area.scale) {
                            artwork.lock().unwrap().insert(shape, art);
                        }
                    }
                    let (px, py) = area.point(x as f64, y as f64);
                    let sample = CursorSample { shape, t: seconds(t) + latency, x: px, y: py };
                    let mut writer = cursor.lock().unwrap();
                    writer.line(&sample);
                    if last_flush.elapsed() > Duration::from_millis(500) {
                        writer.file.flush().ok();
                        last_flush = std::time::Instant::now();
                    }
                }
                cursor.lock().unwrap().file.flush().ok();
            }));
        }

        // Clicks, scrolls and keys, from the hooks, written by one thread.
        let (sender, receiver) = mpsc::channel::<(i64, InputSample)>();
        let mut input = Writer::create(&folder.join("input.jsonl"))?;
        {
            let (stop, clock) = (stop.clone(), clock.clone());
            threads.push(std::thread::spawn(move || {
                while !stop.load(Ordering::SeqCst) {
                    match receiver.recv_timeout(Duration::from_millis(500)) {
                        Ok((when, mut sample)) => {
                            let Some(t) = clock.take_time(when) else { continue };
                            sample.stamp(seconds(t) + latency, &area);
                            input.line(&sample);
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => {
                            input.file.flush().ok();
                        }
                        Err(_) => break,
                    }
                }
                input.file.flush().ok();
            }));
        }
        threads.push(platform::hooks(sender, stop.clone()));

        Ok(Self { stop, threads, artwork, folder, latency })
    }

    /// Stops, and writes `cursors.json`. Returns the latency the times were shifted by.
    pub fn finish(self) -> f64 {
        self.stop.store(true, Ordering::SeqCst);
        for thread in self.threads {
            thread.join().ok();
        }
        let artwork = self.artwork.lock().unwrap();
        std::fs::write(self.folder.join("cursors.json"), serde_json::to_vec_pretty(&*artwork).unwrap_or_default()).ok();
        self.latency
    }
}

#[cfg(windows)]
mod platform {
    use super::*;
    use std::cell::RefCell;
    use windows::Win32::Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM};
    use windows::Win32::Graphics::Gdi::{
        CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, EnumDisplaySettingsW, GetObjectW, SelectObject, BITMAP, BITMAPINFO,
        BITMAPINFOHEADER, BI_RGB, DEVMODEW, DIB_RGB_COLORS, ENUM_CURRENT_SETTINGS,
    };
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, VIRTUAL_KEY, VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT};
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, DrawIconEx, GetCursorInfo, GetIconInfo, GetMessageW, LoadCursorW, PostThreadMessageW, SetWindowsHookExW,
        UnhookWindowsHookEx, CURSORINFO, CURSOR_SHOWING, DI_NORMAL, HHOOK, HICON, ICONINFO, IDC_APPSTARTING, IDC_ARROW, IDC_CROSS,
        IDC_HAND, IDC_IBEAM, IDC_NO, IDC_SIZEALL, IDC_SIZENESW, IDC_SIZENS, IDC_SIZENWSE, IDC_SIZEWE, IDC_WAIT, KBDLLHOOKSTRUCT, MSG,
        MSLLHOOKSTRUCT, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_KEYDOWN, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP,
        WM_MOUSEHWHEEL, WM_MOUSEWHEEL, WM_QUIT, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SYSKEYDOWN,
    };
    use windows::core::PCWSTR;

    pub fn pointer() -> Option<(i32, i32, isize, bool)> {
        let mut info = CURSORINFO { cbSize: std::mem::size_of::<CURSORINFO>() as u32, ..Default::default() };
        unsafe { GetCursorInfo(&mut info).ok()? };
        let visible = info.flags.0 & CURSOR_SHOWING.0 != 0;
        Some((info.ptScreenPos.x, info.ptScreenPos.y, info.hCursor.0 as isize, visible))
    }

    /// The Mac's shape name for a Windows cursor: the system's standard cursors by
    /// their shared handles, anything an app drew itself as `other`.
    pub fn shape_of(handle: isize) -> &'static str {
        let standard: [(PCWSTR, &'static str); 12] = [
            (IDC_ARROW, "arrow"),
            (IDC_IBEAM, "iBeam"),
            (IDC_HAND, "pointingHand"),
            (IDC_CROSS, "crosshair"),
            (IDC_SIZEWE, "resizeLeftRight"),
            (IDC_SIZENS, "resizeUpDown"),
            (IDC_SIZENWSE, "resizeDiagonal"),
            (IDC_SIZENESW, "resizeDiagonal"),
            (IDC_SIZEALL, "openHand"),
            (IDC_NO, "operationNotAllowed"),
            (IDC_WAIT, "busy"),
            (IDC_APPSTARTING, "busy"),
        ];
        for (id, name) in standard {
            if let Ok(cursor) = unsafe { LoadCursorW(None, id) } {
                if cursor.0 as isize == handle {
                    return name;
                }
            }
        }
        "other"
    }

    /// One display refresh, clamped to 0…50 ms; 60 Hz when it can't be read (the Mac's
    /// `PointerLatency`).
    pub fn refresh_latency() -> f64 {
        let mut mode = DEVMODEW { dmSize: std::mem::size_of::<DEVMODEW>() as u16, ..Default::default() };
        let hz = if unsafe { EnumDisplaySettingsW(PCWSTR::null(), ENUM_CURRENT_SETTINGS, &mut mode) }.as_bool() {
            mode.dmDisplayFrequency as f64
        } else {
            60.0
        };
        let hz = if (24.0..=480.0).contains(&hz) { hz } else { 60.0 };
        (1.0 / hz).clamp(0.0, 0.05)
    }

    /// Draws a cursor into a 32-bit picture and saves it as `<name>.png`; returns its
    /// entry for `cursors.json`.
    pub fn save_cursor(handle: isize, folder: &Path, name: &str, scale: f64) -> Option<CursorArtwork> {
        unsafe {
            let icon = HICON(handle as *mut _);
            let mut info = ICONINFO::default();
            GetIconInfo(icon, &mut info).ok()?;
            let mut bitmap = BITMAP::default();
            let source = if !info.hbmColor.is_invalid() { info.hbmColor } else { info.hbmMask };
            GetObjectW(source.into(), std::mem::size_of::<BITMAP>() as i32, Some(&mut bitmap as *mut _ as *mut _));
            let width = bitmap.bmWidth.max(1);
            // A mask-only cursor stacks its AND and XOR masks: half the height is the shape.
            let height = if info.hbmColor.is_invalid() { bitmap.bmHeight / 2 } else { bitmap.bmHeight }.max(1);
            let draw = |background: u8| -> Option<Vec<u8>> {
                let dc = CreateCompatibleDC(None);
                let header = BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: width,
                    biHeight: -height,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                };
                let bmi = BITMAPINFO { bmiHeader: header, ..Default::default() };
                let mut bits: *mut std::ffi::c_void = std::ptr::null_mut();
                let dib = CreateDIBSection(Some(dc), &bmi, DIB_RGB_COLORS, &mut bits, None, 0).ok()?;
                let old = SelectObject(dc, dib.into());
                let len = (width * height * 4) as usize;
                std::ptr::write_bytes(bits as *mut u8, background, len);
                DrawIconEx(dc, 0, 0, icon, width, height, 0, None, DI_NORMAL).ok();
                let pixels = std::slice::from_raw_parts(bits as *const u8, len).to_vec();
                SelectObject(dc, old);
                let _ = DeleteObject(dib.into());
                let _ = DeleteDC(dc);
                Some(pixels)
            };
            // Drawn on black and on white: where they differ is the shape's transparency.
            let pictures = (draw(0), draw(255));
            if !info.hbmColor.is_invalid() {
                let _ = DeleteObject(info.hbmColor.into());
            }
            let _ = DeleteObject(info.hbmMask.into());
            let (Some(on_black), Some(on_white)) = pictures else { return None };
            let mut rgba = Vec::with_capacity(on_black.len());
            for (b, w) in on_black.chunks_exact(4).zip(on_white.chunks_exact(4)) {
                let alpha = 255 - (w[1] as i32 - b[1] as i32).clamp(0, 255) as u8;
                let un = |c: u8| if alpha == 0 { 0 } else { ((c as u32 * 255) / alpha as u32).min(255) as u8 };
                rgba.extend_from_slice(&[un(b[2]), un(b[1]), un(b[0]), alpha]);
            }
            let image = image::RgbaImage::from_raw(width as u32, height as u32, rgba)?;
            image.save(folder.join(format!("{name}.png"))).ok()?;
            Some(CursorArtwork {
                width: width as f64 / scale,
                height: height as f64 / scale,
                hotspot_x: info.xHotspot as f64 / width as f64,
                hotspot_y: info.yHotspot as f64 / height as f64,
                path: format!("telemetry/cursors/{name}.png"),
            })
        }
    }

    thread_local! {
        static SENDER: RefCell<Option<mpsc::Sender<(i64, InputSample)>>> = const { RefCell::new(None) };
    }

    fn send(sample: InputSample) {
        let now = Clock::now();
        SENDER.with(|s| {
            if let Some(sender) = s.borrow().as_ref() {
                sender.send((now, sample)).ok();
            }
        });
    }

    unsafe extern "system" fn mouse(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code >= 0 {
            let event = unsafe { &*(lparam.0 as *const MSLLHOOKSTRUCT) };
            let (x, y) = (event.pt.x as f64, event.pt.y as f64);
            let wheel = ((event.mouseData >> 16) as i16) as f64 / 120.0;
            let sample = match wparam.0 as u32 {
                WM_LBUTTONDOWN => Some(InputSample::MouseDown { button: 0, t: 0.0, x, y }),
                WM_LBUTTONUP => Some(InputSample::MouseUp { button: 0, t: 0.0, x, y }),
                WM_RBUTTONDOWN => Some(InputSample::MouseDown { button: 1, t: 0.0, x, y }),
                WM_RBUTTONUP => Some(InputSample::MouseUp { button: 1, t: 0.0, x, y }),
                WM_MBUTTONDOWN => Some(InputSample::MouseDown { button: 2, t: 0.0, x, y }),
                WM_MBUTTONUP => Some(InputSample::MouseUp { button: 2, t: 0.0, x, y }),
                WM_MOUSEWHEEL => Some(InputSample::Scroll { dx: 0.0, dy: wheel, t: 0.0 }),
                WM_MOUSEHWHEEL => Some(InputSample::Scroll { dx: wheel, dy: 0.0, t: 0.0 }),
                _ => None,
            };
            if let Some(sample) = sample {
                send(sample);
            }
        }
        unsafe { CallNextHookEx(None, code, wparam, lparam) }
    }

    fn held(key: VIRTUAL_KEY) -> bool {
        unsafe { (GetKeyState(key.0 as i32) as u16 & 0x8000) != 0 }
    }

    /// The keys written by name even with nothing held — the Mac's `NamedKey`.
    fn named(vk: u32) -> Option<String> {
        Some(
            match vk {
                0x0D => "Return",
                0x09 => "Tab",
                0x1B => "Escape",
                0x08 => "Delete",
                0x2E => "Forward Delete",
                0x25 => "Left",
                0x26 => "Up",
                0x27 => "Right",
                0x28 => "Down",
                0x21 => "Page Up",
                0x22 => "Page Down",
                0x24 => "Home",
                0x23 => "End",
                0x70..=0x83 => return Some(format!("F{}", vk - 0x6F)),
                _ => return None,
            }
            .to_string(),
        )
    }

    fn key_name(vk: u32) -> String {
        match vk {
            0x30..=0x39 | 0x41..=0x5A => char::from_u32(vk).map(String::from).unwrap_or_default(),
            0x20 => "Space".into(),
            0xBA => ";".into(),
            0xBB => "=".into(),
            0xBC => ",".into(),
            0xBD => "-".into(),
            0xBE => ".".into(),
            0xBF => "/".into(),
            0xC0 => "`".into(),
            0xDB => "[".into(),
            0xDC => "\\".into(),
            0xDD => "]".into(),
            0xDE => "'".into(),
            _ => named(vk).unwrap_or_else(|| format!("Key {vk}")),
        }
    }

    unsafe extern "system" fn keyboard(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code >= 0 && matches!(wparam.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN) {
            let event = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
            let vk = event.vkCode;
            // Modifiers alone are not keys.
            if !matches!(vk, 0x10 | 0x11 | 0x12 | 0xA0..=0xA5 | 0x5B | 0x5C) {
                let (ctrl, win, alt, shift) = (held(VK_CONTROL), held(VK_LWIN) || held(VK_RWIN), held(VK_MENU), held(VK_SHIFT));
                // On disk in the Mac's order and names: Ctrl is control, Alt option, Win command.
                let modifiers: Vec<&'static str> =
                    [(ctrl, "control"), (alt, "option"), (shift, "shift"), (win, "command")].into_iter().filter(|(on, _)| *on).map(|(_, n)| n).collect();
                // Ctrl or Win makes a shortcut (Alt alone types characters on many layouts);
                // a named key is written by name; anything else is typing, with no identity.
                let sample = if ctrl || win {
                    InputSample::Shortcut { key: key_name(vk), modifiers, t: 0.0 }
                } else if let Some(name) = named(vk) {
                    InputSample::Shortcut { key: name, modifiers, t: 0.0 }
                } else {
                    // macOS's Shift bit, so the Mac's editor reads it as typing too.
                    InputSample::Key { modifiers: if shift { 1 << 17 } else { 0 }, t: 0.0 }
                };
                send(sample);
            }
        }
        unsafe { CallNextHookEx(None, code, wparam, lparam) }
    }

    /// Low-level hooks run on a thread with a message loop until the take ends.
    pub fn hooks(sender: mpsc::Sender<(i64, InputSample)>, stop: Arc<AtomicBool>) -> JoinHandle<()> {
        let (ready_tx, ready_rx) = mpsc::channel::<u32>();
        let thread = std::thread::spawn(move || unsafe {
            SENDER.with(|s| *s.borrow_mut() = Some(sender));
            let module = HINSTANCE::default();
            let mouse_hook: Option<HHOOK> = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse), Some(module), 0).ok();
            let key_hook: Option<HHOOK> = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard), Some(module), 0).ok();
            ready_tx.send(windows::Win32::System::Threading::GetCurrentThreadId()).ok();
            let mut message = MSG::default();
            while GetMessageW(&mut message, None, 0, 0).as_bool() {}
            if let Some(h) = mouse_hook {
                UnhookWindowsHookEx(h).ok();
            }
            if let Some(h) = key_hook {
                UnhookWindowsHookEx(h).ok();
            }
        });
        let thread_id = ready_rx.recv().unwrap_or(0);
        // Ends the message loop once the take stops.
        std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(100));
            }
            unsafe { PostThreadMessageW(thread_id, WM_QUIT, WPARAM(0), LPARAM(0)).ok() };
        });
        thread
    }
}

#[cfg(not(windows))]
mod platform {
    use super::*;

    pub fn pointer() -> Option<(i32, i32, isize, bool)> {
        None
    }

    pub fn shape_of(_: isize) -> &'static str {
        "arrow"
    }

    pub fn refresh_latency() -> f64 {
        1.0 / 60.0
    }

    pub fn save_cursor(_: isize, _: &Path, _: &str, _: f64) -> Option<CursorArtwork> {
        None
    }

    pub fn hooks(_: mpsc::Sender<(i64, InputSample)>, _: Arc<AtomicBool>) -> JoinHandle<()> {
        std::thread::spawn(|| {})
    }
}
