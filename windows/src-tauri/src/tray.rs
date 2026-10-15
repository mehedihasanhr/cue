//! The tray icon: Klik's menu bar item, on Windows.

use crate::{actions, state::AppState};
use tauri::menu::{Menu, MenuBuilder, MenuItemBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Wry};

const TRAY_ID: &str = "klik";

fn menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let shortcuts = app.state::<AppState>().settings().shortcuts;
    let item = |id: &str, title: &str| {
        let mut builder = MenuItemBuilder::with_id(id, title);
        if let Some(accelerator) = shortcuts.get(id).filter(|a| !a.is_empty()) {
            builder = builder.accelerator(accelerator);
        }
        builder.build(app)
    };
    MenuBuilder::new(app)
        .item(&item("captureArea", "Capture Area")?)
        .item(&item("captureWindow", "Capture Window")?)
        .item(&item("captureFullScreen", "Capture Full Screen")?)
        .item(&item("captureText", "Capture Text")?)
        .separator()
        .item(&MenuItemBuilder::with_id("recordScreen", "Record Screen\u{2026}").build(app)?)
        .item(&MenuItemBuilder::with_id("openStudio", "Edit Videos").build(app)?)
        .separator()
        .item(&item("showHistory", "Klik Panel")?)
        .item(&MenuItemBuilder::with_id("showSettings", "Settings\u{2026}").build(app)?)
        .separator()
        .item(&MenuItemBuilder::with_id("quit", "Quit Klik").build(app)?)
        .build()
}

pub fn create(app: &AppHandle) -> tauri::Result<()> {
    TrayIconBuilder::with_id(TRAY_ID)
        .icon(app.default_window_icon().cloned().expect("app icon"))
        .tooltip("Klik")
        .menu(&menu(app)?)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "quit" => crate::updates::quit(app),
            action => actions::run(app, action),
        })
        .on_tray_icon_event(|tray, event| {
            // A left click opens the Klik panel, as clicking the Mac's menu bar item does.
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                actions::run(tray.app_handle(), "showHistory");
            }
        })
        .build(app)?;
    Ok(())
}

/// Rebuilds the menu, so the shortcuts written beside each item stay true.
pub fn refresh(app: &AppHandle) {
    if let (Some(tray), Ok(menu)) = (app.tray_by_id(TRAY_ID), menu(app)) {
        tray.set_menu(Some(menu)).ok();
    }
}
