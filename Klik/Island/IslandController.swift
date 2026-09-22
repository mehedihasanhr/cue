import os
import AppKit
import SwiftUI

/// Owns the Dynamic Island: places it on the notch (or as a pill on a plain display),
/// opens the captures panel when the pointer rests on it, closes it when the pointer
/// leaves, and flashes each new capture.
@MainActor
final class IslandController {
    private let window = IslandWindow()
    private let model = IslandModel()
    private let preferences: AppPreferences
    private let tasks: TaskStore
    private let snippets: SnippetStore
    private let notes: NoteStore
    private let library: CaptureLibrary
    private let clipboard: ClipboardHistory
    private let assets: AssetStore
    private let colors: ColorStore
    private let groups: GroupStore

    private var closeTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    /// Menus (layout picker, context menus) take the pointer away without leaving.
    private var menusTracking = 0
    /// Hidden while a capture flow runs; a capture that lands meanwhile flashes after.
    private var hidden = false
    private var pendingFlash: CaptureItem?
    private var observers: [any NSObjectProtocol] = []

    private var hoverTask: Task<Void, Never>?
    private static let collapseAnimation: Duration = .milliseconds(380)

    /// A snippet's blanks were filled in the compact box (nil: cancelled); set by
    /// the app delegate.
    var onSnippetFilled: (Snippet, [String: String]?) -> Void = { _, _ in }

