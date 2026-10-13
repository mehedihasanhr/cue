import AppKit

/// The application main menu. With a Dock tile Klik is a regular app, and macOS shows
/// its main menu in the menu bar, so the bar carries only the Klik menu; Klik's commands
/// live in the status item. The key equivalents Klik's windows need (⌘W, ⌘Z, ⌘C,
/// the editor's ⌘S and zoom…) sit in that menu as hidden items, which still answer keys.
enum MainMenu {
    static func install(target: AnyObject) {
        let main = NSMenu()

        // Klik
        let appMenu = NSMenu(title: "Klik")
        appMenu.addItem(withTitle: "About Klik", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Klik", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Klik", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File — editor actions travel the responder chain to the editor window controller.
        appMenu.addShortcut("Save", #selector(EditorWindowController.saveDocument(_:)), "s")
        appMenu.addShortcut("Export…", #selector(EditorWindowController.saveDocumentAs(_:)), "s", [.command, .shift])
        appMenu.addShortcut("Close", #selector(NSWindow.performClose(_:)), "w")

        // Edit — standard responder-chain selectors so text fields and the editor work.
        appMenu.addShortcut("Undo", Selector(("undo:")), "z")
        appMenu.addShortcut("Redo", Selector(("redo:")), "z", [.command, .shift])
        appMenu.addShortcut("Cut", #selector(NSText.cut(_:)), "x")
        appMenu.addShortcut("Copy", #selector(NSText.copy(_:)), "c")
        appMenu.addShortcut("Paste", #selector(NSText.paste(_:)), "v")
        appMenu.addShortcut("Delete", #selector(NSText.delete(_:)), "\u{8}")
        appMenu.addShortcut("Select All", #selector(NSText.selectAll(_:)), "a")
        appMenu.addShortcut("Duplicate", #selector(CanvasView.duplicate(_:)), "d")

        // View — zoom commands for the editor. ⌘= too: on most layouts "+" needs ⇧,
        // and ⌘= is what people press.
        appMenu.addShortcut("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "+")
        appMenu.addShortcut("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "=")
        appMenu.addShortcut("Zoom Out", #selector(EditorWindowController.zoomOut(_:)), "-")
        appMenu.addShortcut("Zoom to Fit", #selector(EditorWindowController.zoomToFit(_:)), "0")
        appMenu.addShortcut("Actual Size", #selector(EditorWindowController.zoomActualSize(_:)), "1")

        // Window
        appMenu.addShortcut("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")

        let appItem = NSMenuItem(title: appMenu.title, action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }
}

private extension NSMenu {
    /// A hidden item: kept out of the menu bar, still performing its key equivalent.
    func addShortcut(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
        let item = addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
    }
}
