import os
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let shortcuts = ShortcutController()
    let library = CaptureLibrary()
    let clipboard = ClipboardHistory()
    let assets = AssetStore()
    let colors = ColorStore()
    let tasks = TaskStore()
    private var prayerClock: PrayerClock?
    let preferences = AppPreferences()
    private lazy var coordinator = CaptureCoordinator(shortcuts: shortcuts)

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var floatingPanel: FloatingPanelWindow?
    private var island: IslandController?
    private var quickTaskPanel: QuickTaskPanel?
    private var clipboardPanel: FloatingPanelWindow?
    private var clipboardPanelObserver: (any NSObjectProtocol)?

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
        coordinator.onColorPicked = { [weak self] color in self?.handlePickedColor(color) }
        applyIslandPreference()
        applyClipboardPreference()

        shortcuts.setAction(for: .fullScreen) { [weak self] in self?.coordinator.captureFullScreen(fromMenu: false) }
        shortcuts.setAction(for: .region) { [weak self] in self?.coordinator.captureArea(fromMenu: false) }
        shortcuts.setAction(for: .scrolling) { [weak self] in self?.coordinator.captureScrolling(fromMenu: false) }
        shortcuts.setAction(for: .showPanel) { [weak self] in self?.toggleHistoryAtPointer() }
        shortcuts.setAction(for: .captureText) { [weak self] in self?.coordinator.captureText(fromMenu: false) }
        shortcuts.setAction(for: .pickColor) { [weak self] in self?.pickColor(nil) }
        shortcuts.setAction(for: .quickTask) { [weak self] in self?.quickTask(nil) }
        shortcuts.setAction(for: .clipboardPanel) { [weak self] in self?.showClipboardPanel(nil) }

        let clock = PrayerClock(preferences: preferences)
        clock.showStatus = { [weak self] status, quiet in
            guard let self else { return }
            if island?.showStatus(status, quiet: quiet) != true, island == nil {
                FeedbackHUD.show(status.title, symbol: status.symbol, duration: status.duration, subtitle: status.subtitle)
            }
        }
        prayerClock = clock

        // Diagnostics: `--env KLIK_DEBUG_HOTKEYS=1` writes every shortcut and its status to Pictures/Klik.
        if ProcessInfo.processInfo.environment["KLIK_DEBUG_HOTKEYS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                let lines = HotkeyID.configurable.map { id -> String in
                    let entry = shortcuts.entries[id]
                    return "\(id): \(entry?.hotkey?.displayString ?? "none") keyCode=\(entry?.hotkey?.keyCode ?? 0) mods=\(entry?.hotkey?.modifiers ?? 0) status=\(String(describing: entry?.status))"
                }
                let url = CaptureLibrary.defaultFolder().appendingPathComponent("_hotkeys.txt")
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
        // Diagnostics: `open Klik.app --env KLIK_DEBUG_PANEL=1` opens the floating panel at launch.
        if ProcessInfo.processInfo.environment["KLIK_DEBUG_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.toggleHistoryAtPointer() }
        }
        if !PermissionManager.hasScreenCaptureAccess {
            Log.app.notice("Screen Recording not granted; showing onboarding")
            showOnboarding(for: .screenRecording)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissionState()
    }

    // MARK: - Status item

    /// The menu bar item is a plain dropdown — Settings and Quit. Everything else
    /// lives in the Dynamic Island, the floating panel (⌥⇧K) and the shortcuts.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.addItem(makeItem("Settings…", #selector(showSettings(_:)), keyEquivalent: ",", modifiers: .command))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Klik", #selector(NSApplication.terminate(_:)), keyEquivalent: "q", modifiers: .command))
        item.menu = menu
        statusItem = item
        statusMenu = menu
        applyMenuBarIcon()
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

    // MARK: - Dynamic Island

    /// Creates or removes the island as the Settings toggles change.
    private func applyIslandPreference() {
        // Only the two preferences are tracked: the island's own model must not be, or
        // its every change (a tab widening the panel) would re-place it closed.
        let enabled = withObservationTracking {
            _ = preferences.dynamicIslandOnPlainDisplays
            return preferences.dynamicIslandEnabled
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyIslandPreference() }
        }
        if enabled {
            if let island {
                island.place()
            } else {
                island = IslandController(library: library, clipboard: clipboard, assets: assets, colors: colors, tasks: tasks, actions: historyActions, preferences: preferences, clock: prayerClock)
                library.warmThumbnails()
                FeedbackHUD.island = { [weak self] status in self?.island?.showStatus(status) ?? false }
            }
        } else if let island {
            island.tearDown()
            self.island = nil
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

    // MARK: - Panels

    private func closeHistory() {
        floatingPanel?.close()
        clipboardPanel?.close()
        island?.collapse(animated: false)
    }

    /// The floating Klik panel at the pointer (⌥⇧K by default): the island's content
    /// as a movable glass window that scrolls vertically, as a grid or a list.
    private func toggleHistoryAtPointer() {
        if let panel = floatingPanel, panel.isVisible {
            panel.close()
            return
        }
        closeHistory()
        let content = FloatingPanelView(
            library: library, clipboard: clipboard, assets: assets, colors: colors, tasksStore: tasks, actions: historyActions,
            onPrompt: { [weak self] prompt in self?.promptFromFloatingPanel(prompt) },
            onShowTask: { [weak self] task in self?.floatingPanel?.close(); self?.island?.showTask(task) }
        )
        .environment(preferences)
        let panel = FloatingPanelWindow(rootView: content)
        floatingPanel = panel
        panel.show(at: NSEvent.mouseLocation, position: preferences.panelPosition)
    }

    /// The clipboard history alone (⌘⇧C by default): a list to pick from by keyboard.
    @objc func showClipboardPanel(_ sender: Any?) {
        if let panel = clipboardPanel, panel.isVisible {
            panel.close()
            return
        }
        closeHistory()
        // Klik takes activation for the panel (invisibly — it has no menu bar or Dock
        // icon) so that handing it back afterwards restores the other app's key
        // window and the cursor in its field; a non-activating panel would leave the
        // field unfocused when it closed.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let content = ClipboardPanelView(clipboard: clipboard, close: { [weak self] in self?.clipboardPanel?.close() },
                                         onNeedsAccessibility: { [weak self] in self?.showOnboarding(for: .accessibility) },
                                         frontApp: frontApp)
            .environment(preferences)
        let panel = FloatingPanelWindow(rootView: content, size: ClipboardPanelView.size)
        clipboardPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.show(at: NSEvent.mouseLocation, position: preferences.panelPosition)
        // Whatever closes the panel (⎋, a click outside, a pick), the other app gets
        // activation back so the user is where they were.
        if let observer = clipboardPanelObserver { NotificationCenter.default.removeObserver(observer) }
        clipboardPanelObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, let observer = self.clipboardPanelObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.clipboardPanelObserver = nil
                }
                if let frontApp, frontApp != .current { ClipboardHistory.activate(frontApp) }
            }
        }
    }

    /// Creation and renaming from the floating panel go through the island's compact
    /// box; without the island, tasks fall back to the floating task form.
    private func promptFromFloatingPanel(_ prompt: IslandPrompt) {
        floatingPanel?.close()
        if let island {
            island.prompt(prompt)
        } else if case .task = prompt.kind {
            quickTask(nil)
        } else if case .delete(let deletion) = prompt.kind {
            confirmWithAlert(prompt, deletion)
        }
    }

    /// Without an island to ask in, a plain alert confirms a deletion.
    private func confirmWithAlert(_ prompt: IslandPrompt, _ deletion: TaskDeletion) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.detail(tasks)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let done = tasks.delete(deletion)
        FeedbackHUD.show(done.title, symbol: "trash.fill", subtitle: done.subtitle)
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
                FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: item.dimensions, image: self?.library.thumbnail(for: item))
            },
            delete: { [weak self] item in self?.deleteCapture(item) }
        )
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

    /// The pixel picker. The picked color is listed under Colors in the island and
    /// copied in the preferred format.
    @objc func pickColor(_ sender: Any?) {
        closeHistory()
        coordinator.pickColor(fromMenu: sender is NSMenuItem)
    }

    private func handlePickedColor(_ color: PickedColor) {
        let entry = colors.add(color)
        let format = preferences.colorFormat
        colors.copy(entry, as: format)
        UserDefaults.standard.set(IslandTab.colors.rawValue, forKey: IslandTab.storageKey) // the island opens on the new color
        FeedbackHUD.show("\(format.string(for: entry.color)) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.6),
                         subtitle: ColorFormat.oklch.string(for: entry.color), swatch: entry.color)
    }

    /// A floating "new task" form at the pointer (⌥/ by default).
    @objc func quickTask(_ sender: Any?) {
        if let panel = quickTaskPanel, panel.isVisible {
            panel.close()
            return
        }
        closeHistory()
        let panel = QuickTaskPanel(store: tasks) { [weak self] answer in
            guard let self, let answer else { return }
            tasks.addTask(titled: answer.title, notes: answer.notes, in: answer.projectID, priority: answer.priority)
            FeedbackHUD.show("Task added", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
        }
        quickTaskPanel = panel
        // Island cards pasted while the form is open land in its description.
        clipboard.openEditor = { [weak self] in
            guard let panel = self?.quickTaskPanel, panel.isVisible else { return nil }
            return panel.editor
        }
        panel.show(at: NSEvent.mouseLocation, position: preferences.panelPosition)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let controller = SettingsWindowController(model: model, shortcuts: shortcuts, library: library, clipboard: clipboard, preferences: preferences, clock: prayerClock)
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
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Something went wrong"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