    init(library: CaptureLibrary, clipboard: ClipboardHistory, assets: AssetStore, colors: ColorStore, groups: GroupStore, tasks: TaskStore, snippets: SnippetStore,
         notes: NoteStore, actions: HistoryActions, preferences: AppPreferences, clock: PrayerClock? = nil, focus: FocusTimer? = nil) {
        self.preferences = preferences
        self.tasks = tasks
        self.snippets = snippets
        self.notes = notes
        self.library = library
        self.clipboard = clipboard
        self.assets = assets
        self.colors = colors
        self.groups = groups

        let content = IslandDropView(frame: CGRect(origin: .zero, size: window.frame.size))
        content.onDragEntered = { [weak self] in self?.dragEntered() }
        content.onDragExited = { [weak self] in self?.model.dropping = false }
        content.onDrop = { [weak self] urls, image in self?.drop(urls: urls, image: image, into: assets) }
        let host = NSHostingView(rootView: IslandView(model: model, library: library, clipboard: clipboard, assets: assets, colors: colors, tasks: tasks, snippets: snippets, actions: actions)
            .environment(preferences).environment(clock).environment(focus).environment(groups).environment(notes))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = content.bounds
        content.addSubview(host)
        window.contentView = content
        window.onEscape = { [weak self] in self?.escape() }
        model.onTap = { [weak self] in self?.expand() }
        model.onPrompt = { [weak self] prompt in self?.prompt(prompt) }
        model.onShowTask = { [weak self] task in self?.showTask(task) }
        model.onPanelWidthChanged = { [weak self] in
            // Reported from inside a layout pass; the window resizes after it.
            DispatchQueue.main.async { self?.fitWindow() }
        }
        model.onShowClock = { [weak self] in self?.showClock() }
        model.onClockClosed = { [weak self] in
            guard let self else { return }
            removeOutsideClickMonitor()
            resignKeyIfNeeded()
            if model.shapeRect(for: .expanded).contains(NSEvent.mouseLocation) {
                pointerInside = true
                setPhase(.expanded, animated: true)
            } else {
                collapse()
            }
        }
        model.onOpenTimeSettings = { [weak self] in
            self?.collapse()
            actions.openSettings()
        }
        model.onTaskDetailClosed = { [weak self] task in
            guard let self else { return }
            removeOutsideClickMonitor()
            if let task { tasks.pendingSelection = task.projectID.map { .project($0) } ?? .all }
            setPhase(.expanded, animated: true)
            resignKeyIfNeeded()
        }
        model.onPromptFinished = { [weak self] prompt, answer in
            guard let self else { return }
            removeOutsideClickMonitor()
            var status: IslandStatus?
            var collapseAfterPrompt = false
            if let answer {
                switch prompt.kind {
                case .delete(let deletion):
                    let done = tasks.delete(deletion)
                    if case .project = deletion { tasks.pendingSelection = .all }
                    status = IslandStatus(symbol: "trash.fill", title: done.title, subtitle: done.subtitle)
                case .snippet(let existing, _, let assetID):
                    if let existing {
                        snippets.update(existing, keyword: answer.title, name: answer.name, text: answer.notes)
                    } else {
                        snippets.add(keyword: answer.title, name: answer.name, text: answer.notes, assetID: assetID)
                    }
                    status = IslandStatus(symbol: "text.badge.checkmark", title: existing == nil ? "Snippet saved" : "Snippet updated",
                                          subtitle: "Type \(SnippetStore.cleanKeyword(answer.title)) anywhere")
                case .fill(let snippet):
                    onSnippetFilled(snippet, answer.values)
                    collapseAfterPrompt = true
                case .note(let existing):
                    let saved = existing.map { notes.update($0, text: answer.text) } ?? notes.add(text: answer.text)
                    status = IslandStatus(symbol: "note.text", title: existing == nil ? "Note saved" : "Note updated", subtitle: saved?.title ?? answer.title)
                    if existing == nil, let saved { NoteSharing.send(saved, to: answer.sendTo, preferences: preferences) }
                case .project(let parent):
                    if let project = tasks.addProject(named: answer.title, in: parent) {
                        tasks.pendingSelection = .project(project.id)
                    }
                case .group(let kind, let assign, let editing):
                    if let editing {
                        groups.rename(editing, to: answer.title)
                    } else if let group = groups.add(name: answer.title, kind: kind) {
                        switch assign {
                        case .capture(let id): library.items.first { $0.id == id }.map { library.setGroup($0, group.id) }
                        case .clipboard(let id): clipboard.items.first { $0.id == id }.map { clipboard.setGroup($0, group.id) }
                        case .color(let id): colors.items.first { $0.id == id }.map { colors.setGroup($0, group.id) }
                        case .asset(let id): assets.items.first { $0.id == id }.map { assets.setGroup($0, group.id) }
                        case nil: break
                        }
                        status = IslandStatus(symbol: "folder.fill.badge.plus", title: "Group “\(group.name)”", subtitle: assign == nil ? "Ready for its first item" : "Moved in")
                    }
                case .rename(let detail):
                    renamed(detail, to: answer.title)
                case .task:
                    if let task = prompt.editing {
                        tasks.update(task, text: answer.text, projectID: answer.projectID, priority: answer.priority)
                    } else {
                        tasks.addTask(text: answer.text, in: answer.projectID, priority: answer.priority)
                    }
                    tasks.pendingSelection = answer.projectID.map { .project($0) } ?? .all
                }
            } else if case .task(let project) = prompt.kind {
                tasks.pendingSelection = project.map { .project($0) } ?? .all
            }
            if let answer, case .task = prompt.kind {
                status = IslandStatus(symbol: "checkmark.circle.fill", title: prompt.editing == nil ? "Task saved" : "Task updated", subtitle: answer.title)
            }
            resignKeyIfNeeded()
            if answer == nil, case .fill(let snippet) = prompt.kind {
                onSnippetFilled(snippet, nil)
                collapseAfterPrompt = true
            }
            if collapseAfterPrompt {
                collapse() // the paste goes to the app the keyword was typed in
            } else if let status {
                showStatus(status)
            } else {
                setPhase(.expanded, animated: true)
            }
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menusTracking += 1 }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menusTracking = max(0, (self?.menusTracking ?? 1) - 1) }
        })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        installPointerMonitors()
        place()
    }

    private var wakeObserver: (any NSObjectProtocol)?
    private var pointerMonitors: [Any] = []
    private var pointerInside = false

    /// The window server sends no tracking-area events for a window on the notch, so
    /// the island watches mouse-moved events instead: the global monitor covers the
    /// pointer over other apps, the local one the island itself. The handler is a
    /// single rect test, and nothing runs while the pointer is still.
    private func installPointerMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        })
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        })
        pointerMonitors = [global, local].compactMap { $0 }
    }

    private func pointerMoved() {
        guard model.geometry != nil, !hidden, window.isVisible else { return }
        let location = NSEvent.mouseLocation
        // The drawn shapes, not the (mostly transparent) window. The pointer stops at
        // the very top edge (y == maxY), which must count as inside.
        let frame = model.shapeRect(for: model.phase)
        let inside = location.x >= frame.minX && location.x <= frame.maxX
            && location.y >= frame.minY && location.y <= frame.maxY
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside { pointerEntered() } else { pointerExited() }
    }

    /// For diagnostics: the island's window, to capture it.
    var windowNumber: Int { window.windowNumber }

    /// Removes the island; the controller is dropped afterwards.
    func tearDown() {
        closeTask?.cancel()
        flashTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        pointerMonitors.forEach { NSEvent.removeMonitor($0) }
        pointerMonitors.removeAll()
        removeOutsideClickMonitor()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        window.orderOut(nil)
        window.close()
    }

    // MARK: - Placement

    /// The notched screen if there is one, otherwise the primary display (unless the
    /// pill is turned off for plain displays).
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
        return preferences.dynamicIslandOnPlainDisplays ? screens.first : nil
    }

    func place() {
        guard let screen = targetScreen() else {
            model.geometry = nil
            window.orderOut(nil)
            Log.app.info("Dynamic Island: no eligible display")
            return
        }
        let metrics = ScreenMetrics(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )
        let geometry = IslandGeometry(screen: metrics, panelSize: IslandPanel.size)
        model.geometry = geometry
        setPhase(.collapsed, animated: false)
        fitWindow()
        if !hidden { window.orderFrontRegardless() }
        Log.app.info("Dynamic Island on \(screen.localizedName, privacy: .public) notch=\(metrics.hasNotch) rect=\(String(describing: geometry.collapsed), privacy: .public)")
    }

    /// The window always holds the widest shape (the open panel at its current width)
    /// plus shadow room; only the drawn shape animates.
    private func fitWindow() {
        guard let geometry = model.geometry else { return }
        let rect = geometry.windowRect(for: .expanded, contentWidth: model.panelWidth)
        guard window.frame != rect else { return }
        window.setFrame(rect, display: true)
    }

    /// Hidden for the duration of a capture flow so the selection overlay can't open it.
    func setHidden(_ hidden: Bool) {
        guard self.hidden != hidden else { return }
        self.hidden = hidden
        if hidden {
            collapse(animated: false)
            window.orderOut(nil)
        } else if model.geometry != nil {
            window.orderFrontRegardless()
            if let item = pendingFlash {
                pendingFlash = nil
                flash(item)
            }
        }
    }

    // MARK: - Phases

    func expand() {
        guard model.geometry != nil, !hidden, model.phase != .expanded else { return }
        closeTask?.cancel()
        flashTask?.cancel()
        hoverTask?.cancel()
        window.orderFrontRegardless()
        if let tab = preferences.islandOpensOn {
            UserDefaults.standard.set(tab.rawValue, forKey: IslandTab.storageKey)
        }
        setPhase(.expanded, animated: true)
        // With no closing on leave (or in click mode) a click outside is the way out.
        if !preferences.islandCloseOnLeave || preferences.islandOpenMode == .click {
            installOutsideClickMonitor(forExpanded: true)
        }
    }

    func collapse(animated: Bool = true) {
        flashTask?.cancel()
        closeTask?.cancel()
        hoverTask?.cancel()
        guard model.phase != .collapsed else { return }
        removeOutsideClickMonitor()
        setPhase(.collapsed, animated: animated)
        if animated {
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: Self.collapseAnimation)
                guard !Task.isCancelled else { return }
                self?.didCollapse()
            }
        } else {
            didCollapse()
        }
    }

    /// Show the capture that was just taken for a moment; hovering it meanwhile opens
    /// the full panel instead.
    func flash(_ item: CaptureItem) {
        guard preferences.islandFlashCaptures else { return }
        if hidden {
            pendingFlash = item
            return
        }
        flash(phase: .flash(item))
    }

    /// Shrinks the open island to a small box with a text field; the answer comes
    /// back through `onPromptFinished`. A click anywhere outside the box cancels it.
    func prompt(_ prompt: IslandPrompt) {
        guard model.geometry != nil else { return }
        closeTask?.cancel()
        flashTask?.cancel()
        setPhase(.prompt(prompt), animated: true)
        installOutsideClickMonitor()
        if prompt.isConfirm { window.makeKey() } // so ⎋ / ↩ reach the box
    }

    /// Opens a task in the compact island; a click outside closes the island, ⎋
    /// goes back to the panel.
    func showTask(_ task: TaskItem) {
        guard model.geometry != nil else { return }
        closeTask?.cancel()
        flashTask?.cancel()
        setPhase(.taskDetail(task.id), animated: true)
        installOutsideClickMonitor()
        window.makeKey() // so ⎋ reaches the island
    }

    /// Opens the clock in the compact island; ⎋ or a click outside closes it.
    func showClock() {
        guard model.geometry != nil, model.phase != .clock else { return }
        closeTask?.cancel()
        flashTask?.cancel()
        setPhase(.clock, animated: true)
        installOutsideClickMonitor()
        window.makeKey() // so ⎋ reaches the island
    }

    /// Applies a rename from the compact box to the right store.
    private func renamed(_ detail: IslandDetail, to name: String) {
        switch detail {
        case .capture(let item): library.rename(item, to: name)
        case .asset(let item): assets.rename(item, to: name)
        case .clipboard(let item): clipboard.rename(item, to: name)
        case .color(let entry): colors.rename(entry, to: name)
        }
    }

    /// ⎋: back out of a compact phase to the panel; from the panel, close the island.
    private func escape() {
        switch model.phase {
        case .taskDetail:
            model.onTaskDetailClosed(nil)
        case .clock:
            model.onClockClosed()
        case .prompt(let prompt):
            model.onPromptFinished(prompt, nil)
        default:
            collapse()
        }
    }

    /// Typing must go back to the user's app once the island no longer needs the
    /// keyboard; re-ordering front without key is the only way to drop it.
    private func resignKeyIfNeeded() {
        guard window.isKeyWindow else { return }
        window.orderOut(nil)
        if !hidden { window.orderFrontRegardless() }
    }

    private var outsideClickMonitors: [Any] = []

    /// `forExpanded`: the open panel closes on a click outside too (click mode, or
    /// when it does not close on leaving).
    private func installOutsideClickMonitor(forExpanded: Bool = false) {
        removeOutsideClickMonitor()
        let handler: @MainActor () -> Void = { [weak self] in
            guard let self, model.geometry != nil else { return }
            switch model.phase {
            case .prompt, .taskDetail, .clock: break
            case .expanded where forExpanded: break
            default: return
            }
            if !model.shapeRect(for: model.phase).contains(NSEvent.mouseLocation) { collapse() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { handler() }
        }) {
            outsideClickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            MainActor.assumeIsolated { handler() }
            return event
        }) {
            outsideClickMonitors.append(local)
        }
    }

    private func removeOutsideClickMonitor() {
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideClickMonitors.removeAll()
    }

    /// Shows a confirmation on the island for a moment: the closed notch grows into
    /// it, the open panel shrinks to it. False when the island is not on screen.
    @discardableResult
    /// `quiet`: an unprompted status (the time, a prayer) that must not interrupt
    /// the open panel or a form — it is dropped unless the island is closed.
    func showStatus(_ status: IslandStatus, quiet: Bool = false) -> Bool {
        guard model.geometry != nil, !hidden, preferences.islandStatuses || status.clock != nil else { return false }
        if quiet, model.phase != .collapsed, !model.phase.isFlash { return false }
        flash(phase: .status(status), overPanel: !quiet)
        return true
    }

    /// `overPanel`: replace the open panel (or compact box) too, rather than only
    /// flashing the closed island. Afterwards the island closes — or opens again if
    /// the pointer is still on it.
    private func flash(phase: IslandModel.Phase, overPanel: Bool = false) {
        guard model.geometry != nil, overPanel || model.phase == .collapsed || model.phase.isFlash else { return }
        flashTask?.cancel()
        closeTask?.cancel()
        removeOutsideClickMonitor()
        window.orderFrontRegardless()
        setPhase(phase, animated: true)
        let duration: Duration = if case .status(let status) = phase { status.duration } else { .seconds(preferences.islandFlashDuration) }
        let isClock = if case .status(let status) = phase { status.clock != nil } else { false }
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, model.phase.isFlash else { return }
            // A pointer resting on a flash opens the panel; the clock just closes.
            if !isClock, model.shapeRect(for: model.phase).contains(NSEvent.mouseLocation) {
                pointerInside = true
                expand()
            } else {
                collapse()
            }
        }
    }

    private func setPhase(_ phase: IslandModel.Phase, animated: Bool) {
        if animated {
            let animation = phase == .collapsed ? IslandView.closeAnimation : IslandView.openAnimation
            withAnimation(animation) { model.phase = phase }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.phase = phase }
        }
    }

    /// Giving up key status (if a control inside took it) returns typing to the
    /// user's app; re-ordering front without key is the only way to drop it.
    private func didCollapse() {
        guard model.phase == .collapsed else { return }
        pointerInside = false
        if window.isKeyWindow {
            window.orderOut(nil)
            if !hidden { window.orderFrontRegardless() }
        }
    }

    // MARK: - Drops

    /// A file or image dragged over the island: open on the Assets tab and show the
    /// drop hint.
    private func dragEntered() {
        // A card of the island's own, on its way to a group chip — not a file arriving.
        guard IslandDrag.current == nil else { return }
        UserDefaults.standard.set(IslandTab.assets.rawValue, forKey: IslandTab.storageKey)
        expand()
        model.dropping = true
    }

    private func drop(urls: [URL], image: Data?, into assets: AssetStore) {
        model.dropping = false
        var added = assets.add(fileURLs: urls)
        if let image, let item = assets.add(imageData: image) { added.append(item) }
        if added.isEmpty {
            FeedbackHUD.show("Nothing to save", symbol: "tray")
        } else {
            FeedbackHUD.show(added.count == 1 ? "Saved to Assets" : "\(added.count) saved to Assets", symbol: "tray.and.arrow.down.fill", duration: .seconds(1.2))
        }
    }

    // MARK: - Pointer

    private func pointerEntered() {
        closeTask?.cancel()
        // The compact prompt / task detail stay as they are until ↩, ⎋ or a click
        // outside; the pointer does not reopen the panel.
        switch model.phase {
        case .prompt, .taskDetail, .clock: return
        case .status(let status) where status.clock != nil:
            // The clock ignores the pointer: it neither opens the panel nor stays;
            // a click opens the clock view, otherwise it closes on its own.
            return
        default: break
        }
        guard model.phase != .expanded else { return }
        // A flash opens at once when hovered; the closed island waits for the delay
        // — or, in click mode, for a click.
        if model.phase.isFlash {
            expand()
        } else if preferences.islandOpenMode == .hover {
            let delay = preferences.islandHoverDelay
            guard delay > 0 else { expand(); return }
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                guard !Task.isCancelled, let self, pointerInside else { return }
                expand()
            }
        }
    }

    private func pointerExited() {
        hoverTask?.cancel()
        guard model.phase == .expanded, preferences.islandCloseOnLeave else { return }
        closeTask?.cancel()
        let delay = preferences.islandCloseDelay
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            // A drag out of the panel or an open menu keeps it open until they finish.
            while !Task.isCancelled, let self, NSEvent.pressedMouseButtons != 0 || menusTracking > 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, let self else { return }
            if model.shapeRect(for: model.phase).contains(NSEvent.mouseLocation) {
                pointerInside = true
                return
            }
            collapse()
        }
    }
}
