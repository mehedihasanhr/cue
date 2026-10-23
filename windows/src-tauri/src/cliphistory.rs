//! Clipboard history: what is copied anywhere, kept for the island's Clipboard tab —
//! the Mac's `ClipboardHistory`.
//!
//! Windows bumps a sequence number on every copy, so a look twice a second costs almost
//! nothing while nothing changes. What password managers mark as private is skipped, as
//! are Cue's own copies and a repeat of the newest entry. An entry's fields are the
//! Mac's `ClipboardItem`: `kind` is text, link, color, image or files; `text` holds the
//! text, the colour as `#RRGGBB`, or the files' paths one per line; a picture is a PNG
//! in the Clipboard folder named by the entry's id.

use crate::state::AppState;
use crate::stores::{id_of, Stores};
use serde_json::{json, Value};
use std::borrow::Cow;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tauri::{AppHandle, Manager};

/// The largest text kept; longer copies are left out rather than slow every list.
const MAX_TEXT: usize = 2 * 1024 * 1024;

/// Set by Cue's own copies, so the watcher leaves the next change alone.
static OWN_COPY: AtomicBool = AtomicBool::new(false);

pub fn mark_own_copy() {
    OWN_COPY.store(true, Ordering::SeqCst);
}

pub fn watch(app: AppHandle) {
    std::thread::spawn(move || {
        let mut last = change_marker();
        loop {
            std::thread::sleep(Duration::from_millis(500));
            let marker = change_marker();
            if marker == last {
                continue;
            }
            last = marker;
            if OWN_COPY.swap(false, Ordering::SeqCst) {
                continue;
            }
            let settings = app.state::<AppState>().settings().clipboard;
            if !settings.enabled || is_private() {
                continue;
            }
            if let Some(entry) = read(&app) {
                let stores = app.state::<Stores>();
                // A repeat of the newest entry (copying the same thing twice) is not news.
                let newest = stores.list("clipboard").into_iter().next();
                if newest.is_some_and(|n| same(&n, &entry)) {
                    if let Some(id) = entry.get("id").and_then(Value::as_str) {
                        std::fs::remove_file(stores.clipboard_folder().join(format!("{id}.png"))).ok();
                    }
                    continue;
                }
                stores.put(&app, "clipboard", entry, Some(settings.limit.max(10) as usize));
            }
        }
    });
}

/// Changes whenever the clipboard does: Windows' sequence number, or elsewhere (where
/// this only runs to be tried out) the text itself.
fn change_marker() -> String {
    #[cfg(windows)]
    {
        unsafe { windows::Win32::System::DataExchange::GetClipboardSequenceNumber() }.to_string()
    }
    #[cfg(not(windows))]
    {
        arboard::Clipboard::new().and_then(|mut c| c.get_text()).unwrap_or_default()
    }
}

/// Password managers mark what they copy so clipboard tools leave it alone.
fn is_private() -> bool {
    #[cfg(windows)]
    unsafe {
        use windows::core::w;
        use windows::Win32::System::DataExchange::{IsClipboardFormatAvailable, RegisterClipboardFormatW};
        for name in [w!("ExcludeClipboardContentFromMonitorProcessing"), w!("Clipboard Viewer Ignore")] {
            let format = RegisterClipboardFormatW(name);
            if format != 0 && IsClipboardFormatAvailable(format).is_ok() {
                return true;
            }
        }
        let history = RegisterClipboardFormatW(w!("CanIncludeInClipboardHistory"));
        // Present with a zero: "don't keep this". Reading its value needs the clipboard
        // open; its presence alone is what password managers set.
        if history != 0 && IsClipboardFormatAvailable(history).is_ok() {
            return true;
        }
    }
    false
}

fn same(a: &Value, b: &Value) -> bool {
    let field = |v: &Value, k: &str| v.get(k).cloned().unwrap_or(Value::Null);
    if field(a, "kind") != field(b, "kind") {
        return false;
    }
    if field(a, "kind") == json!("image") {
        return field(a, "hash") == field(b, "hash");
    }
    field(a, "text") == field(b, "text")
}

/// What is on the clipboard now, as a new entry.
fn read(app: &AppHandle) -> Option<Value> {
    let mut clipboard = arboard::Clipboard::new().ok()?;
    let id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let now = chrono::Utc::now().to_rfc3339();
    let source = source_name();
    let mut entry = json!({ "id": id, "createdAt": now, "pinned": false });
    if let Some(name) = source {
        entry["sourceName"] = json!(name);
    }

    if let Ok(files) = clipboard.get().file_list() {
        if !files.is_empty() {
            let text = files.iter().map(|p| p.to_string_lossy()).collect::<Vec<_>>().join("\n");
            entry["kind"] = json!("files");
            entry["text"] = json!(text);
            return Some(entry);
        }
    }
    if let Ok(text) = clipboard.get_text() {
        if text.trim().is_empty() || text.len() > MAX_TEXT {
            return None;
        }
        entry["kind"] = json!(classify(&text));
        entry["text"] = json!(if classify(&text) == "color" { normalize_color(&text).unwrap_or(text) } else { text });
        return Some(entry);
    }
    if let Ok(image) = clipboard.get_image() {
        let (width, height) = (image.width as u32, image.height as u32);
        let rgba = image::RgbaImage::from_raw(width, height, image.bytes.into_owned())?;
        let hash = {
            use std::hash::{Hash, Hasher};
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            rgba.as_raw().hash(&mut hasher);
            format!("{:x}", hasher.finish())
        };
        let folder = app.state::<Stores>().clipboard_folder();
        std::fs::create_dir_all(&folder).ok();
        rgba.save_with_format(folder.join(format!("{id}.png")), image::ImageFormat::Png).ok()?;
        entry["kind"] = json!("image");
        entry["pixelWidth"] = json!(width);
        entry["pixelHeight"] = json!(height);
        entry["hash"] = json!(hash);
        return Some(entry);
    }
    None
}

