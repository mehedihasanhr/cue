//! The clipboard. `arboard` puts a PNG and a DIB on it, so both Paint and the browser
//! can paste.

use anyhow::{Context, Result};
use image::RgbaImage;
use std::borrow::Cow;

pub fn copy_image(image: &RgbaImage) -> Result<()> {
    crate::cliphistory::mark_own_copy();
    arboard::Clipboard::new()
        .and_then(|mut clipboard| {
            clipboard.set_image(arboard::ImageData {
                width: image.width() as usize,
                height: image.height() as usize,
                bytes: Cow::Borrowed(image.as_raw()),
            })
        })
        .context("Could not copy to the clipboard")
}

pub fn copy_text(text: &str) -> Result<()> {
    crate::cliphistory::mark_own_copy();
    arboard::Clipboard::new()
        .and_then(|mut clipboard| clipboard.set_text(text.to_owned()))
        .context("Could not copy to the clipboard")
}
