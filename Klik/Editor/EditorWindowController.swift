import os
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One window per capture, in preview or edit mode (the same window switches between
/// them). Save writes the flattened image back to the library item; Export writes a
/// copy wherever the user chooses.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorViewModel
    let item: CaptureItem
    private let library: CaptureLibrary
    var onClose: (() -> Void)?
    var onDelete: ((CaptureItem) -> Void)?

    private let preferences: AppPreferences
    /// Opened over another app's full-screen Space: every-Space membership and floating.
    private var overFullScreen = false

    init(item: CaptureItem, image: CapturedImage, library: CaptureLibrary, preferences: AppPreferences, mode: EditorMode) {
        self.item = item
        self.library = library
        self.preferences = preferences
        model = EditorViewModel(image: image, defaults: preferences.editorDefaults)
        model.mode = mode

        let window = EditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = item.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The toolbar row draws its own traffic lights on the tools' centre line; the
        // native ones are pinned to AppKit's title-bar height and can't be moved.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Opens on the desktop the user is on, including a full-screen app's Space;
        // without `.fullScreenAuxiliary` macOS sends it back to the plain desktop.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false
        window.becomesKeyOnlyIfNeeded = false
        super.init(window: window)
        window.delegate = self
        // ⎋ closes a preview (like Quick Look). In edit mode the canvas owns ⎋; this
        // catches it when a toolbar control has focus instead, so ⎋ still returns to Select.
        // `self.window`, not the local `window`: this closure is stored *on* the window,
        // so capturing it strongly makes the window own a closure that owns the window.
        // With `isReleasedWhenClosed = false` — which is right, the controller manages the
        // lifetime — that cycle means a closed editor is never deallocated. Eight of them
        // were found alive and off-screen on a machine that had been editing all day, and
        // they turn up in anything that lists windows, including this app's own recorder.
        window.onEscape = { [weak self] in
            guard let self else { return false }
            if model.mode == .preview {
                self.window?.performClose(nil)
                return true
            }
            guard model.tool != .select else { return false }
            model.tool = .select
            return true
        }

        let root = EditorView(
            model: model,
            title: item.title,
            fileName: item.fileName,
            onCopy: { [weak self] in self?.copyToClipboard() },
            onSave: { [weak self] in self?.save() },
            onExport: { [weak self] in self?.export() },
            onDelete: { [weak self] in self?.deleteCapture() },
            onDone: { [weak self] in self?.done() },
            onAddImages: { [weak self] in self?.addImages() },
            windowButtons: WindowButtons(
                close: { [weak self] in self?.window?.performClose(nil) },
                minimize: { [weak self] in self?.window?.miniaturize(nil) },
                zoom: { [weak self] in
                    // Like the system's green button: full screen, ⌥-click zooms instead.
                    guard let window = self?.window else { return }
                    if NSEvent.modifierFlags.contains(.option) {
                        window.performZoom(nil)
                    } else {
                        // An auxiliary window can't take a Space of its own; become a
                        // primary one for the trip (swapped back on exit).
                        if !window.styleMask.contains(.fullScreen) {
                            // A Space of its own is a desktop Klik must be allowed on.
                            NSApp.activate()
                            self?.overFullScreen = false
                            window.level = .normal
                            window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
                        }
                        window.toggleFullScreen(nil)
                    }
                }
            )
        )
        let host = NSHostingController(rootView: root.ignoresSafeArea())
        // Don't let SwiftUI's ideal size pin the window; the user sizes it freely.
        host.sizingOptions = []
        window.contentViewController = host
        window.contentMinSize = CGSize(width: 560, height: 400)
        sizeToFit(image: image, on: Self.targetScreen(for: image))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The display to open on: the one the capture was taken from, else the one under the
    /// pointer. `NSScreen.main` is the primary display for a menu-bar app with no key
    /// window, which is the wrong monitor on a multi-display Mac mini or iMac.
    private static func targetScreen(for image: CapturedImage) -> NSScreen? {
        let screens = NSScreen.screens
        if image.displayID != 0, let screen = screens.first(where: { $0.displayID == image.displayID }) {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? screens.first
    }

    /// Opens large: most of the screen, and never smaller than the image needs (plus room
    /// for the background sidebar), so nothing has to be zoomed out on arrival. Centred on
    /// `screen`, so a 1080p external monitor and a 5K iMac panel each get a sensible size.
    private func sizeToFit(image: CapturedImage, on screen: NSScreen?) {
        guard let screen, let window else { return }
        let available = screen.visibleFrame
        let chrome = CGSize(width: BackgroundSidebar.width + 80, height: 160)
        let width = min(max(image.pointSize.width + chrome.width, available.width * 0.8), available.width * 0.94)
        let height = min(max(image.pointSize.height + chrome.height, available.height * 0.85), available.height * 0.94)
        window.setContentSize(CGSize(width: width, height: height))
        let frame = window.frame
        window.setFrameOrigin(CGPoint(
            x: available.midX - frame.width / 2,
            y: available.midY - frame.height / 2
        ))
    }

    /// Brings the window in front of whatever app the capture was taken over, on the
    /// desktop the user is on — a full-screen app's Space included.
    ///
    /// Klik is never activated for it: activating an app (a regular one, with its Dock
    /// tile, most of all) makes macOS switch to a desktop that app is allowed on, and
    /// another app's full-screen Space never is. The editor is a non-activating panel,
    /// so it takes the keyboard without that, the way the capture overlay does.
    ///
    /// Over another app's full screen, `.moveToActiveSpace` is not enough: macOS files
    /// the window on the plain desktop. There it joins every Space instead, like a
    /// pinned capture, and floats above the full-screen app until it is closed.
    func present() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let screen = NSScreen.screens.first { NSPointInRect(CGPoint(x: window.frame.midX, y: window.frame.midY), $0.frame) }
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        overFullScreen = screen.map(WindowDetector.isFullScreenSpace) ?? false
        // Left open on another desktop: take it off there, so it comes out here
        // instead of taking the user over to it.
        if window.isVisible, !window.isOnActiveSpace { window.orderOut(nil) }
        window.collectionBehavior = overFullScreen
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKey()
        // On a plain desktop Klik comes to the front: trackpad pinches, the menu bar
        // and ⌘-shortcuts only go to the active app. The window is already on this
        // desktop, so activating does not move the user. Over a full-screen app it
        // stays in the background, where activating would leave the Space.
        (window as? EditorWindow)?.activatesOnClick = !overFullScreen
        if !overFullScreen { NSApp.activate(ignoringOtherApps: true) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if !overFullScreen { window?.level = .normal }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !overFullScreen { window?.level = .normal }
    }

    /// Back to auxiliary, so the next `present()` can join a full-screen app's Space.
    func windowDidExitFullScreen(_ notification: Notification) {
        window?.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    /// Entering full screen failed or was refused: undo the swap made for it.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    /// Switch to the annotation tools; never drops back to preview once there are edits.
    func enterEditMode() {
        model.mode = .edit
    }

    /// Removes the capture from the library (to the Trash) and closes the window.
    private func deleteCapture() {
        model.endTextEditing()
        onDelete?(item)
        forceClose()
    }

    /// Close without the unsaved-changes prompt.
    func forceClose() {
        window?.delegate = nil
        rememberOptions()
        onClose?()
        window?.close()
    }

    /// With "remember last used" on, the next editor starts from this one's options.
    private func rememberOptions() {
        guard preferences.editorDefaults.rememberLastUsed, model.mode == .edit else { return }
        var options = model.options
        options.rememberLastUsed = true
        if options != preferences.editorDefaults { preferences.editorDefaults = options }
    }

    // MARK: - Actions

    @objc func copyToClipboard() {
        model.endTextEditing()
        guard let image = model.renderedImage() else { return }
        Clipboard.copy(image) // encodes in the background; returns at once
        Log.app.info("Copied edited capture to clipboard")
    }

    /// Save (if anything changed) and close — the capture is already in the library.
    @objc func done() {
        if model.isDirty { save() }
        window?.close()
    }

    /// Told the edited image on every save (a clipboard image goes back on the clipboard).
    var onSaved: ((CGImage) -> Void)?

    @objc func save() {
        model.endTextEditing()
        guard let image = model.renderedImage() else { return }
        library.replaceImage(of: item, with: image)
        model.markSaved()
        onSaved?(image)
    }

    /// Compare: pick images from disk and lay them beside this capture.
    @objc func addImages() {
        model.endTextEditing()
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images to place beside this capture."
        panel.prompt = "Compare"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let images = panel.urls.compactMap { ImageDrop.captured(at: $0) }
            guard !images.isEmpty else {
                FeedbackHUD.show("No image could be read", symbol: "photo")
                return
            }
            guard model.compare(with: images) else {
                FeedbackHUD.show("The images could not be combined", symbol: "exclamationmark.triangle")
                return
            }
            if model.mode == .preview { model.mode = .edit }
            Log.app.info("Editor: compared with \(images.count, privacy: .public) picked image(s)")
        }
    }

    @objc func export() {
        model.endTextEditing()
        guard let image = model.renderedImage(), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.nameFieldStringValue = item.fileName
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let type = UTType(filenameExtension: url.pathExtension) ?? .png
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return }
            let options: [CFString: Any] = type == .png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            if !CGImageDestinationFinalize(destination) {
                Log.app.error("Export failed for \(url.lastPathComponent, privacy: .public)")
            }
        }
    }

    // MARK: - Menu plumbing

    @objc func saveDocument(_ sender: Any?) { save() }
    @objc func saveDocumentAs(_ sender: Any?) { export() }
    @objc func copy(_ sender: Any?) { copyToClipboard() }
    @objc func zoomIn(_ sender: Any?) { model.applyZoom(.zoomIn) }
    @objc func zoomOut(_ sender: Any?) { model.applyZoom(.zoomOut) }
    @objc func zoomToFit(_ sender: Any?) { model.applyZoom(.fit) }
    @objc func zoomActualSize(_ sender: Any?) { model.applyZoom(.actualSize) }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.endTextEditing()
        guard model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(item.title)”?"
        alert.informativeText = "Your annotations will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        // A sheet, not `runModal()`: a modal alert activates Klik, and the Space
        // switch that comes with it would pull the user off a full-screen app.
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                save()
                forceClose()
            case .alertSecondButtonReturn:
                forceClose()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        rememberOptions()
        onClose?()
    }
}

/// Lets the controller intercept ⎋ before AppKit's default beep. A panel so it can
/// take the keyboard without activating Klik (see `EditorWindowController.present()`).
final class EditorWindow: NSPanel {
    var onEscape: (() -> Bool)?

    /// A click brings Klik to the front (set per presentation; see `present()`).
    var activatesOnClick = true

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if activatesOnClick, !NSApp.isActive, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            NSApp.activate(ignoringOtherApps: true)
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, onEscape?() == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        super.cancelOperation(sender)
    }
}