/// The Mac's rules: a colour value is a colour, one URL alone is a link.
pub fn classify(text: &str) -> &'static str {
    let trimmed = text.trim();
    if normalize_color(trimmed).is_some() {
        return "color";
    }
    let one_url = !trimmed.contains(char::is_whitespace)
        && trimmed.len() < 2048
        && ["http://", "https://", "mailto:", "ftp://"].iter().any(|s| trimmed.to_ascii_lowercase().starts_with(s));
    if one_url {
        "link"
    } else {
        "text"
    }
}

/// `#RGB`, `#RRGGBB`, `#RRGGBBAA` or `rgb(r, g, b)` as `#RRGGBB`.
fn normalize_color(text: &str) -> Option<String> {
    let t = text.trim();
    if let Some(hex) = t.strip_prefix('#') {
        if !hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        return match hex.len() {
            3 => Some(format!("#{}", hex.chars().flat_map(|c| [c, c]).collect::<String>().to_uppercase())),
            6 | 8 => Some(format!("#{}", hex[..6].to_uppercase())),
            _ => None,
        };
    }
    let lower = t.to_ascii_lowercase();
    let inner = lower.strip_prefix("rgba(").or_else(|| lower.strip_prefix("rgb("))?.strip_suffix(')')?;
    let parts: Vec<u8> = inner.split(',').take(3).map(|p| p.trim().parse::<u8>()).collect::<Result<_, _>>().ok()?;
    (parts.len() == 3).then(|| format!("#{:02X}{:02X}{:02X}", parts[0], parts[1], parts[2]))
}

/// The app in front when the copy was made, by its program's name.
fn source_name() -> Option<String> {
    #[cfg(windows)]
    unsafe {
        use windows::Win32::Foundation::CloseHandle;
        use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
        use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};
        let window = GetForegroundWindow();
        let mut pid = 0u32;
        GetWindowThreadProcessId(window, Some(&mut pid));
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buffer = [0u16; 512];
        let mut length = buffer.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, windows::core::PWSTR(buffer.as_mut_ptr()), &mut length).is_ok();
        CloseHandle(process).ok();
        if !ok {
            return None;
        }
        let path = String::from_utf16_lossy(&buffer[..length as usize]);
        let stem = std::path::Path::new(&path).file_stem()?.to_string_lossy().into_owned();
        return Some(pretty_app_name(&stem));
    }
    #[cfg(not(windows))]
    None
}

/// "msedge" → "Microsoft Edge": the names people know, for the usual programs.
#[cfg_attr(not(windows), allow(dead_code))]
fn pretty_app_name(stem: &str) -> String {
    let known = [
        ("msedge", "Microsoft Edge"),
        ("chrome", "Google Chrome"),
        ("firefox", "Firefox"),
        ("explorer", "File Explorer"),
        ("code", "Visual Studio Code"),
        ("winword", "Word"),
        ("excel", "Excel"),
        ("powerpnt", "PowerPoint"),
        ("outlook", "Outlook"),
        ("notepad", "Notepad"),
        ("windowsterminal", "Terminal"),
        ("slack", "Slack"),
        ("teams", "Microsoft Teams"),
        ("ms-teams", "Microsoft Teams"),
        ("discord", "Discord"),
        ("figma", "Figma"),
        ("notion", "Notion"),
        ("obsidian", "Obsidian"),
    ];
    let lower = stem.to_ascii_lowercase();
    known.iter().find(|(k, _)| *k == lower).map(|(_, v)| v.to_string()).unwrap_or_else(|| {
        let mut chars = stem.chars();
        chars.next().map(|c| c.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or_default()
    })
}

/// Puts an entry back on the clipboard, as it was copied.
pub fn copy_entry(app: &AppHandle, entry: &Value) -> anyhow::Result<()> {
    use anyhow::Context;
    let kind = entry.get("kind").and_then(Value::as_str).unwrap_or("text");
    let text = entry.get("text").and_then(Value::as_str).unwrap_or("");
    mark_own_copy();
    match kind {
        "image" => {
            let id = id_of(entry).context("No id")?;
            let path = app.state::<Stores>().clipboard_folder().join(format!("{id}.png"));
            let image = image::open(path).context("The picture is gone")?.to_rgba8();
            let mut clipboard = arboard::Clipboard::new()?;
            clipboard.set_image(arboard::ImageData {
                width: image.width() as usize,
                height: image.height() as usize,
                bytes: Cow::Borrowed(image.as_raw()),
            })?;
        }
        "files" => {
            let paths: Vec<&str> = text.lines().filter(|l| !l.is_empty()).collect();
            arboard::Clipboard::new()?.set().file_list(&paths)?;
        }
        _ => crate::clipboard::copy_text(text)?,
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_like_the_mac() {
        assert_eq!(classify("#0e4fec"), "color");
        assert_eq!(classify("rgb(14, 79, 236)"), "color");
        assert_eq!(classify("https://cue.app/download"), "link");
        assert_eq!(classify("see https://cue.app"), "text");
        assert_eq!(classify("hello"), "text");
        assert_eq!(normalize_color("#abc").as_deref(), Some("#AABBCC"));
        assert_eq!(normalize_color("rgb(14, 79, 236)").as_deref(), Some("#0E4FEC"));
    }
}
