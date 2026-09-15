import os
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    let shortcuts = ShortcutController()
    let library = CaptureLibrary()
    let clipboard = ClipboardHistory()
    let assets = AssetStore()
    let colors = ColorStore()
    let tasks = TaskStore()
    let preferences = AppPreferences()
    private lazy var coordinator = CaptureCoordinator(shortcuts: shortcuts)

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var historyPopover: NSPopover?
    private var historyDismissMonitors: [Any] = []
    private var historyPanel: HistoryPanelWindow?
    private var island: IslandController?
    private var captureMenuItems: [HotkeyID: NSMenuItem] = [:]

    private var settingsWindow: SettingsWindowController?
    private var onboardingWindows: [PermissionKind: HostedWindowController] = [:]
    private var editorWindows: [UUID: EditorWindowController] = [:]

    // MARK: - Lifecycle

    func applicationWillTerminate(_ notification: Notification) {
        Clipboard.resolvePromises()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(target: self)
        preferences.applyAppearance()
        // Alerts, onboarding and the About pane all draw the brand icon from the asset
        // catalog, independent of the icon-services cache for this bundle path.
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
        installStatusItem()

        coordinator.onCaptured = { [weak self] image in self?.handleCapture(image) }
        coordinator.onTextRecognized = { [weak self] text in self?.handleRecognizedText(text) }
        coordinator.onPermissionRequired = { [weak self] kind in self?.showOnboarding(for: kind) }
        coordinator.onError = { [weak self] error in self?.presentError(error) }
        coordinator.onBusyChanged = { [weak self] busy in self?.island?.setHidden(busy) }
        applyIslandPreference()
        applyClipboardPreference()

        shortcuts.setAction(for: .fullScreen) { [weak self] in self?.coordinator.captureFullScreen(fromMenu: false) }
        shortcuts.setAction(for: .region) { [weak self] in self?.coordinator.captureArea(fromMenu: false) }
        shortcuts.setAction(for: .scrolling) { [weak self] in self?.coordinator.captureScrolling(fromMenu: false) }
        shortcuts.setAction(for: .showPanel) { [weak self] in self?.toggleHistoryAtPointer() }
        shortcuts.setAction(for: .captureText) { [weak self] in self?.coordinator.captureText(fromMenu: false) }
        shortcuts.setAction(for: .pickColor) { [weak self] in self?.pickColor(nil) }

        if !PermissionManager.hasScreenCaptureAccess {
            Log.app.notice("Screen Recording not granted; showing onboarding")
            showOnboarding(for: .screenRecording)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissionState()
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        applyMenuBarIcon()

        let menu = NSMenu()
        menu.delegate = self
        captureMenuItems[.fullScreen] = addItem(makeItem("Capture Full Screen", #selector(captureFullScreen(_:))), to: menu)
        captureMenuItems[.region] = addItem(makeItem("Capture Area", #selector(captureArea(_:))), to: menu)
        captureMenuItems[.scrolling] = addItem(makeItem("Scrolling Capture", #selector(captureScrolling(_:))), to: menu)
        captureMenuItems[.captureText] = addItem(makeItem("Capture Text", #selector(captureText(_:))), to: menu)
        captureMenuItems[.pickColor] = addItem(makeItem("Pick Color", #selector(pickColor(_:))), to: menu)
        menu.addItem(.separator())
        menu.addItem(makeItem("Show Captures", #selector(showHistory(_:))))
        menu.addItem(makeItem("Settings…", #selector(showSettings(_:)), keyEquivalent: ",", modifiers: .command))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Klik", #selector(NSApplication.terminate(_:)), keyEquivalent: "q", modifiers: .command))
        statusMenu = menu
        refreshMenuShortcuts()
    }

    /// Keeps the status item image in sync with the Settings choice.
    private func applyMenuBarIcon() {
        withObservationTracking {
            statusItem?.button?.image = preferences.menuBarImage()
                ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Klik")
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyMenuBarIcon() }
        }
    }

    /// Left click opens the capture history; right click shows the quick menu.
    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp, let statusMenu, let item = statusItem {
            item.menu = statusMenu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            toggleHistory()
        }
    }

    private func addItem(_ item: NSMenuItem, to menu: NSMenu) -> NSMenuItem {
        menu.addItem(item)
        return item
    }

    private func makeItem(
        _ title: String,
        _ action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        // Only our own actions target the delegate; app-level ones (Quit) go to NSApp.
        item.target = responds(to: action) ? self : NSApp
        return item
    }

    /// Mirrors the current bindings next to the menu items (display only — the
    /// global shortcuts themselves are handled by `ShortcutController`).
    private func refreshMenuShortcuts() {
        for (id, item) in captureMenuItems {
            if let hotkey = shortcuts.hotkey(for: id) {
                item.keyEquivalent = hotkey.menuKeyEquivalent
                item.keyEquivalentModifierMask = hotkey.menuModifierMask
            } else {
                item.keyEquivalent = ""
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuShortcuts()
    }

    // MARK: - Dynamic Island

    /// Creates or removes the island as the Settings toggles change.
    private func applyIslandPreference() {
        withObservationTracking {
            if preferences.dynamicIslandEnabled {
                if let island {
                    island.place()
                } else {
                    island = IslandController(library: library, clipboard: clipboard, assets: assets, colors: colors, tasks: tasks, actions: historyActions, preferences: preferences)
                    library.warmThumbnails()
                }
            } else if let island {
                island.tearDown()
                self.island = nil
            }
            _ = preferences.dynamicIslandOnPlainDisplays
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyIslandPreference() }
        }
    }

    /// Starts or stops recording the pasteboard as the Settings toggles change.
    private func applyClipboardPreference() {
        withObservationTracking {
            clipboard.limit = preferences.clipboardHistoryLimit
            if preferences.clipboardHistoryEnabled {
                clipboard.startWatching()
            } else {
                clipboard.stopWatching()
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyClipboardPreference() }
        }
    }

    // MARK: - History popover

    private func toggleHistory() {
        if let popover = historyPopover, popover.isShown {
            closeHistory()
            return
        }
        showHistory(nil)
    }

    @objc func showHistory(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        let popover = historyPopover ?? makeHistoryPopover()
        historyPopover = popover
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installHistoryDismissMonitors()
    }

    /// A transient popover from a menu-bar-only app does not reliably close when the
    /// click lands in another app, so watch for outside clicks and ⎋ ourselves.
    private func installHistoryDismissMonitors() {
        removeHistoryDismissMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closeHistory() }
        }) {
            historyDismissMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self, let popover = self.historyPopover, popover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.closeHistory(); return nil }
                return event
            }
            // Clicks inside the popover (or on the status item, which toggles) pass through.
            if event.window === popover.contentViewController?.view.window || event.window === self.statusItem?.button?.window {
                return event
            }
            self.closeHistory()
            return event
        }) {
            historyDismissMonitors.append(local)
        }
    }

    private func removeHistoryDismissMonitors() {
        historyDismissMonitors.forEach { NSEvent.removeMonitor($0) }
        historyDismissMonitors.removeAll()
    }

    private func closeHistory() {
        removeHistoryDismissMonitors()
        historyPopover?.performClose(nil)
        historyPanel?.close()
        island?.collapse(animated: false)
    }

    /// ⌥V: the same panel, floating at the mouse pointer instead of under the menu bar.
    private func toggleHistoryAtPointer() {
        if let panel = historyPanel, panel.isVisible {
            panel.close()
            return
        }
        closeHistory()
        let panel = historyPanel ?? HistoryPanelWindow(rootView: HistoryView(library: library, actions: historyActions))
        historyPanel = panel
        panel.show(at: NSEvent.mouseLocation)
    }

    private var historyActions: HistoryActions {
        HistoryActions(
            captureFullScreen: { [weak self] in self?.closeHistoryThen { $0.coordinator.captureFullScreen(fromMenu: true) } },
            captureArea: { [weak self] in self?.closeHistoryThen { $0.coordinator.captureArea(fromMenu: true) } },
            captureScrolling: { [weak self] in self?.closeHistoryThen { $0.coordinator.captureScrolling(fromMenu: true) } },
            captureText: { [weak self] in self?.closeHistoryThen { $0.coordinator.captureText(fromMenu: true) } },
            pickColor: { [weak self] in self?.closeHistoryThen { $0.pickColor(nil) } },
            openSettings: { [weak self] in self?.closeHistoryThen { $0.showSettings(nil) } },
            quit: { NSApp.terminate(nil) },
            preview: { [weak self] item in self?.closeHistoryThen { $0.openEditor(for: item, mode: .preview) } },
            edit: { [weak self] item in self?.closeHistoryThen { $0.openEditor(for: item, mode: .edit) } },
            copy: { [weak self] item in
                self?.library.copyToClipboard(item)
                FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
            },
            delete: { [weak self] item in self?.deleteCapture(item) }
        )
    }

    private func makeHistoryPopover() -> NSPopover {
        let host = NSHostingController(rootView: HistoryView(library: library, actions: historyActions))
        host.sizingOptions = []
        host.preferredContentSize = HistoryView.size
        host.view.frame = CGRect(origin: .zero, size: HistoryView.size)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = host
        popover.contentSize = HistoryView.size
        return popover
    }

    private func closeHistoryThen(_ action: @escaping (AppDelegate) -> Void) {
        closeHistory()
        Task { @MainActor [weak self] in
            guard let self else { return }
            action(self)
        }
    }

    // MARK: - Actions

    @objc func captureFullScreen(_ sender: Any?) {
        coordinator.captureFullScreen(fromMenu: sender is NSMenuItem)
    }

    @objc func captureArea(_ sender: Any?) {
        coordinator.captureArea(fromMenu: sender is NSMenuItem)
    }

    @objc func captureScrolling(_ sender: Any?) {
        coordinator.captureScrolling(fromMenu: sender is NSMenuItem)
    }

    @objc func captureText(_ sender: Any?) {
        coordinator.captureText(fromMenu: sender is NSMenuItem)
    }

    /// The eyedropper. The picked colour is listed under Colours in the island and
    /// copied in the preferred format.
    @objc func pickColor(_ sender: Any?) {
        closeHistory()
        colors.pick { [weak self] entry in
            guard let self, let entry else { return }
            let format = preferences.colorFormat
            colors.copy(entry, as: format)
            FeedbackHUD.show("\(format.string(for: entry.color)) copied", symbol: "eyedropper.halffull", duration: .seconds(1.6))
            island?.flashColor(entry)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let controller = SettingsWindowController(model: model, shortcuts: shortcuts, library: library, clipboard: clipboard, preferences: preferences)
            controller.onClose = { [weak self] in
                self?.settingsWindow = nil
                self?.shortcuts.isRecording = false
            }
            settingsWindow = controller
        }
        model.refreshPermissionState()
        settingsWindow?.present()
    }

    // MARK: - Captures

    private func handleCapture(_ image: CapturedImage) {
        // Clipboard first (a promise, instant), then the library lists it and writes the
        // file in the background, then the editor opens — nothing waits for the disk.
        Clipboard.copy(image.cgImage)
        preferences.playCaptureSound()
        let item = library.add(image)
        Log.app.info("Captured \(item.fileName, privacy: .public) → clipboard + library")
        island?.flash(item)
        openEditor(for: item, image: image, mode: .edit)
    }

    /// Preview and edit share one window per capture; asking to edit an open preview
    /// switches it, asking to preview an open editor just brings it forward.
    private func openEditor(for item: CaptureItem, image: CapturedImage? = nil, mode: EditorMode) {
        if let existing = editorWindows[item.id] {
            if mode == .edit { existing.enterEditMode() }
            existing.present()
            return
        }
        guard let image = image ?? library.image(for: item) else {
            presentError(NSError(domain: "Klik", code: 2, userInfo: [NSLocalizedDescriptionKey: "The capture file could not be opened."]))
            return
        }
        // Decoding the wallpaper thumbnails costs seconds of CPU, so it waits for the
        // first editor rather than running at every login; it's done long before the
        // Background tool is reached, and a no-op once cached.
        Task(priority: .utility) { await WallpaperStore.shared.prepareThumbnails() }
        let controller = EditorWindowController(item: item, image: image, library: library, preferences: preferences, mode: mode)
        controller.onClose = { [weak self] in self?.editorWindows[item.id] = nil }
        controller.onDelete = { [weak self] item in self?.library.delete(item) }
        editorWindows[item.id] = controller
        controller.present()
    }

    /// Capture Text: clipboard only, never the library. The text itself is not logged.
    private func handleRecognizedText(_ recognized: RecognizedText) {
        guard !recognized.isEmpty else {
            FeedbackHUD.show("No text detected", symbol: "text.viewfinder")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(recognized.text, forType: .string)
        preferences.playCaptureSound()
        FeedbackHUD.show("Text copied", symbol: "checkmark.circle.fill")
    }

    private func deleteCapture(_ item: CaptureItem) {
        editorWindows[item.id]?.forceClose()
        library.delete(item)
    }

    // MARK: - Windows

    private func showOnboarding(for kind: PermissionKind) {
        if onboardingWindows[kind] == nil {
            let controller = HostedWindowController(
                title: "Welcome to Klik",
                contentSize: CGSize(width: 460, height: 420),
                styleMask: [.titled, .closable],
                rootView: OnboardingView(kind: kind) { [weak self] in
                    self?.onboardingWindows[kind]?.close()
                }
            )
            controller.onClose = { [weak self] in
                self?.onboardingWindows[kind] = nil
                self?.model.refreshPermissionState()
            }
            onboardingWindows[kind] = controller
        }
        onboardingWindows[kind]?.present()
    }

    private func presentError(_ error: any Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Something went wrong"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
