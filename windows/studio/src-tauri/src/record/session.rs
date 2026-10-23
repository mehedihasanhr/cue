//! One take: starts the picture, the sound and the telemetry on one clock, pauses them
//! together, and on stop finishes every file and writes the manifest.

use super::audio::{AudioRecorder, Source};
use super::clock::Clock;
use super::package::{self, Manifest, TelemetryFiles, Track};
use super::screen::{self, Control, DisplayInfo, ScreenSettings, Target};
use super::telemetry::{Area, Telemetry};
use anyhow::{Context, Result};
use chrono::{Local, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// What the recorder bar asks for.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartOptions {
    pub target: Target,
    /// For an area take: the area in pixels of the display, from its top left.
    pub area: Option<[f64; 4]>,
    pub system_audio: bool,
    pub microphone: bool,
    pub microphone_id: Option<String>,
    pub microphone_name: Option<String>,
    /// 30 or 60.
    pub frame_rate: u32,
    /// `good`, `better` or `best`.
    pub quality: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionState {
    pub recording: bool,
    pub paused: bool,
    pub seconds: f64,
}

pub struct Session {
    package: PathBuf,
    name: String,
    created: chrono::DateTime<Utc>,
    clock: Arc<Clock>,
    control: Arc<Control>,
    stop_screen: Option<Box<dyn FnOnce() + Send>>,
    sound: Vec<(Track, AudioRecorder)>,
    telemetry: Option<Telemetry>,
    pixel_size: [u32; 2],
    frame_rate: u32,
    scale: f64,
    source_rect: Option<[[f64; 2]; 2]>,
    crop: Option<[f64; 4]>,
}

/// Capture bitrate, the Mac's: pixels × bits per pixel × fps, kept to 2…120 Mbit/s.
pub fn bitrate(width: u32, height: u32, fps: u32, quality: &str) -> u32 {
    let bpp = match quality {
        "good" => 0.08,
        "best" => 0.2,
        _ => 0.13,
    };
    ((width as f64 * height as f64 * bpp * fps as f64) as u64).clamp(2_000_000, 120_000_000) as u32
}

impl Session {
    pub fn start(options: StartOptions) -> Result<Self> {
        let geometry = geometry(&options.target).context("That display or window is gone")?;
        let (x, y, width, height, scale) = geometry;
        // Even sizes, as encoders want.
        let (width, height) = ((width.max(2) as u32) & !1, (height.max(2) as u32) & !1);
        let frame_rate = if options.frame_rate >= 60 { 60 } else { 30 };

        let now = Local::now();
        let name = package::take_name(now);
        let package = package::create(&package::library_folder(), &name)?;
        package::write_json(&package.join(package::IN_PROGRESS), &serde_json::json!({ "startedAt": Utc::now() }))?;

        let clock = Arc::new(Clock::default());
        let control = Arc::new(Control::default());
        let stop_screen = screen::start(
            ScreenSettings {
                target: options.target.clone(),
                path: package.join("media").join("screen.mp4"),
                width,
                height,
                frame_rate,
                bitrate: bitrate(width, height, frame_rate, &options.quality),
            },
            clock.clone(),
            control.clone(),
        )?;

        let mut sound = Vec::new();
        if options.system_audio {
            let path = package.join("media").join("system-audio.wav");
            let track = Track { kind: "systemAudio".into(), path: "media/system-audio.wav".into(), pixel_size: None, frame_rate: None, codec: None, name: Some("System audio".into()), device_id: None };
            match AudioRecorder::start(Source::System, None, path, clock.clone()) {
                Ok(recorder) => sound.push((track, recorder)),
                Err(error) => log::warn!("System audio: {error:#}"),
            }
        }
        if options.microphone {
            let path = package.join("media").join("microphone-1.wav");
            let track = Track {
                kind: "microphone".into(),
                path: "media/microphone-1.wav".into(),
                pixel_size: None,
                frame_rate: None,
                codec: None,
                name: options.microphone_name.clone().or(Some("Microphone".into())),
                device_id: options.microphone_id.clone(),
            };
            match AudioRecorder::start(Source::Microphone, options.microphone_id.clone(), path, clock.clone()) {
                Ok(recorder) => sound.push((track, recorder)),
                Err(error) => log::warn!("Microphone: {error:#}"),
            }
        }

        let telemetry = Telemetry::start(package.join("telemetry"), Area { x, y, width: width as i32, height: height as i32, scale }, clock.clone())?;

        // An area take records its display and keeps the area as the edit's crop.
        let (source_rect, crop) = match options.area {
            Some([ax, ay, aw, ah]) if aw > 8.0 && ah > 8.0 => (
                Some([[ax / scale, ay / scale], [aw / scale, ah / scale]]),
                Some([ax / width as f64, ay / height as f64, aw / width as f64, ah / height as f64]),
            ),
            _ => (None, None),
        };

        Ok(Self {
            package,
            name,
            created: now.with_timezone(&Utc),
            clock,
            control,
            stop_screen: Some(stop_screen),
            sound,
            telemetry: Some(telemetry),
            pixel_size: [width, height],
            frame_rate,
            scale,
            source_rect,
            crop,
        })
    }

    pub fn state(&self) -> SessionState {
        SessionState { recording: true, paused: self.clock.is_paused(), seconds: self.clock.recorded_seconds().unwrap_or(0.0) }
    }

    pub fn pause(&self) {
        self.control.paused.store(true, Ordering::SeqCst);
        self.clock.pause();
    }

    pub fn resume(&self) {
        let paused = self.clock.resume();
        self.control.skip.fetch_add(paused, Ordering::SeqCst);
        self.control.paused.store(false, Ordering::SeqCst);
    }

    /// Finishes every file and the manifest; returns the package.
    pub fn stop(mut self) -> Result<PathBuf> {
        // A take stopped in a pause ends where the pause began.
        let duration = self.clock.recorded_seconds().unwrap_or(0.0);
        if let Some(stop) = self.stop_screen.take() {
            stop();
        }
        let mut tracks = vec![Track {
            kind: "screen".into(),
            path: "media/screen.mp4".into(),
            pixel_size: Some([self.pixel_size[0] as f64, self.pixel_size[1] as f64]),
            frame_rate: Some(self.frame_rate),
            codec: Some("avc1".into()),
            name: None,
            device_id: None,
        }];
        for (track, recorder) in self.sound.drain(..) {
            match recorder.finish() {
                Ok(()) => tracks.push(track),
                Err(error) => log::warn!("{}: {error:#}", track.path),
            }
        }
        let latency = self.telemetry.take().map(Telemetry::finish).unwrap_or(0.0);

        let manifest = Manifest {
            format_version: 1,
            name: self.name.clone(),
            created_at: self.created,
            duration,
            display_scale: self.scale,
            source_rect: self.source_rect,
            tracks,
            telemetry: TelemetryFiles {
                cursor: Some("telemetry/cursor.jsonl".into()),
                input: Some("telemetry/input.jsonl".into()),
                cursor_artwork: Some("telemetry/cursors.json".into()),
                pointer_latency: Some(latency),
                keys: Some("recorded".into()),
            },
            recorded_by: "Cue Studio".into(),
        };
        package::write_json(&self.package.join("manifest.json"), &manifest)?;
        if let Some([x, y, w, h]) = self.crop {
            // The area, as the edit's crop: `{"crop":{"rect":[[x,y],[w,h]]}}`, normalised.
            package::write_json(&self.package.join("pending-crop.json"), &serde_json::json!({ "rect": [[x, y], [w, h]] }))?;
        }
        std::fs::remove_file(self.package.join(package::IN_PROGRESS)).ok();
        Ok(self.package.clone())
    }

    /// Throws the take away.
    pub fn cancel(mut self) {
        if let Some(stop) = self.stop_screen.take() {
            stop();
        }
        for (_, recorder) in self.sound.drain(..) {
            recorder.finish().ok();
        }
        if let Some(telemetry) = self.telemetry.take() {
            telemetry.finish();
        }
        // Gone for good would be a surprise; the Recycle Bin is not.
        trash::delete(&self.package).or_else(|_| std::fs::remove_dir_all(&self.package).map_err(|e| trash::Error::Unknown { description: e.to_string() })).ok();
    }

    /// Waits until the first frame has started the clock, so the bar's timer starts with
    /// the picture. Gives up after `limit`.
    pub fn wait_for_first_frame(&self, limit: Duration) -> bool {
        let began = Instant::now();
        while !self.clock.has_started() {
            if began.elapsed() > limit {
                return false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        true
    }
}

/// Where the target is on the desktop, in pixels, and its display's scale.
#[cfg(windows)]
fn geometry(target: &Target) -> Option<(i32, i32, i32, i32, f64)> {
    match target {
        Target::Display { index } => displays().into_iter().find(|d| d.index == *index).map(|d| (d.x, d.y, d.width as i32, d.height as i32, d.scale)),
        Target::Window { hwnd } => unsafe {
            use windows::Win32::Foundation::{HWND, RECT};
            use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_EXTENDED_FRAME_BOUNDS};
            use windows::Win32::UI::HiDpi::GetDpiForWindow;
            let window = HWND(*hwnd as *mut _);
            let mut rect = RECT::default();
            DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &mut rect as *mut _ as *mut _, std::mem::size_of::<RECT>() as u32).ok()?;
            let dpi = GetDpiForWindow(window).max(96);
            Some((rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, dpi as f64 / 96.0))
        },
    }
}

#[cfg(not(windows))]
fn geometry(_: &Target) -> Option<(i32, i32, i32, i32, f64)> {
    None
}

/// The displays, in the order the capture numbers them.
#[cfg(windows)]
pub fn displays() -> Vec<DisplayInfo> {
    use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, HMONITOR, MONITORINFO};
    use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
    use windows_capture::monitor::Monitor;
    const MONITORINFOF_PRIMARY: u32 = 1;
    Monitor::enumerate()
        .unwrap_or_default()
        .into_iter()
        .enumerate()
        .filter_map(|(index, monitor)| unsafe {
            let handle = HMONITOR(monitor.as_raw_hmonitor());
            let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
            GetMonitorInfoW(handle, &mut info).ok().ok()?;
            let (mut dx, mut dy) = (96u32, 96u32);
            GetDpiForMonitor(handle, MDT_EFFECTIVE_DPI, &mut dx, &mut dy).ok();
            let r = info.rcMonitor;
            Some(DisplayInfo {
                index,
                name: monitor.name().unwrap_or_else(|_| format!("Display {}", index + 1)),
                x: r.left,
                y: r.top,
                width: (r.right - r.left) as u32,
                height: (r.bottom - r.top) as u32,
                scale: dx.max(96) as f64 / 96.0,
                primary: info.dwFlags & MONITORINFOF_PRIMARY != 0,
            })
        })
        .collect()
}

#[cfg(not(windows))]
pub fn displays() -> Vec<DisplayInfo> {
    vec![DisplayInfo { index: 0, name: "Built-in Display".into(), x: 0, y: 0, width: 2880, height: 1800, scale: 2.0, primary: true }]
}

#[cfg(test)]
mod tests {
    #[test]
    fn bitrate_like_the_mac() {
        assert_eq!(super::bitrate(1920, 1080, 60, "better"), 16_174_080);
        assert_eq!(super::bitrate(320, 200, 30, "good"), 2_000_000);
        assert_eq!(super::bitrate(7680, 4320, 60, "best"), 120_000_000);
    }
}
