import AppKit

/// The application main menu. An agent app has no visible menu bar of its own, but
/// the main menu still provides key equivalents (⌘W, ⌘Q, ⌘C, ⌘Z…) for Klik's windows.
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
        main.addItem(submenu: appMenu)

        // Capture
        let captureMenu = NSMenu(title: "Capture")
        for (title, selector) in [
            ("Capture Full Screen", #selector(AppDelegate.captureFullScreen(_:))),
            ("Capture Area", #selector(AppDelegate.captureArea(_:))),
            ("Capture Window", #selector(AppDelegate.captureWindow(_:))),
            ("Record Screen…", #selector(AppDelegate.recordScreen(_:))),
            ("Open Klik Studio", #selector(AppDelegate.openStudio(_:))),
            ("Scrolling Capture", #selector(AppDelegate.captureScrolling(_:))),
            ("Capture Text", #selector(AppDelegate.captureText(_:))),
            ("Pick Color", #selector(AppDelegate.pickColor(_:))),
            ("Quick Task…", #selector(AppDelegate.quickTask(_:))),
            ("Quick Note…", #selector(AppDelegate.quickNote(_:))),
            ("Clipboard List…", #selector(AppDelegate.showClipboardPanel(_:))),
            ("Command Palette…", #selector(AppDelegate.showCommandPalette(_:))),
        ] {
            let item = captureMenu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            item.target = target
        }
        main.addItem(submenu: captureMenu)

        // File — editor actions travel the responder chain to the editor window controller.
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let export = fileMenu.addItem(withTitle: "Export…", action: #selector(EditorWindowController.saveDocumentAs(_:)), keyEquivalent: "s")
        export.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: fileMenu)

        // Edit — standard responder-chain selectors so text fields and the editor work.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "\u{8}")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Duplicate", action: #selector(CanvasView.duplicate(_:)), keyEquivalent: "d")
        main.addItem(submenu: editMenu)

        // View — zoom commands for the editor.
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(EditorWindowController.zoomIn(_:)), keyEquivalent: "+")
        // ⌘= too: on most layouts "+" needs ⇧, and ⌘= is what people press.
        let zoomInEquals = NSMenuItem(title: "Zoom In", action: #selector(EditorWindowController.zoomIn(_:)), keyEquivalent: "=")
        zoomInEquals.isHidden = true
        zoomInEquals.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(zoomInEquals)
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(EditorWindowController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Zoom to Fit", action: #selector(EditorWindowController.zoomToFit(_:)), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(EditorWindowController.zoomActualSize(_:)), keyEquivalent: "1")
        main.addItem(submenu: viewMenu)

        // Window
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu: windowMenu)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
