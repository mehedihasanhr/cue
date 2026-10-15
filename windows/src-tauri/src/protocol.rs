//! `klik://` — pictures for the web views, served from memory and disk without a trip
//! through IPC as base64.
//!
//!   frame/<session>/<display>.png   a frozen display, while a capture is being chosen
//!   capture/<id>                    a capture's PNG
//!   thumb/<id>                      its thumbnail

use crate::state::AppState;
use tauri::http::{Request, Response, StatusCode};
use tauri::{AppHandle, Manager};

pub const SCHEME: &str = "klik";

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
