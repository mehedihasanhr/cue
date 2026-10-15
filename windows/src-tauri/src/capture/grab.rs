//! Reading pixels off the screen, through `xcap`.

use super::{geometry::Rect, Frame, WindowInfo};
use anyhow::{Context, Result};
use image::{codecs::png, ImageEncoder, RgbaImage};
use std::sync::Arc;
use xcap::{Monitor, Window};

/// Every display, grabbed together and encoded in parallel.
pub fn all_displays() -> Result<Vec<Frame>> {
    let monitors = Monitor::all().context("Could not list the displays")?;
    let grabbed: Vec<(Rect, f64, RgbaImage)> = monitors
        .iter()
        .map(|monitor| {
            let bounds = Rect::new(monitor.x()?, monitor.y()?, monitor.width()?, monitor.height()?);
            let scale = monitor.scale_factor().unwrap_or(1.0) as f64;
            Ok((bounds, scale, monitor.capture_image()?))
        })
        .collect::<Result<_, xcap::XCapError>>()
        .context("Could not capture the screen")?;

    std::thread::scope(|scope| {
        let jobs: Vec<_> = grabbed
            .into_iter()
            .map(|(bounds, scale, image)| {
                scope.spawn(move || -> Result<Frame> {
                    let png = Arc::new(encode_fast(&image)?);
                    Ok(Frame { bounds, scale, image, png })
                })
            })
            .collect();
        jobs.into_iter().map(|job| job.join().expect("encoder panicked")).collect()
    })
}

/// The display under `point` (physical desktop pixels).
pub fn display_at(point: (i32, i32)) -> Result<(RgbaImage, f64)> {
    let monitor = Monitor::from_point(point.0, point.1)
        .or_else(|_| Monitor::all().map(|all| all.into_iter().next().unwrap()))
        .context("Could not find the display")?;
    let scale = monitor.scale_factor().unwrap_or(1.0) as f64;
    Ok((monitor.capture_image().context("Could not capture the screen")?, scale))
}

/// The windows on screen, front to back, without this app's own or anything minimized.
pub fn windows() -> Vec<WindowInfo> {
    let own = std::process::id();
    Window::all()
        .unwrap_or_default()
        .into_iter()
        .filter(|window| window.pid().map(|pid| pid != own).unwrap_or(false))
        .filter(|window| !window.is_minimized().unwrap_or(true))
        .filter_map(|window| {
            let rect = Rect::new(window.x().ok()?, window.y().ok()?, window.width().ok()?, window.height().ok()?);
            (rect.width > 8 && rect.height > 8).then(|| WindowInfo {
                rect,
                title: window.title().unwrap_or_default(),
                app: window.app_name().unwrap_or_default(),
            })
        })
        .collect()
}

/// PNG at the fastest setting: the overlay needs it in a few milliseconds, not small.
fn encode_fast(image: &RgbaImage) -> Result<Vec<u8>> {
    let mut data = Vec::with_capacity(image.as_raw().len() / 3);
    png::PngEncoder::new_with_quality(&mut data, png::CompressionType::Fast, png::FilterType::NoFilter)
        .write_image(image.as_raw(), image.width(), image.height(), image::ExtendedColorType::Rgba8)?;
    Ok(data)
}
