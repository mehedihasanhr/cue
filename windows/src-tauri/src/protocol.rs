//! `cue://` — pictures for the web views, served from memory and disk without a trip
//! through IPC as base64.
//!
//!   frame/<session>/<display>.png   a frozen display, while a capture is being chosen
//!   capture/<id>                    a capture's PNG
//!   thumb/<id>                      its thumbnail
//!   clip/<id>                       a clipboard entry's picture
//!   asset/<id>                      an asset's file

use crate::state::AppState;
use tauri::http::{Request, Response, StatusCode};
use tauri::{AppHandle, Manager};

pub const SCHEME: &str = "cue";

/// The URL a web view loads `path` from. WebView2 has no custom schemes of its own, so
/// Tauri maps them to `http://<scheme>.localhost` there.
pub fn url(path: &str) -> String {
    if cfg!(windows) {
        format!("http://{SCHEME}.localhost/{path}")
    } else {
        format!("{SCHEME}://localhost/{path}")
    }
}

pub fn handle(app: &AppHandle, request: Request<Vec<u8>>) -> Response<Vec<u8>> {
    let path = request.uri().path().trim_start_matches('/').to_string();
    let parts: Vec<&str> = path.split('/').collect();
    let found = match parts.as_slice() {
        ["frame", session, display] => display
            .trim_end_matches(".png")
            .parse::<usize>()
            .ok()
            .and_then(|index| crate::capture::frame_png(app, session, index))
            .map(|png| ("image/png", png.as_ref().clone())),
        ["capture", id] => uuid::Uuid::parse_str(id).ok().and_then(|id| {
            let path = app.state::<AppState>().library.lock().unwrap().path(id)?;
            std::fs::read(path).ok().map(|data| ("image/png", data))
        }),
        ["thumb", id] => uuid::Uuid::parse_str(id).ok().and_then(|id| {
            app.state::<AppState>().library.lock().unwrap().thumbnail(id).ok().map(|data| ("image/jpeg", data))
        }),
        ["clip", id] => {
            let folder = app.state::<crate::stores::Stores>().clipboard_folder();
            let id = id.trim_end_matches(".png");
            (!id.contains(['/', '\\', '.'])).then(|| std::fs::read(folder.join(format!("{id}.png"))).ok()).flatten().map(|d| ("image/png", d))
        }
        ["asset", id] => crate::assets::path(app, id).and_then(|path| {
            let mime = match path.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase).as_deref() {
                Some("png") => "image/png",
                Some("jpg" | "jpeg") => "image/jpeg",
                Some("gif") => "image/gif",
                Some("webp") => "image/webp",
                Some("bmp") => "image/bmp",
                Some("avif") => "image/avif",
                _ => "application/octet-stream",
            };
            std::fs::read(path).ok().map(|d| (mime, d))
        }),
        _ => None,
    };
    match found {
        Some((mime, body)) => Response::builder()
            .header("Content-Type", mime)
            .header("Access-Control-Allow-Origin", "*")
            .header("Cache-Control", "no-store")
            .body(body)
            .unwrap(),
        None => Response::builder().status(StatusCode::NOT_FOUND).body(Vec::new()).unwrap(),
    }
}
