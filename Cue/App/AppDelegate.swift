import Carbon.HIToolbox
import os
import AppKit
import BackgroundKit
import RecordKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    let shortcuts = ShortcutController()
    let library = CaptureLibrary()
    let clipboard = ClipboardHistory()
    let assets = AssetStore()
    let colors = ColorStore()
    let groups = GroupStore()
    let tasks = TaskStore()
    /// The remote server and webhooks for tasks (Settings › Tasks).
    private lazy var taskSync = TaskSync(store: tasks, preferences: preferences)
    let snippets = SnippetStore()
    let notes = NoteStore()
    private var snippetExpander: SnippetExpander?
    /// The app a snippet keyword was typed in, while its blanks are being filled.
    private var snippetFrontField: FrontField?
    private var prayerClock: PrayerClock?
    let preferences = AppPreferences()
    /// The floating basket, shaken up while dragging files.
    private lazy var basket = BasketController(preferences: preferences)
    /// The recognisers Capture Text can use, and the language packs behind them.
    private lazy var ocrEngines = OCREngines(preferences: preferences)
    /// Screen recording and the video editor.
    let studio = StudioController()
    /// The settings and service `CueApp` makes for the menu bar, handed over for `studio`.
    static var studioHandOff: (settings: StudioSettings, studio: StudioService)?
    private lazy var coordinator = CaptureCoordinator(shortcuts: shortcuts, preferences: preferences, engines: ocrEngines)

    private var statusItem: NSStatusItem?
    /// Blinks the mark in the menu bar, when the mark is what is shown there.
    private var markBlinker: MarkBlinker?
    private var statusMenu: NSMenu?
    private var floatingPanel: FloatingPanelWindow?
    private var island: IslandController?
    private var quickTaskPanel: QuickTaskPanel?
    private var clipboardPanel: FloatingPanelWindow?
    private var clipboardPanelObserver: (any NSObjectProtocol)?
    private var commandPalette: FloatingPanelWindow?
    private let share = ShareSettings()
    private let focusTimer = FocusTimer()
    let syncFolder = SyncFolder()
    private var commandPaletteObserver: (any NSObjectProtocol)?
    /// Claude Code and Codex sessions, shown and answered on the island.
    private let agentStore = AgentStore()
    private lazy var agentConnector = AgentConnector(store: agentStore)
    /// Puts the keyboard back in Cue's window when the user returns to its Space.
    private let spaceFocus = SpaceFocusKeeper()
    /// The task list for AI agents, over MCP (Settings › Tasks).
    private lazy var taskMCP = TaskMCPController(tasks: tasks, preferences: preferences)

    private var settingsWindow: SettingsWindowController?
    private var taskDashboard: TaskDashboardWindowController?
    private var onboardingWindows: [PermissionKind: HostedWindowController] = [:]
    private var editorWindows: [UUID: EditorWindowController] = [:]

    // MARK: - Lifecycle

    func applicationWillTerminate(_ notification: Notification) {
        Clipboard.resolvePromises()
        agentConnector.tearDown() // waiting agents ask in their terminals again
        taskMCP.tearDown()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One Cue at a time. A second copy (the installed app started by `cue-mcp` while a
        // development build restarts, say) would draw a second island over the first and
        // fight it for the sockets. It leaves before setting anything up, and without
        // `terminate`, whose teardown would remove the running copy's sockets.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        if !others.isEmpty { exit(0) }
        // Before anything a launch was asked to open: `cue://settings` arrives ahead of
        // didFinishLaunching, and its recording pages need the recorder's settings.
        if let handOff = Self.studioHandOff {
            studio.start(settings: handOff.settings, studio: handOff.studio)
        }
        studio.showSettings = { [weak self] page in
            self?.showSettings(nil)
            self?.settingsWindow?.present(SettingsSection(page ?? .general))
        }
        // A video editor needs the menu bar, so Cue keeps a Dock tile while one is open.
        studio.onEditorsChange = { [weak self] in
            guard let self else { return }
            preferences.keepsDock = !studio.editors.isEmpty
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.applyAppearance()
        // The bundle launches as an agent; the preference decides whether Cue takes
        // a Dock tile, so it can be turned off without reinstalling.
        preferences.applyDockVisibility()
        // Alerts, onboarding and the About pane all draw the brand icon from the asset
        // catalog, independent of the icon-services cache for this bundle path.
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
        installStatusItem()
        AppUpdater.shared.start()
        spaceFocus.start()
        _ = taskSync // listens for task changes from now on
        taskMCP.apply()

        coordinator.onCaptured = { [weak self] image in self?.handleCapture(image) }
        coordinator.onTextRecognized = { [weak self] text in self?.handleRecognizedText(text) }
        coordinator.onTextUnavailable = { [weak self] reason in self?.handleTextUnavailable(reason) }
        coordinator.onPermissionRequired = { [weak self] kind in self?.showOnboarding(for: kind) }
        coordinator.onError = { [weak self] error in self?.presentError(error) }
        coordinator.onBusyChanged = { [weak self] busy in self?.island?.setHidden(busy) }
        coordinator.onColorPicked = { [weak self] color in self?.handlePickedColor(color) }

        applySyncFolder()
        focusTimer.announce = { [weak self] status in
            guard let self else { return }
            if island?.showStatus(status, quiet: false) != true, island == nil {
                FeedbackHUD.show(status.title, symbol: status.symbol, duration: status.duration, subtitle: status.subtitle)
            }
        }
        // Before the island, which shows the clock's statuses and its pill.
        let clock = PrayerClock(preferences: preferences)
        clock.showStatus = { [weak self] status, quiet in
            guard let self else { return }
            if island?.showStatus(status, quiet: quiet) != true, island == nil {
                FeedbackHUD.show(status.title, symbol: status.symbol, duration: status.duration, subtitle: status.subtitle)
            }
        }
        prayerClock = clock
        // Questions are only held for the island; without it they go back to the terminal.
        agentStore.canAsk = { [weak self] in
            guard let self else { return false }
            return island != nil && preferences.agentSessionsEnabled
        }
        applyIslandPreference()
        applyAgentPreference()
        applyClipboardPreference()
        basket.start()

        let expander = SnippetExpander(store: snippets, assets: assets, preferences: preferences)
        expander.askToFill = { [weak self] snippet, field in self?.fillSnippet(snippet, from: field) }
        snippetExpander = expander

        shortcuts.setAction(for: .fullScreen) { [weak self] in self?.coordinator.captureFullScreen(fromMenu: false) }
        shortcuts.setAction(for: .region) { [weak self] in self?.coordinator.captureArea(fromMenu: false) }
        shortcuts.setAction(for: .scrolling) { [weak self] in self?.coordinator.captureScrolling(fromMenu: false) }
        shortcuts.setAction(for: .showPanel) { [weak self] in self?.toggleHistoryAtPointer() }
        shortcuts.setAction(for: .captureText) { [weak self] in self?.coordinator.captureText(fromMenu: false) }
        shortcuts.setAction(for: .pickColor) { [weak self] in self?.pickColor(nil) }
        shortcuts.setAction(for: .quickTask) { [weak self] in self?.quickTask(nil) }
        shortcuts.setAction(for: .quickNote) { [weak self] in self?.quickNote(nil) }
        shortcuts.setAction(for: .clipboardPanel) { [weak self] in self?.showClipboardPanel(nil) }
        shortcuts.setAction(for: .commandPalette) { [weak self] in self?.showCommandPalette(nil) }
        shortcuts.setAction(for: .pasteNext) { [weak self] in self?.pasteNext() }
        shortcuts.setAction(for: .window) { [weak self] in self?.coordinator.captureWindow(fromMenu: false) }

        // Diagnostics: `--env CUE_DEBUG_HOTKEYS=1` writes every shortcut and its status to Pictures/Cue.
        if ProcessInfo.processInfo.environment["CUE_DEBUG_HOTKEYS"] == "1" {
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
        // Tooling: `open Cue.app --env CUE_IMPORT_TASKS='[{"project":…,"title":…}]'` adds tasks at launch.
        if let json = ProcessInfo.processInfo.environment["CUE_IMPORT_TASKS"], let data = json.data(using: .utf8) {
            let added = tasks.importTasks(from: data)
            Log.app.notice("Imported \(added) task(s)")
        }
        // Tooling: `--env CUE_COMPLETE_TASKS='["Title one","Title two"]'` marks tasks complete by title prefix.
        if let json = ProcessInfo.processInfo.environment["CUE_COMPLETE_TASKS"], let data = json.data(using: .utf8),
           let titles = try? JSONDecoder().decode([String].self, from: data) {
            let done = tasks.setStatus(.complete, forTitlesStartingWith: titles)
            Log.app.notice("Completed \(done) task(s)")
        }
        // Diagnostics: `--env CUE_DEBUG_SETTINGS_SHOT=general` opens Settings on that page and
        // writes a picture of the window to Pictures/Cue/_settings-<page>.png.
        if let page = ProcessInfo.processInfo.environment["CUE_DEBUG_SETTINGS_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                showSettings(nil)
                settingsWindow?.present(SettingsSection(rawValue: page))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, let window = self.settingsWindow?.window, let screen = window.screen else { return }
                    let rect = window.frame.insetBy(dx: -24, dy: -24)
                    Task { @MainActor in
                        do {
                            // The screen around the window rather than the window alone,
                            // so its glass is seen over the desktop as it really is.
                            let image = try await ScreenCaptureService().captureRegionIncludingCue(rect, on: screen)
                            guard let png = ImageEncoding.png(image) else { return }
                            try png.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_settings-\(page).png"))
                            Log.app.notice("Settings shot written")
                        } catch {
                            Log.app.error("Settings shot failed: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
            }
        }
        // Diagnostics: `--env CUE_DEBUG_LINK=<url>` fetches the link's preview metadata and
        // writes what came back to Pictures/Cue/_link.txt.
        if let spec = ProcessInfo.processInfo.environment["CUE_DEBUG_LINK"], let url = URL(string: spec) {
            Task { @MainActor in
                let start = Date.now
                let metadata = await LinkMetadata.fetch(url)
                let report = """
                url: \(url.absoluteString)
                took: \(Int(Date.now.timeIntervalSince(start) * 1000)) ms
                title: \(metadata?.title ?? "nil")
                description: \(metadata?.description ?? "nil")
                image: \(metadata?.imageData?.count ?? 0) bytes, decodes: \(metadata?.imageData.flatMap { NSImage(data: $0) } != nil)
                video: \(metadata?.isVideo ?? false)
                """
                try? report.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_link.txt"), atomically: true, encoding: .utf8)
            }
        }
        // Diagnostics: `--env CUE_DEBUG_CLIPBOARD_ROUNDTRIP=1` puts the newest clipboard entry
        // back on the pasteboard after 5 s and lists the pasteboard's types before and after
        // in Pictures/Cue/_roundtrip.txt.
        if ProcessInfo.processInfo.environment["CUE_DEBUG_CLIPBOARD_ROUNDTRIP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                func types() -> String {
                    (NSPasteboard.general.pasteboardItems ?? []).enumerated().map { index, item in
                        "item \(index): " + item.types.map { "\($0.rawValue) (\(item.data(forType: $0)?.count ?? 0) B)" }.joined(separator: ", ")
                    }.joined(separator: "\n")
                }
                var report = "BEFORE\n" + types() + "\n"
                if let newest = clipboard.items.first {
                    report += "\nNEWEST \(newest.kind) \(newest.title.prefix(60))\n"
                    clipboard.copy(newest, promote: false)
                    report += "\nAFTER\n" + types() + "\n"
                }
                try? report.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_roundtrip.txt"), atomically: true, encoding: .utf8)
            }
        }
        // Diagnostics: `--env CUE_DEBUG_CLIPBOARD_PASTE=1` (with a text document in front)
        // brings up the clipboard list, presses ↩ (the top entry pastes into the document),
        // then ⌘A ⌘C — `pbpaste` then shows whether the paste landed.
        if ProcessInfo.processInfo.environment["CUE_DEBUG_CLIPBOARD_PASTE"] == "1" {
            func state(_ step: String) {
                Log.app.notice("Paste test \(step, privacy: .public): responder \(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "-", privacy: .public), front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-", privacy: .public), active \(NSApp.isActive), key \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none", privacy: .public)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                state("before")
                self?.showClipboardPanel(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    state("panel up")
                    // A picture of the list first, to Pictures/Cue/_clip.png.
                    if let window = self?.clipboardPanel, let screen = window.screen {
                        Task { @MainActor in
                            if let image = try? await ScreenCaptureService().captureRegionIncludingCue(window.frame, on: screen), let png = ImageEncoding.png(image) {
                                try? png.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_clip.png"))
                            }
                            Self.debugPress(CGKeyCode(kVK_Return), flags: [])
                        }
                        return
                    }
                    Self.debugPress(CGKeyCode(kVK_Return), flags: [])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        state("after return")
                        // ⌘A ⌘C: the document's text lands on the pasteboard for `pbpaste`.
                        Self.debugPress(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.debugPress(CGKeyCode(kVK_ANSI_C), flags: .maskCommand) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            guard let screen = NSScreen.main else { return }
                            Task { @MainActor in
                                if let image = try? await ScreenCaptureService().captureRegionIncludingCue(screen.frame, on: screen), let png = ImageEncoding.png(image) {
                                    try? png.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_paste.png"))
                                }
                                Log.app.notice("Clipboard paste test done")
                            }
                        }
                    }
                }
            }
        }
        // Diagnostics: `--env CUE_DEBUG_NOTE_SCRIPT=1` compiles (does not run) the Apple Notes
        // script for a sample note and logs the outcome.
        if ProcessInfo.processInfo.environment["CUE_DEBUG_NOTE_SCRIPT"] == "1" {
            let sample = Note(id: "Sample", text: "Sample \"note\"\n\n- one **two**\n- [ ] three\n\n> quote", createdAt: .now, updatedAt: .now)
            for folder in ["Cue", ""] {
                var error: NSDictionary?
                let compiled = NSAppleScript(source: NoteSharing.appleNotesScript(sample, folder: folder))?.compileAndReturnError(&error) ?? false
                Log.app.notice("Notes script (folder \(folder.isEmpty ? "none" : folder, privacy: .public)): \(compiled ? "compiles" : "does not compile", privacy: .public) \(String(describing: error ?? [:]), privacy: .public)")
            }
        }
        // Diagnostics: `--env CUE_DEBUG_EDIT_CLIPBOARD=1` opens the newest clipboard image in the editor.
        if ProcessInfo.processInfo.environment["CUE_DEBUG_EDIT_CLIPBOARD"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let item = self.clipboard.items.first(where: { $0.kind == .image }) else { Log.app.error("No clipboard image to edit"); return }
                self.editClipboardImage(item)
            }
        }
        // Diagnostics: `--env CUE_DEBUG_TASK_SHOT=1` opens the quick task (`=note`: the
        // quick note) and writes a picture of it (the screen around it) to Pictures/Cue/_task.png.
        if let shot = ProcessInfo.processInfo.environment["CUE_DEBUG_TASK_SHOT"], shot == "1" || shot == "note" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if shot == "note" { self?.quickNote(nil) } else { self?.quickTask(nil) }
                // CUE_DEBUG_TASK_TEXT is typed into it first (a "/" brings the list up).
                if let typed = ProcessInfo.processInfo.environment["CUE_DEBUG_TASK_TEXT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let editor = self?.quickTaskPanel?.editor else { return }
                        // Typed a character at a time, so the editor's Markdown shortcuts run.
                        for character in typed {
                            switch character {
                            case "\n": editor.insertNewline(nil)
                            case "\t": editor.doCommand(by: #selector(NSResponder.insertTab(_:))) // picks a suggestion
                            default: editor.insertText(String(character), replacementRange: editor.selectedRange())
                            }
                        }
                    }
                }
                // CUE_DEBUG_TASK_CLICK=x,y clicks there, measured from the glass's top-left corner.
                if let spec = ProcessInfo.processInfo.environment["CUE_DEBUG_TASK_CLICK"] {
                    let parts = spec.split(separator: ",").compactMap { Double($0) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let panel = self?.quickTaskPanel, parts.count == 2 else { return }
                        let point = CGPoint(x: panel.frame.minX + 24 + parts[0], y: NSScreen.screens[0].frame.maxY - (panel.frame.maxY - 24 - parts[1]))
                        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                    guard let self, let panel = self.quickTaskPanel else { Log.app.error("Task shot: no panel"); return }
                    let id = CGWindowID(panel.windowNumber)
                    Task { @MainActor in
                        let service = ScreenCaptureService()
                        guard let content = try? await service.shareableContent(),
                              let image = try? await service.captureWindow(id: id, in: content, fallbackScale: 2),
                              let png = ImageEncoding.png(image.cgImage) else { Log.app.error("Task shot: no capture"); return }
                        try? png.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_task.png"))
                    }
                }
            }
        }
        // Diagnostics: `--env CUE_DEBUG_RENDER=critter` draws the pixel Cue's frames to Pictures/Cue/_render.png.
        if ProcessInfo.processInfo.environment["CUE_DEBUG_RENDER"] == "critter" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let renderer = ImageRenderer(content: CueCritter.sheet())
                renderer.scale = 2
                if let cg = renderer.cgImage, let png = ImageEncoding.png(cg) {
                    try? png.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_render.png"))
                }
            }
        }
        // Diagnostics: `--env CUE_DEBUG_RENDER=panels` draws the panel-position pictures to Pictures/Cue/_render.png.
        if ProcessInfo.processInfo.environment["CUE_DEBUG_RENDER"] == "panels" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let view = LazyVGrid(columns: Array(repeating: GridItem(.fixed(92), spacing: 12), count: 4), spacing: 12) {
                    ForEach(PanelPosition.allCases, id: \.self) { position in
                        PanelPositionPreview(position: position)
                            .frame(width: 92, height: 92 / 1.5)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                .padding(16)
                .background(Color(red: 0.1, green: 0.1, blue: 0.1))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let cg = renderer.cgImage, let png = ImageEncoding.png(cg) {
                    try? png.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_render.png"))
                }
            }
        }
        // Diagnostics: `--env CUE_DEBUG_BASKET=1` shows the basket with a few of the app's own files
        // (`empty`: with none).
        if let mode = ProcessInfo.processInfo.environment["CUE_DEBUG_BASKET"] {
            let files = ((try? FileManager.default.contentsOfDirectory(at: Bundle.main.resourceURL!, includingPropertiesForKeys: nil)) ?? []).prefix(mode == "empty" ? 0 : 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.basket.debugShow(Array(files)) }
        }
        // Diagnostics: `--env CUE_DEBUG_ISLAND_SHOT=captures` opens the island on that tab (`agents`:
        // the agent sessions; `drop`: as with a file dragged over it;
        // `dropsaved`: then as just dropped; `status`: a sample "Copied") and
        // writes a picture of it to Pictures/Cue/_island.png.
        if let tabName = ProcessInfo.processInfo.environment["CUE_DEBUG_ISLAND_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if let tab = IslandTab(rawValue: tabName) { UserDefaults.standard.set(tab.rawValue, forKey: IslandTab.storageKey) }
                switch tabName {
                case "agents": self?.island?.showAgents()
                case "level": self?.island?.debugShowLevel()
                case "agentsmedia":
                    self?.island?.nowPlaying.debugFake()
                    self?.island?.showAgents()
                case "status":
                    _ = self?.island?.showStatus(IslandStatus(symbol: "checkmark.circle.fill", title: "Copied", subtitle: "Image 148 × 116",
                                                              image: NSImage(named: "AppIcon"), duration: .seconds(6)))
                case "drop": self?.island?.debugShowDropZone()
                case "media", "mediapill", "mediablocked":
                    self?.island?.nowPlaying.debugFake(blocked: tabName == "mediablocked")
                    if tabName != "mediapill" { self?.island?.showMedia() } else { self?.island?.expand() }
                case "shelf":
                    // A few of the app's own files parked, one picked.
                    let resources = Bundle.main.resourceURL!
                    let files = ((try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []).prefix(4)
                    if let shelf = self?.island?.shelf {
                        shelf.add(fileURLs: Array(files))
                        if let first = shelf.items.first { shelf.selection = [first.id] }
                    }
                    self?.island?.expand()
                case "dropsaved":
                    self?.island?.debugShowDropZone()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.island?.debugShowDropSaved() }
                default: self?.island?.expand()
                }
                // CUE_DEBUG_ISLAND_PREVIEW=capture|clipboard|color|asset opens the tab's first
                // such item in the pane under the island; the shot then takes the screen around both.
                let previewKind = ProcessInfo.processInfo.environment["CUE_DEBUG_ISLAND_PREVIEW"]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, let island = self.island, let previewKind else { return }
                    switch previewKind {
                    case "capture": if let item = library.items.first { island.showPreview(.capture(item)) }
                    case "clipboard": if let item = clipboard.items.first(where: { $0.kind == .link }) ?? clipboard.items.first { island.showPreview(.clipboard(item)) }
                    case "color": if let entry = colors.items.first { island.showPreview(.color(entry)) }
                    case "asset": if let item = assets.items.first { island.showPreview(.asset(item)) }
                    default: break
                    }
                }
                // CUE_DEBUG_ISLAND_KEYS="right,right,left" presses those keys in the island
                // (made key first), a third of a second apart.
                if let keys = ProcessInfo.processInfo.environment["CUE_DEBUG_ISLAND_KEYS"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        self?.island?.debugMakeKey()
                        for (index, key) in keys.split(separator: ",").enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(index + 1)) {
                                let code: Int = switch key { case "left": kVK_LeftArrow; case "right": kVK_RightArrow; case "up": kVK_UpArrow; case "down": kVK_DownArrow; default: kVK_Escape }
                                Self.debugPress(CGKeyCode(code), flags: [])
                            }
                        }
                    }
                }
                // CUE_DEBUG_ISLAND_HOVER=x,y[;x,y…] moves the pointer there (a second apart),
                // measured from the open island's top-left corner, so cards are hovered.
                if let spec = ProcessInfo.processInfo.environment["CUE_DEBUG_ISLAND_HOVER"] {
                    let points = spec.split(separator: ";").map { $0.split(separator: ",").compactMap { Double($0) } }.filter { $0.count == 2 }
                    for (index, parts) in points.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + Double(index)) { [weak self] in
                            guard let island = self?.island, let screen = NSScreen.main else { return }
                            let shape = island.debugExpandedRect
                            // Cocoa (bottom-left) to Quartz (top-left) coordinates.
                            let point = CGPoint(x: shape.minX + parts[0], y: screen.frame.maxY - (shape.maxY - parts[1]))
                            for step in 0..<4 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(step)) {
                                    let jitter = CGPoint(x: point.x + Double(step), y: point.y)
                                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: jitter, mouseButton: .left)?.post(tap: .cghidEventTap)
                                }
                            }
                        }
                    }
                }
                // CUE_DEBUG_ISLAND_SHOT_DELAY overrides when the picture is taken (seconds after opening).
                let wide = previewKind != nil || ProcessInfo.processInfo.environment["CUE_DEBUG_ISLAND_KEYS"] != nil || ProcessInfo.processInfo.environment["CUE_DEBUG_ISLAND_HOVER"] != nil
                let shotDelay: Double = ProcessInfo.processInfo.environment["CUE_DEBUG_ISLAND_SHOT_DELAY"].flatMap(Double.init) ?? (wide ? 4 : 1.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + shotDelay) { [weak self] in
                    guard let self, let island = self.island else { return }
                    let id = CGWindowID(island.windowNumber)
                    Task { @MainActor in
                        let service = ScreenCaptureService()
                        if wide, let screen = NSScreen.main {
                            var rect = screen.frame
                            rect.size.height = 1000
                            rect.origin.y = screen.frame.maxY - 1000
                            guard let image = try? await service.captureRegionIncludingCue(rect, on: screen), let png = ImageEncoding.png(image) else { return }
                            try? png.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_island.png"))
                            return
                        }
                        guard let content = try? await service.shareableContent(),
                              let image = try? await service.captureWindow(id: id, in: content, fallbackScale: 2),
                              let png = ImageEncoding.png(image.cgImage) else { Log.app.error("Island shot: no capture"); return }
                        try? png.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_island.png"))
                    }
                }
            }
        }
        // Diagnostics: `--env CUE_DEBUG_ISLAND_ANIM=snippets,captures` opens the island on the
        // first tab, switches to the second, and writes frames of the change (_anim-N.png).
        if let spec = ProcessInfo.processInfo.environment["CUE_DEBUG_ISLAND_ANIM"] {
            let tabs = spec.split(separator: ",").compactMap { IslandTab(rawValue: String($0)) }
            if tabs.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    UserDefaults.standard.set(tabs[0].rawValue, forKey: IslandTab.storageKey)
                    self?.island?.expand()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self, let island = self.island else { return }
                        let id = CGWindowID(island.windowNumber)
                        if let window = NSApp.windows.first(where: { $0.windowNumber == island.windowNumber }),
                           let x = ["tasks": 277.0, "captures": 380.0, "snippets": 600.0, "colors": 500.0][tabs[1].rawValue] {
                            // A real click on the tab pill (the path the pointer takes), not a defaults change.
                            let point = CGPoint(x: window.frame.minX + x, y: NSScreen.screens[0].frame.maxY - (window.frame.maxY - 99))
                            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                            }
                        } else {
                            UserDefaults.standard.set(tabs[1].rawValue, forKey: IslandTab.storageKey)
                        }
                        for frame in 0..<6 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30 + frame * 70)) {
                                Task { @MainActor in
                                    let service = ScreenCaptureService()
                                    guard let content = try? await service.shareableContent(),
                                          let image = try? await service.captureWindow(id: id, in: content, fallbackScale: 2),
                                          let png = ImageEncoding.png(image.cgImage) else { return }
                                    try? png.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_anim-\(frame).png"))
                                }
                            }
                        }
                    }
                }
            }
        }
        // Diagnostics: `open Cue.app --env CUE_DEBUG_PANEL=1` opens the floating panel at launch.
        // With CUE_DEBUG_PANEL_SHOT=1 too, a picture of it lands in Pictures/Cue/_panel.png.
        if ProcessInfo.processInfo.environment["CUE_DEBUG_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.toggleHistoryAtPointer() }
            if ProcessInfo.processInfo.environment["CUE_DEBUG_PANEL_SHOT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let panel = self?.floatingPanel else { return }
                    let id = CGWindowID(panel.windowNumber)
                    Task { @MainActor in
                        let service = ScreenCaptureService()
                        guard let content = try? await service.shareableContent(),
                              let image = try? await service.captureWindow(id: id, in: content, fallbackScale: 2),
                              let png = ImageEncoding.png(image.cgImage) else { return }
                        try? png.write(to: CaptureLibrary.defaultFolder().appendingPathComponent("_panel.png"))
                    }
                }
            }
        }
        groups.onDeleted = { [weak self] group in
            guard let self else { return }
            switch group.kind {
            case .captures: library.removeGroup(group.id)
            case .clipboard: clipboard.removeGroup(group.id)
            case .colors: colors.removeGroup(group.id)
            case .assets: assets.removeGroup(group.id)
            }
        }
        // Older captures get their text read in the background, a while after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            // The search index is only as good as the language it was read in, so it
            // is rebuilt when that changes before catching up on anything missing.
            library.ocr = OCRService(settings: preferences.ocrSettings.forIndexing, engines: ocrEngines.set)
            library.reindexIfLanguagesChanged(preferences.ocrLanguages)
            library.indexMissingText()
        }
        if !PermissionManager.hasScreenCaptureAccess {
            Log.app.notice("Screen Recording not granted; showing onboarding")
            showOnboarding(for: .screenRecording)
        }
    }

    /// `cue://…` from the command line, Shortcuts, Raycast, a browser — and recordings
    /// opened from the Finder, which go to the video editor.
    func application(_ application: NSApplication, open urls: [URL]) {
        let recordings = urls.filter(StudioController.handles)
        if !recordings.isEmpty { studio.open(recordings) }
        for url in urls where !StudioController.handles(url) {
            #if DEBUG
            if DebugCommands.handles(url) {
                DebugCommands.run(url, tasks: tasks, createTask: { [weak self] in self?.createTask(from: $0) }) { [weak self] task, asPage in
                    self?.openTaskDashboard(task: task)
                    self?.taskDashboard?.showAsPage(asPage)
                }
                continue
            }
            #endif
            guard let command = URLCommand(url) else {
                Log.app.notice("Unknown URL: \(url.absoluteString, privacy: .public)")
                FeedbackHUD.show("Cue doesn't understand that link", symbol: "link.badge.plus", subtitle: url.absoluteString)
                continue
            }
            run(command)
        }
    }

    private func run(_ command: URLCommand) {
        closeHistory()
        switch command {
        case .captureArea: coordinator.captureArea(fromMenu: true)
        case .captureWindow: coordinator.captureWindow(fromMenu: true)
        case .captureFullScreen: coordinator.captureFullScreen(fromMenu: true)
        case .captureScrolling: coordinator.captureScrolling(fromMenu: true)
        case .captureText: coordinator.captureText(fromMenu: true)
        case .pickColor: pickColor(nil)
        case .newTask(let title, let notes, let priority, let project):
            guard let title else { quickTask(nil); return }
            let projectID = project.flatMap { name in (tasks.projects.first { $0.parentID == nil && $0.name == name } ?? tasks.addProject(named: name))?.id }
            if tasks.addTask(titled: title, notes: notes, in: projectID, priority: priority) != nil {
                FeedbackHUD.show("Task added", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: title)
            }
        case .addSnippet(let keyword, let name, let text):
            if let snippet = snippets.add(keyword: keyword, name: name, text: text) {
                FeedbackHUD.show("Snippet saved", symbol: "text.badge.checkmark", subtitle: "Type \(snippet.keyword) anywhere")
            }
        case .newNote(let text):
            guard let text else { quickNote(nil); return }
            if let note = notes.add(text: text) {
                FeedbackHUD.show("Note saved", symbol: "note.text", duration: .seconds(1.2), subtitle: note.title)
                NoteSharing.sendToConnected(note, preferences: preferences)
            }
        case .copy(let text):
            clipboard.copy(text: text)
            FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: String(text.prefix(60)))
        case .palette: showCommandPalette(nil)
        case .clipboard: showClipboardPanel(nil)
        case .panel: toggleHistoryAtPointer()
        case .clock: island?.showClock() ?? showSettings(nil)
        case .settings(let name):
            showSettings(nil)
            if let page = SettingsSection.allCases.first(where: { $0.rawValue.lowercased() == name }) { settingsWindow?.present(page) }
        case .record: studio.showRecorder()
        case .recordings: studio.showLibrary()
        case .tasks: showTaskDashboard(nil)
        case .basket: basket.reopen()
        case .checkForUpdates: AppUpdater.shared.checkInBackground()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissionState()
    }

    // MARK: - Status item

    /// The menu bar item: every capture tool and the panels, with their shortcuts,
    /// then Settings and Quit. Built as it opens, so a changed shortcut shows.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        statusMenu = menu
        applyMenuBarIcon()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        menu.removeAllItems()
        menu.addItem(brandHeader())
        menu.addItem(.separator())
        let tools: [(String, Selector, HotkeyID)] = [
            ("Capture Full Screen", #selector(captureFullScreen(_:)), .fullScreen),
            ("Capture Area", #selector(captureArea(_:)), .region),
            ("Capture Window", #selector(captureWindow(_:)), .window),
            ("Scrolling Capture", #selector(captureScrolling(_:)), .scrolling),
            ("Capture Text", #selector(captureText(_:)), .captureText),
            ("Pick Color", #selector(pickColor(_:)), .pickColor),
        ]
        for (title, selector, id) in tools { menu.addItem(shortcutItem(title, selector, id)) }
        menu.addItem(.separator())
        // Video. Mid-take, the take's own controls take Record Video's place: the bar may
        // be put away, and this menu is always there.
        if let session = studio.service?.session, session.state.isBusy {
            if session.state.isStarting {
                menu.addItem(makeItem("Cancel Countdown", #selector(stopRecording(_:))))
            } else {
                menu.addItem(makeItem("Stop Recording", #selector(stopRecording(_:))))
                menu.addItem(makeItem(session.isPaused ? "Resume Recording" : "Pause Recording", #selector(pauseRecording(_:))))
            }
        } else {
            menu.addItem(makeItem("Record Video", #selector(recordVideo(_:))))
        }
        menu.addItem(makeItem("Recordings…", #selector(openStudio(_:))))
        menu.addItem(.separator())
        let panels: [(String, Selector, HotkeyID)] = [
            ("Quick Task…", #selector(quickTask(_:)), .quickTask),
            ("Quick Note…", #selector(quickNote(_:)), .quickNote),
        ]
        for (title, selector, id) in panels { menu.addItem(shortcutItem(title, selector, id)) }
        menu.addItem(makeItem("Tasks…", #selector(showTaskDashboard(_:))))
        if basket.canReopen { menu.addItem(makeItem("Reopen Last Basket", #selector(reopenBasket(_:)))) }
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", #selector(showSettings(_:)), keyEquivalent: ",", modifiers: .command))
        menu.addItem(makeItem("Check for Updates…", #selector(checkForUpdates(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Cue", #selector(NSApplication.terminate(_:)), keyEquivalent: "q", modifiers: .command))
    }

    /// The mark and the app's name over the menu: which app this is, at a glance,
    /// and what VoiceOver reads first.
    private func brandHeader() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.image = CueMarkImage.template(height: 14)
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        item.attributedTitle = NSAttributedString(
            string: name.map { "Cue \($0)" } ?? "Cue",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        )
        return item
    }

    /// A menu item showing the shortcut set for the action in Settings, if any. The
    /// action runs once the menu is gone: a panel shown while the menu is still
    /// closing loses key status to that and closes itself at once.
    private func shortcutItem(_ title: String, _ action: Selector, _ id: HotkeyID) -> NSMenuItem {
        let hotkey = shortcuts.hotkey(for: id)
        let item = makeItem(title, #selector(runFromStatusMenu(_:)), keyEquivalent: hotkey?.menuKeyEquivalent ?? "", modifiers: hotkey?.menuModifierMask ?? [])
        item.representedObject = NSStringFromSelector(action)
        return item
    }

    @objc private func runFromStatusMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let action = NSSelectorFromString(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            _ = self?.perform(action, with: sender)
        }
    }

    /// The menu bar glyph gives once, the way a shutter does, at what Cue just took.
    private func pulseStatusItem() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // The mark blinks at what it just took; any other glyph gives like a shutter.
        if let markBlinker {
            markBlinker.blink()
            return
        }
        guard let button = statusItem?.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        // Apple's shape for a thing that lands: a touch of give, response ≈ 0.35 s.
        let pulse = CASpringAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.82
        pulse.toValue = 1
        pulse.mass = 1
        pulse.stiffness = 322 // (2π / 0.35)²
        pulse.damping = 28.7 // 2 · 0.8 · √stiffness
        pulse.duration = pulse.settlingDuration
        layer.add(pulse, forKey: "cue.pulse")
    }

    /// Keeps the status item image in sync with the Settings choice.
    private func applyMenuBarIcon() {
        withObservationTracking {
            // The mark is drawn from its paths; every other choice is a still image.
            markBlinker?.stop()
            markBlinker = nil
            if preferences.icon == .mark, let button = statusItem?.button {
                button.image = CueMarkImage.template(height: 17)
                markBlinker = MarkBlinker(button: button, height: 17)
            } else {
                let image = preferences.menuBarImage()
                    ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Cue")
                image?.accessibilityDescription = "Cue"
                statusItem?.button?.image = image
            }
            // VoiceOver and the Accessibility Inspector name the item, not its glyph.
            statusItem?.button?.setAccessibilityLabel("Cue")
            statusItem?.button?.toolTip = "Cue — capture, clipboard and notes"
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
                island = IslandController(library: library, clipboard: clipboard, assets: assets, colors: colors, groups: groups, tasks: tasks, snippets: snippets,
                                          notes: notes, actions: historyActions, preferences: preferences, clock: prayerClock, focus: focusTimer, agents: agentStore)
                island?.onSnippetFilled = { [weak self] snippet, values in self?.snippetFilled(snippet, values: values) }
                island?.onOpenTaskDashboard = { [weak self] in self?.showTaskDashboard(nil) }
                library.warmThumbnails()
                FeedbackHUD.island = { [weak self] status in self?.island?.showStatus(status) ?? false }
            }
        } else if let island {
            island.tearDown()
            self.island = nil
        }
    }

    /// Listens for agent sessions while Settings › Island › Agent sessions is on.
    private func applyAgentPreference() {
        let enabled = withObservationTracking {
            preferences.agentSessionsEnabled
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyAgentPreference() }
        }
        agentConnector.setRunning(enabled)
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
        commandPalette?.close()
        island?.collapse(animated: false)
    }

    /// The floating Cue panel at the pointer (⌥⇧K by default): the island's content
    /// as a movable glass window that scrolls vertically, as a grid or a list.
    private func toggleHistoryAtPointer() {
        if let panel = floatingPanel, panel.isVisible {
            panel.close()
            return
        }
        closeHistory()
        let content = FloatingPanelView(library: library, clipboard: clipboard, assets: assets, colors: colors, tasksStore: tasks, snippets: snippets, actions: historyActions,
                                        close: { [weak self] in self?.floatingPanel?.close() })
        .environment(preferences)
        .environment(notes)
        let panel = FloatingPanelWindow(rootView: content, movableByBackground: false)
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
        // The panel takes the keyboard without activating Cue, so the other app stays
        // in front with its cursor where it was; the field is remembered all the same,
        // for the paste to be sent once the panel has gone.
        let frontField = FrontField.capture()
        let content = ClipboardPanelView(clipboard: clipboard, close: { [weak self] in self?.clipboardPanel?.close() },
                                         onNeedsAccessibility: { [weak self] in self?.showOnboarding(for: .accessibility) },
                                         onEdit: { [weak self] item in self?.editClipboardImage(item) },
                                         frontField: frontField)
            .environment(preferences)
        let panel = FloatingPanelWindow(rootView: content, size: ClipboardPanelView.size)
        clipboardPanel = panel
        panel.show(at: NSEvent.mouseLocation, position: preferences.panelPosition)
        // Whatever closes the panel (⎋, a click outside, a pick), the other app gets
        // the keyboard back (and activation, should Cue have taken it meanwhile).
        if let observer = clipboardPanelObserver { NotificationCenter.default.removeObserver(observer) }
        clipboardPanelObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, let observer = self.clipboardPanelObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.clipboardPanelObserver = nil
                }
                frontField.restore()
            }
        }
    }

    /// Moves the snippets, colors and tasks into the sync folder (or back) whenever it changes.
    private func applySyncFolder() {
        let folder = withObservationTracking {
            syncFolder.url
        } onChange: { [weak self] in
            Task { @MainActor in self?.applySyncFolder() }
        }
        snippets.useSyncFolder(folder)
        colors.useSyncFolder(folder)
        tasks.useSyncFolder(folder)
        groups.useSyncFolder(folder)
    }

    /// ⌘⇧V: the paste stack — each press pastes the next entry of the history.
    private func pasteNext() {
        guard PermissionManager.hasAccessibilityAccess else { showOnboarding(for: .accessibility); return }
        guard let pasted = clipboard.pasteNext() else {
            FeedbackHUD.show("Nothing to paste", symbol: "doc.on.clipboard", duration: .seconds(1.2))
            return
        }
        island?.showStatus(IslandStatus(symbol: "square.stack.3d.down.right", title: "Pasted \(pasted.position) of \(pasted.of)",
                                        subtitle: pasted.item.title, duration: .seconds(1.2)), quiet: true)
    }

    /// One list over everything (⌥⇧Space by default): actions, quick answers and
    /// every item, driven by the keyboard. Activation is handled like the clipboard
    /// list's so a pick lands where the cursor was.
    @objc func showCommandPalette(_ sender: Any?) {
        if let panel = commandPalette, panel.isVisible {
            panel.close()
            return
        }
        closeHistory()
        let frontField = FrontField.capture()
        let content = CommandPaletteView(library: library, clipboard: clipboard, assets: assets, colors: colors, tasks: tasks,
                                         snippets: snippets, shortcuts: shortcuts, actions: paletteActions(returningTo: frontField),
                                         close: { [weak self] in self?.commandPalette?.close() },
                                         onNeedsAccessibility: { [weak self] in self?.showOnboarding(for: .accessibility) })
            .environment(preferences)
            .environment(notes)
        let panel = FloatingPanelWindow(rootView: content, size: CommandPaletteView.size)
        commandPalette = panel
        panel.show(at: NSEvent.mouseLocation, position: preferences.panelPosition)
        if let observer = commandPaletteObserver { NotificationCenter.default.removeObserver(observer) }
        commandPaletteObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, let observer = self.commandPaletteObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.commandPaletteObserver = nil
                }
                frontField.restore()
            }
        }
    }

    private func paletteActions(returningTo field: FrontField) -> PaletteActions {
        PaletteActions(
            run: { [weak self] command in
                guard let self else { return }
                switch command {
                case .captureArea: coordinator.captureArea(fromMenu: true)
                case .captureWindow: coordinator.captureWindow(fromMenu: true)
                case .captureFullScreen: coordinator.captureFullScreen(fromMenu: true)
                case .captureScrolling: coordinator.captureScrolling(fromMenu: true)
                case .captureText: coordinator.captureText(fromMenu: true)
                case .pickColor: pickColor(nil)
                case .newTask: quickTask(nil)
                case .taskDashboard: showTaskDashboard(nil)
                case .newSnippet: snippetPanel(IslandPrompt(kind: .snippet(nil, initialText: "", assetID: nil)))
                case .newNote: quickNote(nil)
                case .clipboardList: showClipboardPanel(nil)
                case .cuePanel: toggleHistoryAtPointer()
                case .clock: island?.showClock() ?? showSettings(nil)
                case .settings: showSettings(nil)
                case .unghostPins: PinnedCaptureWindow.unghostAll()
                }
            },
            paste: { [weak self] item in
                guard let self else { return false }
                copyToPasteboard(item)
                if clipboard.pressPaste(returningTo: field) { return true }
                FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
                return false
            },
            copy: { [weak self] item in
                self?.copyToPasteboard(item)
                FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
            },
            open: { [weak self] item in
                guard let self else { return }
                switch item {
                case .capture(let capture): openEditor(for: capture, mode: .edit)
                case .clipboard(let entry): clipboard.copy(entry); FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
                case .asset(let asset): assets.open(asset)
                case .color(let entry): colors.copy(entry, as: preferences.colorFormat); FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), swatch: entry.color)
                case .task(let task):
                    if let island { island.showTask(task) } else { toggleHistoryAtPointer() }
                case .snippet(let snippet):
                    if let island { island.prompt(IslandPrompt(kind: .snippet(snippet, initialText: "", assetID: nil))) }
                    else { snippetPanel(IslandPrompt(kind: .snippet(snippet, initialText: "", assetID: nil))) }
                case .note(let note): notePanel(IslandPrompt(kind: .note(note)))
                case .answer: break
                }
            },
            pasteText: { [weak self] text in
                guard let self else { return false }
                clipboard.copy(text: text)
                if clipboard.pressPaste(returningTo: field) { return true }
                FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
                return false
            },
            pin: { [weak self] item in
                if case .capture(let capture) = item { self?.pinToScreen(capture) }
            },
            shareLink: { [weak self] item in
                if case .capture(let capture) = item { self?.shareLink(for: capture) }
            }
        )
    }

    /// Puts an item on the pasteboard the way its own tab would.
    private func copyToPasteboard(_ item: IslandItem) {
        switch item {
        case .capture(let capture): library.copyToClipboard(capture)
        case .clipboard(let entry): clipboard.copy(entry)
        case .asset(let asset): assets.copy(asset)
        case .color(let entry): colors.copy(entry, as: preferences.colorFormat)
        case .task(let task): clipboard.copy(text: task.text)
        case .snippet(let snippet):
            clipboard.copy(text: SnippetTemplate.expand(snippet.text, values: [:], clipboard: NSPasteboard.general.string(forType: .string)))
            snippets.recordUse(snippet)
        case .note(let note): clipboard.copy(text: note.text)
        case .answer(let answer): clipboard.copy(text: answer.value)
        }
    }

    /// A snippet's blanks, asked for in the island — or a floating form without one.
    /// Cue takes activation for the form (invisibly) so it can hand it back to the
    /// app afterwards, with the cursor where it was.
    private func fillSnippet(_ snippet: Snippet, from field: FrontField) {
        snippetFrontField = field
        NSApp.activate(ignoringOtherApps: true)
        // Always a floating form at the pointer — where the keyword was just typed.
        snippetPanel(IslandPrompt(kind: .fill(snippet)), at: .pointer)
    }

    /// The blanks are in (or the form was cancelled): back to the app, then paste.
    private func snippetFilled(_ snippet: Snippet, values: [String: String]?) {
        let field = snippetFrontField
        snippetFrontField = nil
        if let values {
            snippetExpander?.paste(snippet, values: values, returningTo: field)
        } else {
            field?.restore()
        }
    }

    /// The snippet form (new / edit) as a floating window when there is no island,
    /// and the blanks form always.
    private func snippetPanel(_ prompt: IslandPrompt, at position: PanelPosition? = nil) {
        quickTaskPanel?.close()
        let finish: (PromptAnswer?) -> Void = { [weak self] answer in
            guard let self, let answer else { return }
            switch prompt.kind {
            case .snippet(let existing, _, let assetID):
                if let existing {
                    snippets.update(existing, keyword: answer.title, name: answer.name, text: answer.notes)
                } else {
                    snippets.add(keyword: answer.title, name: answer.name, text: answer.notes, assetID: assetID)
                }
                FeedbackHUD.show("Snippet saved", symbol: "text.badge.checkmark", subtitle: "Type \(SnippetStore.cleanKeyword(answer.title)) anywhere")
            case .fill(let snippet):
                snippetFilled(snippet, values: answer.values)
            default:
                break
            }
        }
        let panel: QuickTaskPanel
        if case .fill(let snippet) = prompt.kind {
            let fill = SnippetFillRow(snippet: snippet) { [weak self] answer in
                if answer == nil { self?.snippetFilled(snippet, values: nil) }
                finish(answer)
                self?.quickTaskPanel?.close()
            } onContentSize: { [weak self] naturalWidth, height in
                // The glass grows to the template — up to 60 % of the screen either way.
                guard let panel = self?.quickTaskPanel else { return }
                let limit = QuickTaskPanel.maxSize(on: panel.screen ?? NSScreen.main)
                let chrome = CGSize(width: 36, height: 128) // paddings, the header row and the buttons
                let width = min(max(naturalWidth + chrome.width, 360), limit.width)
                let contentHeight = min(max(height + chrome.height, 180), limit.height)
                panel.resize(to: CGSize(width: width.rounded(), height: contentHeight.rounded()))
            }
            panel = QuickTaskPanel(form: fill)
        } else {
            panel = QuickTaskPanel(form: SnippetFormRow(prompt: prompt, store: snippets, assets: assets) { [weak self] answer in finish(answer); self?.quickTaskPanel?.close() }
                .environment(preferences))
        }
        quickTaskPanel = panel
        panel.show(at: NSEvent.mouseLocation, position: position ?? preferences.panelPosition)
    }

    private var historyActions: HistoryActions {
        HistoryActions(
            captureFullScreen: { [weak self] in self?.closeHistoryThen { $0.coordinator.captureFullScreen(fromMenu: true) } },
            captureArea: { [weak self] in self?.closeHistoryThen { $0.coordinator.captureArea(fromMenu: true) } },
            captureWindow: { [weak self] in self?.closeHistoryThen { $0.coordinator.captureWindow(fromMenu: true) } },
            captureScrolling: { [weak self] in self?.closeHistoryThen { $0.coordinator.captureScrolling(fromMenu: true) } },
            captureText: { [weak self] in self?.closeHistoryThen { $0.coordinator.captureText(fromMenu: true) } },
            pickColor: { [weak self] in self?.closeHistoryThen { $0.pickColor(nil) } },
            openSettings: { [weak self] in self?.closeHistoryThen { $0.showSettings(nil) } },
            quit: { NSApp.terminate(nil) },
            preview: { [weak self] item in self?.closeHistoryThen { $0.openEditor(for: item, mode: .preview) } },
            edit: { [weak self] item in self?.closeHistoryThen { $0.openEditor(for: item, mode: .edit) } },
            copy: { [weak self] item in
                if self?.library.copyToClipboard(item) == true {
                    FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: item.dimensions, image: self?.library.thumbnail(for: item))
                } else {
                    FeedbackHUD.show("Cannot copy — the file has gone", symbol: "exclamationmark.triangle.fill", duration: .seconds(1.6), subtitle: item.title)
                }
            },
            palette: { [weak self] item in self?.library.image(for: item).map { PaletteExtractor.dominantColors(in: $0.cgImage) } ?? [] },
            delete: { [weak self] item in self?.deleteCapture(item) },
            pinToScreen: { [weak self] item in self?.pinToScreen(item) },
            shareLink: { [weak self] item in self?.shareLink(for: item) },
            makeTask: { [weak self] item in self?.makeTask(from: item) },
            createTask: { [weak self] seed in self?.createTask(from: seed) },
            compare: { [weak self] item, images in self?.compare(item, with: images) },
            editClipboardImage: { [weak self] item in self?.closeHistoryThen { $0.editClipboardImage(item) } }
        )
    }

    /// An image dropped on a capture card: the two are laid out in one picture, kept
    /// as a capture of its own and copied, ready to paste into a chat or an agent.
    private func compare(_ item: CaptureItem, with images: [CapturedImage]) {
        guard !images.isEmpty else { return }
        guard let base = library.image(for: item) else {
            FeedbackHUD.show("The capture could not be read", symbol: "exclamationmark.triangle")
            return
        }
        let pieces = [CompareComposer.Piece(base)] + images.map(CompareComposer.Piece.init)
        guard let composed = CompareComposer.compose(pieces) else {
            FeedbackHUD.show("The images could not be combined", symbol: "exclamationmark.triangle")
            return
        }
        Clipboard.copy(composed.cgImage)
        let capture = library.add(composed)
        Log.app.info("Compared \(pieces.count, privacy: .public) images → \(capture.fileName, privacy: .public)")
        FeedbackHUD.show("\(pieces.count) images compared · copied", symbol: "checkmark.circle.fill",
                         duration: .seconds(1.6), subtitle: composed.dimensionsDescription, image: library.thumbnail(for: capture))
    }

    /// A new task with the capture in its description (the island's form, or the
    /// floating one without an island).
    private func makeTask(from item: CaptureItem) {
        guard let image = library.image(for: item), let png = ImageEncoding.png(image.cgImage) else { return }
        createTask(from: .image(png))
    }

    /// The floating task form with `seed` in the description — the picture (or text, or
    /// file) at the bottom, the caret on the empty line above it for the title.
    func createTask(from seed: TaskSeed) {
        let notes: String?
        switch seed {
        case .image(let png):
            notes = tasks.saveImage(png)
        case .text(let text):
            notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .file(let url):
            let isImage = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"].contains(url.pathExtension.lowercased())
            notes = isImage ? (try? Data(contentsOf: url)).flatMap { tasks.saveImage($0) } : tasks.saveAttachment(url)
        }
        guard let notes, !notes.isEmpty else { return }
        closeHistory()
        island?.collapse()
        quickTaskPanel?.close()
        isNotePanel = false
        let panel = QuickTaskPanel(store: tasks, prompt: IslandPrompt(kind: .task(project: nil), initialNotes: notes + "\n")) { [weak self] answer in
            guard let self, let answer else { return }
            tasks.addTask(text: answer.text, in: answer.projectID, priority: answer.priority)
            FeedbackHUD.show("Task added", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
        }
        quickTaskPanel = panel
        clipboard.openEditor = { [weak self] in
            guard let panel = self?.quickTaskPanel, panel.isVisible else { return nil }
            return panel.editor
        }
        panel.show(at: NSEvent.mouseLocation, position: preferences.panelPosition)
    }

    /// Uploads the capture where Settings › Sharing says and puts the link on the
    /// clipboard; the island (or a HUD) says how it went.
    private func shareLink(for item: CaptureItem) {
        guard share.isConfigured else {
            FeedbackHUD.show("Set up sharing first", symbol: "link.badge.plus", subtitle: "Settings › Sharing")
            showSettings(nil)
            return
        }
        guard let image = library.image(for: item), let png = ImageEncoding.png(image.cgImage) else { return }
        closeHistory()
        island?.showStatus(IslandStatus(symbol: "arrow.up.circle", title: "Uploading…", subtitle: item.title, duration: .seconds(20)), quiet: false)
        let name = share.objectName(for: item.createdAt)
        let share = share
        Task { @MainActor [weak self] in
            do {
                let url = try await ShareUploader.upload(png, name: name, settings: share)
                self?.clipboard.copy(text: url.absoluteString)
                FeedbackHUD.show("Link copied", symbol: "link", duration: .seconds(2.5), subtitle: url.absoluteString, image: self?.library.thumbnail(for: item))
                Log.app.info("Shared \(item.fileName, privacy: .public) → \(url.absoluteString, privacy: .public)")
            } catch {
                FeedbackHUD.show("Upload failed", symbol: "exclamationmark.triangle.fill", duration: .seconds(4), subtitle: error.localizedDescription)
                Log.app.error("Share failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The capture as a floating window to work against (see PinnedCaptureWindow).
    private func pinToScreen(_ item: CaptureItem) {
        guard let image = library.image(for: item) else { return }
        closeHistory()
        PinnedCaptureWindow.pin(image.nsImage) { [weak self] in
            self?.library.copyToClipboard(item)
            FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
        }
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

    @objc func captureWindow(_ sender: Any?) {
        coordinator.captureWindow(fromMenu: true)
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

    /// A key press for the diagnostics above, sent as the user's would be.
    private static func debugPress(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// The pixel picker. The picked color is listed under Colors in the island and
    /// copied in the preferred format.
    @objc func pickColor(_ sender: Any?) {
        guard preferences.colorPickerEnabled else {
            FeedbackHUD.show("Color picker is off", symbol: "eyedropper")
            return
        }
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

    /// A floating note at the pointer (⌥⇧M by default): jot it down, ⌘↩ saves it
    /// to the notes folder; Send puts it in Obsidian, Apple Notes or Notion too.
    @objc func quickNote(_ sender: Any?) {
        if let panel = quickTaskPanel, panel.isVisible, isNotePanel {
            // A pinned note is brought back rather than closed.
            if panel.isPinned { panel.makeKeyAndOrderFront(nil) } else { panel.close() }
            return
        }
        notePanel(IslandPrompt(kind: .note(nil)))
    }

    /// Settings › Notes, from a note form's Send menu.
    @objc func showNotesSettings(_ sender: Any?) {
        showSettings(nil)
        settingsWindow?.present(.notes)
    }

    private var isNotePanel = false

    /// The note form (new or an edit) as a floating window at the pointer.
    private func notePanel(_ prompt: IslandPrompt) {
        closeHistory()
        quickTaskPanel?.close()
        let form = NoteFormRow(prompt: prompt, store: notes, style: .floating) { [weak self] answer in
            guard let self else { return }
            if let answer, case .note(let existing) = prompt.kind {
                let saved = existing.map { notes.update($0, text: answer.text) } ?? notes.add(text: answer.text)
                if let saved {
                    FeedbackHUD.show(existing == nil ? "Note saved" : "Note updated", symbol: "note.text", duration: .seconds(1.2), subtitle: saved.title)
                    if existing == nil { NoteSharing.send(saved, to: answer.sendTo, preferences: preferences) }
                }
            }
            quickTaskPanel?.close()
        }
        .environment(preferences)
        let panel = QuickTaskPanel(form: form)
        quickTaskPanel = panel
        isNotePanel = true
        panel.useRaycastLook(size: preferences.notesPanelSize ?? CGSize(width: 640, height: 380))
        // Island cards pasted while the note is open land in its text.
        clipboard.openEditor = { [weak self] in
            guard let panel = self?.quickTaskPanel, panel.isVisible else { return nil }
            return panel.editor
        }
        panel.show(at: NSEvent.mouseLocation, position: preferences.panelPosition)
    }

    /// Every task in a window of its own: lists and projects, as a list or a board,
    /// with the chosen task open beside them.
    @objc func reopenBasket(_ sender: Any?) {
        basket.reopen()
    }

    @objc func showTaskDashboard(_ sender: Any?) {
        openTaskDashboard(task: nil)
    }

    /// The dashboard, with `task` (if any) open in its detail pane.
    func openTaskDashboard(task: TaskItem?) {
        closeHistory()
        if taskDashboard == nil {
            let controller = TaskDashboardWindowController(store: tasks)
            controller.onClose = { [weak self] in self?.taskDashboard = nil }
            taskDashboard = controller
        }
        taskDashboard?.present(task: task)
    }

    /// A floating "new task" form at the pointer (⌥/ by default).
    @objc func quickTask(_ sender: Any?) {
        if let panel = quickTaskPanel, panel.isVisible {
            panel.close()
            return
        }
        closeHistory()
        isNotePanel = false
        let panel = QuickTaskPanel(store: tasks) { [weak self] answer in
            guard let self, let answer else { return }
            tasks.addTask(text: answer.text, in: answer.projectID, priority: answer.priority)
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

    /// The Dock tile, clicked with nothing open: the panel at the pointer, the way
    /// the hotkey opens it. With a window already up, AppKit brings it forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, !studio.handlesReopen else { return true }
        toggleHistoryAtPointer()
        return true
    }

    /// The recorder bar, where recording starts.
    @objc func recordVideo(_ sender: Any?) {
        studio.showRecorder()
    }

    /// Recordings, the gallery of what was recorded.
    @objc func openStudio(_ sender: Any?) {
        studio.showLibrary()
    }

    /// Stops the take under way and keeps it, or calls off a countdown.
    @objc func stopRecording(_ sender: Any?) {
        guard let service = studio.service else { return }
        service.session.state.isStarting ? service.cancel() : service.stop()
    }

    @objc func pauseRecording(_ sender: Any?) {
        studio.service?.togglePause()
    }

    /// A take is stopped and saved, and unsaved edits and running exports asked about,
    /// before Cue quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        studio.shouldTerminate(sender)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        AppUpdater.shared.checkForUpdates()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let controller = SettingsWindowController(model: model, shortcuts: shortcuts, library: library, clipboard: clipboard, preferences: preferences, clock: prayerClock, share: share, sync: syncFolder, notes: notes, taskSync: taskSync, ocrEngines: ocrEngines, agents: agentConnector, studio: studio, taskMCP: taskMCP)
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
        pulseStatusItem()
        island?.flash(item)
        // The editor opens on the Space the capture came from, a full-screen app's too.
        switch preferences.afterCapture {
        case .edit:
            openEditor(for: item, image: image, mode: .edit)
        case .copy:
            FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: item.dimensions, image: library.thumbnail(for: item))
        }
    }

    /// A clipboard image becomes a capture of its own — saved with the others — and
    /// opens in the editor; Done puts the edited image back on the clipboard.
    func editClipboardImage(_ item: ClipboardItem) {
        guard item.kind == .image, let data = clipboard.imageData(for: item),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            FeedbackHUD.show("The image could not be read", symbol: "exclamationmark.triangle")
            return
        }
        let image = CapturedImage(cgImage: cgImage, scale: Self.scale(of: source, pixelWidth: cgImage.width, pixelHeight: cgImage.height),
                                  displayID: 0, capturedAt: item.createdAt)
        let capture = library.add(image)
        Log.app.info("Clipboard image → capture \(capture.fileName, privacy: .public) for editing")
        openEditor(for: capture, image: image, mode: .edit)
        editorWindows[capture.id]?.onSaved = { edited in
            Clipboard.copy(edited)
            FeedbackHUD.show("Edited image copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
        }
    }

    /// Pixels per point for an image of unknown origin: what its DPI says, else the
    /// screen's when it is big enough to be a Retina screenshot, else 1.
    private static func scale(of source: CGImageSource, pixelWidth: Int, pixelHeight: Int) -> CGFloat {
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi >= 144 {
            return (dpi / 72).rounded()
        }
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2
        return pixelWidth >= 1200 && pixelHeight >= 800 ? screenScale : 1
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
            presentError(NSError(domain: "Cue", code: 2, userInfo: [NSLocalizedDescriptionKey: "The capture file could not be opened."]))
            return
        }
        // One editor at a time: a new capture replaces the one before, which keeps its
        // annotations (saved into the library, as Done does) rather than piling up windows.
        for (id, older) in editorWindows where id != item.id {
            older.done()
        }
        // Decoding the wallpaper thumbnails costs seconds of CPU, so it waits for the
        // first editor rather than running at every login; it's done long before the
        // Background tool is reached, and a no-op once cached.
        Task(priority: .utility) { await WallpaperCatalog.shared.prepareThumbnails() }
        let controller = EditorWindowController(item: item, image: image, library: library, preferences: preferences, mode: mode)
        controller.onClose = { [weak self] in self?.editorWindows[item.id] = nil }
        controller.onDelete = { [weak self] item in self?.library.delete(item) }
        controller.onCreateTask = { [weak self] png in self?.createTask(from: .image(png)) }
        editorWindows[item.id] = controller
        controller.present()
    }

    /// Capture Text: clipboard only, never the library. The text itself is not logged.
    private func handleRecognizedText(_ recognized: RecognizedText) {
        guard !recognized.isEmpty else {
            FeedbackHUD.show("No text detected", symbol: "text.viewfinder")
            return
        }
        let text = recognized.bestText
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        preferences.playCaptureSound()
        let code = CodeSnippet.detect(text)
        let found = TextExtract.summary(of: text)
        let title = code.map { "\($0.title) copied" } ?? (recognized.engine == .cloud ? "Text copied · \(recognized.engine.title)" : "Text copied")
        FeedbackHUD.show(title, symbol: recognized.engine == .cloud ? "checkmark.icloud.fill" : "checkmark.circle.fill",
                         subtitle: subtitle(for: recognized, extracted: found))
    }

    /// What the HUD says under the title. The script warning comes first: it is the
    /// one case where Cue copied something it is not sure the reader wanted.
    private func subtitle(for recognized: RecognizedText, extracted: String) -> String? {
        if let warning = recognized.scriptWarning {
            return "\(warning.found.displayName) — if that should be \(warning.possiblyIntended.displayName), pick it in Settings › Capture."
        }
        guard !extracted.isEmpty else { return nil }
        return "Right-click it on the Clipboard tab to copy just the \(extracted)"
    }

    /// Cue declined to answer. Nothing is written to the clipboard on these paths —
    /// whatever was there stays there, because pasting the wrong alphabet is the
    /// failure this whole path exists to prevent.
    private func handleTextUnavailable(_ reason: OCRUnavailable) {
        FeedbackHUD.show(reason.errorDescription ?? "Cue couldn't read that",
                         symbol: reason.symbol, subtitle: reason.recoverySuggestion)
    }

    private func deleteCapture(_ item: CaptureItem) {
        editorWindows[item.id]?.forceClose()
        library.delete(item)
    }

    // MARK: - Windows

    private func showOnboarding(for kind: PermissionKind) {
        if onboardingWindows[kind] == nil {
            let controller = HostedWindowController(
                title: "Welcome to Cue",
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
