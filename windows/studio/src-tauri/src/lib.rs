//! Cue Studio for Windows: record the screen, then edit it into something that looks
//! made — the Mac's Cue Studio, built on Windows' own capture, sound and video APIs.
//!
//! Windows here are made when asked for; the web side picks what to draw from the label:
//! `bar` (the recorder), `picker-N` (choosing what to record on display N), `countdown`,
//! `library`, `editor-<id>`.

mod commands;
mod media;
mod record;
mod windows;

use std::sync::Mutex;
use tauri::Manager;

pub struct AppState {
    pub session: Mutex<Option<record::session::Session>>,
}

pub fn run() {
    tauri::Builder::default()
        // A second launch, or a `cue-studio://` link from Cue, reaches this one.
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            windows::handle_args(app, &args);
        }))
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .setup(|app| {
            app.manage(AppState { session: Mutex::new(None) });
            app.manage(media::Media::default());
            #[cfg(any(windows, target_os = "linux"))]
            {
                use tauri_plugin_deep_link::DeepLinkExt;
                app.deep_link().register_all().ok();
            }
            let args: Vec<String> = std::env::args().collect();
            windows::handle_args(app.handle(), &args);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::displays,
            commands::windows_list,
            commands::microphones,
            commands::start_recording,
            commands::pause_recording,
            commands::resume_recording,
            commands::stop_recording,
            commands::cancel_recording,
            commands::recording_state,
            commands::library,
            commands::open_library,
            commands::open_editor,
            commands::read_project,
            commands::write_project,
            commands::reveal_recording,
            commands::open_file,
            commands::log_line,
            commands::delete_recording,
            commands::open_picker,
            commands::close_picker,
            commands::show_bar,
            media::video_open,
            media::video_read,
            media::video_close,
            media::export_begin,
            media::export_write,
            media::export_end,
        ])
        .run(tauri::generate_context!())
        .expect("error while starting Cue Studio");
}
