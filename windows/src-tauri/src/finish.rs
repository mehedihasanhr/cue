//! What happens to a capture once it is taken.

use crate::{capture::Mode, clipboard, settings::AfterCapture, state::AppState, windows};
use anyhow::Result;
use image::RgbaImage;
use tauri::{AppHandle, Emitter, Manager};

pub fn deliver(app: &AppHandle, image: RgbaImage, scale: f64, mode: Mode) -> Result<()> {
    let state = app.state::<AppState>();
    let settings = state.settings();

    if mode == Mode::Text {
        return crate::ocr::recognize_to_clipboard(app, image);
    }

    // The clipboard first: it is what the user reaches for next, and it does not wait on
    // a PNG being compressed.
    if settings.copy_to_clipboard {
        if let Err(error) = clipboard::copy_image(&image) {
            log::warn!("{error:#}");
        }
    }
    if settings.capture.sound {
        crate::sound::shutter();
    }
    let item = state.library.lock().unwrap().add(&image, scale)?;
    app.emit("library-changed", ()).ok();

    // The island flashes the capture, as on the Mac; without one, a notification says
    // where it went — unless the editor opening says so already.
    let url = crate::protocol::url(&format!("thumb/{}", item.id));
    let flashed = crate::island::flash(app, &item, url, settings.copy_to_clipboard);
    if settings.after_capture == AfterCapture::Edit {
        windows::open_editor(app, item.id)?;
    } else if !flashed {
        let (title, body) = if settings.copy_to_clipboard {
            ("Capture copied", "It's on the clipboard and in History.")
        } else {
            ("Capture saved", "It's in History.")
        };
        crate::notify::send(app, title, body);
    }
    Ok(())
}
