//! Klik for Windows: the screenshot tool, in the tray.

mod actions;
mod assets;
mod cliphistory;
mod islandcmds;
mod notes;
mod paste;
mod stores;
mod capture;
mod clipboard;
mod commands;
mod finish;
mod hotkeys;
mod island;
mod library;
mod notify;
mod ocr;
mod protocol;
mod secrets;
mod settings;
mod share;
mod sound;
mod state;
mod tray;
mod updates;
mod windows;

use settings::Settings;
use state::{default_captures_folder, AppState};
use std::sync::Mutex;
use tauri::{Manager, RunEvent};

pub fn run() {
    tauri::Builder::default()
        // A second launch — from the Start menu, say — opens History instead of starting
        // another Klik that would fight this one for the shortcuts. `klik --capture area`
        // takes a capture instead, for scripts and other launchers.
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            #[cfg(debug_assertions)]
            if let Some(index) = args.iter().position(|a| a == "--island-demo") {
                island::demo(app, args.get(index + 1).map(String::as_str).unwrap_or("expanded"));
                return;
            }
            actions::run(app, &actions::from_args(&args).unwrap_or_else(|| "showHistory".into()));
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_autostart::Builder::new().args(["--autostart"]).build())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        // Off the main thread: a thumbnail is made the first time it is asked for, and a
        // History full of new captures would otherwise stall every window while they are.
        .register_asynchronous_uri_scheme_protocol(protocol::SCHEME, |context, request, responder| {
            let app = context.app_handle().clone();
            std::thread::spawn(move || responder.respond(protocol::handle(&app, request)));
        })
        .setup(|app| {
            let roaming = app.path().config_dir()?.join("Klik");
            let local = app.path().local_data_dir()?.join("Klik");
            let settings_path = roaming.join("settings.json");
            let settings = Settings::load(&settings_path);
            let folder = settings.save_folder.clone().unwrap_or_else(default_captures_folder);
            app.manage(AppState {
                settings: Mutex::new(settings),
                settings_path,
                library: Mutex::new(library::Library::open(folder, &local)),
                session: Mutex::new(None),
                conflicts: Mutex::new(Vec::new()),
            });

            app.manage(stores::Stores::open(&roaming, &local));
            app.manage(islandcmds::NotesFolder(notes::folder(&roaming)));
            cliphistory::watch(app.handle().clone());

            app.manage(island::Islands::default());
            island::rebuild(app.handle());
            island::watch(app.handle().clone());

            tray::create(app.handle())?;
            let conflicts = hotkeys::apply(app.handle());
            for conflict in &conflicts {
                log::warn!("Shortcut {} for {} is taken: {}", conflict.accelerator, conflict.action, conflict.message);
            }
            *app.state::<AppState>().conflicts.lock().unwrap() = conflicts;

            // Started by hand, show something, so it is plain that Klik is running; started
            // at login, stay in the tray.
            app.manage(updates::Updates::default());
            updates::start(app.handle().clone());

            let args: Vec<String> = std::env::args().collect();
            if let Some(action) = actions::from_args(&args) {
                actions::run(app.handle(), &action);
            } else if !args.iter().any(|arg| arg == "--autostart") {
                actions::run(app.handle(), "showHistory");
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_settings,
            commands::set_settings,
            commands::shortcut_conflicts,
            commands::pause_shortcuts,
            commands::default_folder,
            commands::get_autostart,
            commands::set_autostart,
            commands::run_action,
            commands::start_capture,
            commands::overlay_info,
            commands::overlay_ready,
            commands::finish_capture,
            commands::cancel_capture,
            commands::history_items,
            commands::history_item_by_id,
            commands::history_delete,
            commands::history_rename,
            commands::history_set_pinned,
            commands::history_copy,
            commands::history_reveal,
            commands::history_open_folder,
            commands::history_edit,
            commands::history_float,
            commands::history_share,
            commands::share_secret_status,
            commands::set_share_secret,
            commands::editor_save,
            commands::editor_copy,
            commands::editor_write_file,
            commands::copy_text,
            commands::log_error,
            commands::island_ready,
            commands::island_interactive,
            commands::island_take_keyboard,
            commands::island_geometry,
            commands::default_shortcuts,
            commands::app_info,
            commands::reveal_app,
            commands::open_windows_settings,
            islandcmds::store_list,
            islandcmds::store_put,
            islandcmds::store_update,
            islandcmds::store_delete,
            islandcmds::store_clear_unpinned,
            islandcmds::clip_copy,
            islandcmds::copy_text_and_paste,
            islandcmds::paste_item,
            islandcmds::forget_front,
            islandcmds::assets_add_paths,
            islandcmds::assets_add_clipboard,
            islandcmds::asset_copy,
            islandcmds::asset_open,
            islandcmds::asset_reveal,
            islandcmds::asset_rename,
            islandcmds::notes_list,
            islandcmds::note_save,
            islandcmds::note_delete,
            islandcmds::note_reveal,
            islandcmds::history_set_group,
            islandcmds::history_clear_unpinned,
            islandcmds::open_link,
            islandcmds::reveal_path,
            updates::update_state,
            updates::update_check,
            updates::update_install,
        ])
        .build(tauri::generate_context!())
        .expect("error while starting Klik")
        .run(|_app, event| {
            // Closing the last window leaves Klik in the tray; only Quit ends it.
            if let RunEvent::ExitRequested { api, code: None, .. } = event {
                api.prevent_exit();
            }
        });
}
