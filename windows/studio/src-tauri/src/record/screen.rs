//! The picture: Windows.Graphics.Capture into an H.264 MP4 through Media Foundation
//! (`media/screen.mp4`), without the pointer — Studio draws its own, smoothed, from the
//! telemetry, as the Mac's does.
//!
//! Windows only sends a frame when something changes, so the file is variable-rate and a
//! still screen costs nothing. The first frame's timestamp starts the take's clock; a
//! pause sends nothing and, on resume, moves the video's start on by the pause.

use super::clock::Clock;
use anyhow::Result;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI64};
#[cfg(windows)]
use std::sync::atomic::Ordering;
use std::sync::Arc;

/// What to record.
#[derive(Clone, Debug, serde::Deserialize, serde::Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Target {
    /// A display by its index in `displays()`.
    Display { index: usize },
    /// A window by its handle.
    Window { hwnd: i64 },
}

/// Shared with the session: pausing, and the length of a pause just ended.
#[derive(Default)]
pub struct Control {
    pub paused: AtomicBool,
    /// Ticks to skip at the next frame — set on resume.
    pub skip: AtomicI64,
    /// Set by the capture once the file is finished.
    pub finished: AtomicBool,
    /// The picture's size, once known.
    pub width: AtomicI64,
    pub height: AtomicI64,
}

pub struct ScreenSettings {
    pub target: Target,
    pub path: PathBuf,
    pub width: u32,
    pub height: u32,
    pub frame_rate: u32,
    pub bitrate: u32,
}

#[cfg(windows)]
mod imp {
    use super::*;
    use std::time::Duration;
    use windows_capture::capture::{Context, GraphicsCaptureApiHandler};
    use windows_capture::encoder::{AudioSettingsBuilder, ContainerSettingsBuilder, VideoEncoder, VideoSettingsBuilder};
    use windows_capture::frame::Frame;
    use windows_capture::graphics_capture_api::InternalCaptureControl;
    use windows_capture::monitor::Monitor;
    use windows_capture::settings::{
        ColorFormat, CursorCaptureSettings, DirtyRegionSettings, DrawBorderSettings, MinimumUpdateIntervalSettings,
        SecondaryWindowSettings, Settings,
    };
    use windows_capture::window::Window;

    pub struct Flags {
        pub settings: ScreenSettings,
        pub clock: Arc<Clock>,
        pub control: Arc<Control>,
    }

    pub struct Capture {
        encoder: Option<VideoEncoder>,
        clock: Arc<Clock>,
        control: Arc<Control>,
    }

    impl GraphicsCaptureApiHandler for Capture {
        type Flags = Flags;
        type Error = Box<dyn std::error::Error + Send + Sync>;

        fn new(ctx: Context<Self::Flags>) -> Result<Self, Self::Error> {
            let s = &ctx.flags.settings;
            let video = VideoSettingsBuilder::new(s.width, s.height).bitrate(s.bitrate).frame_rate(s.frame_rate);
            let encoder = VideoEncoder::new(video, AudioSettingsBuilder::default().disabled(true), ContainerSettingsBuilder::default(), &s.path)?;
            ctx.flags.control.width.store(s.width as i64, Ordering::SeqCst);
            ctx.flags.control.height.store(s.height as i64, Ordering::SeqCst);
            Ok(Self { encoder: Some(encoder), clock: ctx.flags.clock.clone(), control: ctx.flags.control.clone() })
        }

        fn on_frame_arrived(&mut self, frame: &mut Frame, _capture: InternalCaptureControl) -> Result<(), Self::Error> {
            if self.control.paused.load(Ordering::SeqCst) {
                return Ok(());
            }
            let Some(encoder) = self.encoder.as_mut() else { return Ok(()) };
            // The first frame's own time starts the take.
            self.clock.start_at(frame.timestamp()?.Duration);
            let skip = self.control.skip.swap(0, Ordering::SeqCst);
            if skip > 0 {
                encoder.skip_paused(skip);
            }
            encoder.send_frame(frame)?;
            Ok(())
        }

        fn on_closed(&mut self) -> Result<(), Self::Error> {
            // The window went away: finish what there is.
            if let Some(encoder) = self.encoder.take() {
                encoder.finish()?;
            }
            self.control.finished.store(true, Ordering::SeqCst);
            Ok(())
        }
    }

    impl Drop for Capture {
        fn drop(&mut self) {
            // Stopping ends the capture's thread and drops this: the file is finished here.
            if let Some(encoder) = self.encoder.take() {
                encoder.finish().ok();
            }
            self.control.finished.store(true, Ordering::SeqCst);
        }
    }

    pub fn start(settings: ScreenSettings, clock: Arc<Clock>, control: Arc<Control>) -> Result<Box<dyn FnOnce() + Send>> {
        let interval = MinimumUpdateIntervalSettings::Custom(Duration::from_micros(1_000_000 / settings.frame_rate.max(1) as u64));
        let flags = Flags { settings, clock, control };
        macro_rules! go {
            ($item:expr) => {
                Capture::start_free_threaded(Settings::new(
                    $item,
                    CursorCaptureSettings::WithoutCursor,
                    DrawBorderSettings::WithoutBorder,
                    SecondaryWindowSettings::Default,
                    interval,
                    DirtyRegionSettings::Default,
                    ColorFormat::Bgra8,
                    flags,
                ))
                .map(|capture| Box::new(move || {
                    capture.stop().ok();
                }) as Box<dyn FnOnce() + Send>)
                .map_err(|e| anyhow::anyhow!("Could not start recording the screen: {e}"))
            };
        }
        match flags.settings.target.clone() {
            Target::Display { index } => {
                let monitor = Monitor::enumerate()?.into_iter().nth(index).ok_or_else(|| anyhow::anyhow!("That display is gone"))?;
                go!(monitor)
            }
            Target::Window { hwnd } => go!(Window::from_raw_hwnd(hwnd as *mut std::ffi::c_void)),
        }
    }
}

/// Starts recording on its own thread; returns what stops it and finishes the file.
pub fn start(settings: ScreenSettings, clock: Arc<Clock>, control: Arc<Control>) -> Result<Box<dyn FnOnce() + Send>> {
    #[cfg(windows)]
    {
        imp::start(settings, clock, control)
    }
    #[cfg(not(windows))]
    {
        let _ = (settings, clock, control);
        anyhow::bail!("Recording the screen needs Windows")
    }
}

/// What can be recorded, for the target picker.
#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayInfo {
    pub index: usize,
    pub name: String,
    /// Physical pixels and position on the desktop.
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    pub primary: bool,
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowInfo {
    pub hwnd: i64,
    pub title: String,
    pub app: String,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

#[cfg(windows)]
pub fn windows_list() -> Vec<WindowInfo> {
    use windows_capture::window::Window;
    Window::enumerate()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|w| {
            let title = w.title().ok()?;
            let rect = w.rect().ok()?;
            let (width, height) = (rect.right - rect.left, rect.bottom - rect.top);
            // Larger than 120 × 80, titled, and not Studio's own — the Mac's filter.
            if title.trim().is_empty() || width < 120 || height < 80 {
                return None;
            }
            let app = w.process_name().unwrap_or_default();
            let lower = app.to_ascii_lowercase();
            if lower.starts_with("klik-studio") || lower.starts_with("klik studio") {
                return None;
            }
            Some(WindowInfo { hwnd: w.as_raw_hwnd() as i64, title, app, x: rect.left, y: rect.top, width, height })
        })
        .collect()
}

#[cfg(not(windows))]
pub fn windows_list() -> Vec<WindowInfo> {
    Vec::new()
}
