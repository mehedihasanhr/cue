//! Capture Text: Windows' own OCR engine (`Windows.Media.Ocr`), in the languages the user
//! has installed in Windows — nothing to download, and nothing leaves the PC.

use anyhow::Result;
use image::RgbaImage;
use tauri::AppHandle;

/// Recognises the text in `image`, puts it on the clipboard and says how it went.
pub fn recognize_to_clipboard(app: &AppHandle, image: RgbaImage) -> Result<()> {
    let text = recognize(&image)?;
    if text.trim().is_empty() {
        crate::island::status(app, "tray", "No text found", Some("Cue couldn't read any text there."));
        return Ok(());
    }
    crate::clipboard::copy_text(&text)?;
    let lines = text.lines().count();
    let summary = if lines == 1 { "1 line".to_string() } else { format!("{lines} lines") };
    crate::island::status(app, "checkmark.circle.fill", "Text copied", Some(&format!("{summary} on the clipboard")));
    Ok(())
}

#[cfg(windows)]
pub fn recognize(image: &RgbaImage) -> Result<String> {
    use anyhow::Context;
    use image::imageops::FilterType;
    use windows::Graphics::Imaging::{BitmapAlphaMode, BitmapPixelFormat, SoftwareBitmap};
    use windows::Media::Ocr::OcrEngine;
    use windows::Storage::Streams::DataWriter;

    let engine = OcrEngine::TryCreateFromUserProfileLanguages()
        .context("Windows has no text recognition for your languages. Add a language with OCR in Settings › Time & language.")?;

    // Small text reads better enlarged; the engine refuses anything over its maximum side.
    let max = OcrEngine::MaxImageDimension()? as f32;
    let longest = image.width().max(image.height()) as f32;
    let factor = if longest < 800.0 { 2.0f32.min(max / longest) } else { (max / longest).min(1.0) };
    let prepared = if (factor - 1.0).abs() > 0.01 {
        let width = (image.width() as f32 * factor).round().max(1.0) as u32;
        let height = (image.height() as f32 * factor).round().max(1.0) as u32;
        image::imageops::resize(image, width, height, FilterType::CatmullRom)
    } else {
        image.clone()
    };
    let (width, height) = (prepared.width() as i32, prepared.height() as i32);

    // RGBA → BGRA, which is what SoftwareBitmap takes.
    let mut bgra = prepared.into_raw();
    for pixel in bgra.chunks_exact_mut(4) {
        pixel.swap(0, 2);
    }
    let writer = DataWriter::new()?;
    writer.WriteBytes(&bgra)?;
    let buffer = writer.DetachBuffer()?;
    let bitmap = SoftwareBitmap::CreateCopyWithAlphaFromBuffer(
        &buffer,
        BitmapPixelFormat::Bgra8,
        width,
        height,
        BitmapAlphaMode::Premultiplied,
    )?;
    let result = engine.RecognizeAsync(&bitmap)?.join()?;
    let mut lines = Vec::new();
    for line in result.Lines()? {
        lines.push(line.Text()?.to_string_lossy());
    }
    Ok(lines.join("\n"))
}

#[cfg(not(windows))]
pub fn recognize(_image: &RgbaImage) -> Result<String> {
    anyhow::bail!("Capture Text uses Windows' own OCR, so it only works on Windows.")
}
