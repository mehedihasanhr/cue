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

    init(item: CaptureItem, image: CapturedImage, library: CaptureLibrary, mode: EditorMode) {
        self.item = item
        self.library = library
        model = EditorViewModel(image: image)
        model.mode = mode

        let window = EditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
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
        super.init(window: window)
        window.delegate = self
        // ⎋ closes a preview (like Quick Look); in edit mode the canvas owns ⎋ (deselect).
        window.onEscape = { [weak self] in
            guard let self, model.mode == .preview else { return false }
            window.performClose(nil)
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
            windowButtons: WindowButtons(
                close: { [weak self] in self?.window?.performClose(nil) },
                minimize: { [weak self] in self?.window?.miniaturize(nil) },
                zoom: { [weak self] in
                    // Like the system's green button: full screen, ⌥-click zooms instead.
                    if NSEvent.modifierFlags.contains(.option) { self?.window?.performZoom(nil) } else { self?.window?.toggleFullScreen(nil) }
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

    /// Brings the window in front of whatever app the capture was taken over. A menu-bar
    /// app may be refused activation right after a global hotkey, so the window is
    /// floated above everything until it actually becomes key, then dropped back to normal.
    func present() {
        guard let window else { return }
        showWindow(nil)
        window.level = .floating
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.level = .normal
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.level = .normal
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
        onClose?()
        window?.close()
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

    @objc func save() {
        model.endTextEditing()
        guard let image = model.renderedImage() else { return }
        library.replaceImage(of: item, with: image)
        model.markSaved()
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
    @objc func zoomIn(_ sender: Any?) { model.zoomCommand = .zoomIn }
    @objc func zoomOut(_ sender: Any?) { model.zoomCommand = .zoomOut }
    @objc func zoomToFit(_ sender: Any?) { model.zoomCommand = .fit }
    @objc func zoomActualSize(_ sender: Any?) { model.zoomCommand = .actualSize }

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
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Lets the controller intercept ⎋ before AppKit's default beep.
final class EditorWindow: NSWindow {
    var onEscape: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, onEscape?() == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        super.cancelOperation(sender)
    }
}
