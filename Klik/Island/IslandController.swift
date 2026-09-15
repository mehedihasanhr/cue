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
    private let library: CaptureLibrary
    private let clipboard: ClipboardHistory
    private let assets: AssetStore
    private let colors: ColorStore

    private var closeTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    /// Menus (layout picker, context menus) take the pointer away without leaving.
    private var menusTracking = 0
    /// Hidden while a capture flow runs; a capture that lands meanwhile flashes after.
    private var hidden = false
    private var pendingFlash: CaptureItem?
    private var observers: [any NSObjectProtocol] = []

    private static let closeDelay: Duration = .milliseconds(250)
    private static let flashDuration: Duration = .seconds(1.8)
    private static let collapseAnimation: Duration = .milliseconds(380)

    init(library: CaptureLibrary, clipboard: ClipboardHistory, assets: AssetStore, colors: ColorStore, tasks: TaskStore, actions: HistoryActions, preferences: AppPreferences) {
        self.preferences = preferences
        self.tasks = tasks
        self.library = library
        self.clipboard = clipboard
        self.assets = assets
        self.colors = colors

        let content = IslandDropView(frame: CGRect(origin: .zero, size: window.frame.size))
        content.onDragEntered = { [weak self] in self?.dragEntered() }
        content.onDragExited = { [weak self] in self?.model.dropping = false }
        content.onDrop = { [weak self] urls, image in self?.drop(urls: urls, image: image, into: assets) }
        let host = NSHostingView(rootView: IslandView(model: model, library: library, clipboard: clipboard, assets: assets, colors: colors, tasks: tasks, actions: actions).environment(preferences))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = content.bounds
        content.addSubview(host)
        window.contentView = content
        window.onEscape = { [weak self] in self?.escape() }
        model.onTap = { [weak self] in self?.expand() }
        model.onPrompt = { [weak self] prompt in self?.prompt(prompt) }
        model.onShowTask = { [weak self] task in self?.showTask(task) }
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
            if let answer {
                switch prompt.kind {
                case .project(let parent):
                    if let project = tasks.addProject(named: answer.title, in: parent) {
                        tasks.pendingSelection = .project(project.id)
                    }
                case .rename(let detail):
                    renamed(detail, to: answer.title)
                case .task:
                    if let task = prompt.editing {
                        tasks.update(task, title: answer.title, notes: answer.notes, projectID: answer.projectID)
                    } else {
                        tasks.addTask(titled: answer.title, notes: answer.notes, in: answer.projectID)
                    }
                    tasks.pendingSelection = answer.projectID.map { .project($0) } ?? .all
                }
            } else if case .task(let project) = prompt.kind {
                tasks.pendingSelection = project.map { .project($0) } ?? .all
            }
            setPhase(.expanded, animated: true)
            resignKeyIfNeeded()
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
        guard let geometry = model.geometry, !hidden, window.isVisible else { return }
        let location = NSEvent.mouseLocation
        // The drawn shapes, not the (mostly transparent) window. The pointer stops at
        // the very top edge (y == maxY), which must count as inside.
        let frame = geometry.rect(for: model.phase.geometryPhase)
        let inside = location.x >= frame.minX && location.x <= frame.maxX
            && location.y >= frame.minY && location.y <= frame.maxY
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside { pointerEntered() } else { pointerExited() }
    }

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
        window.setFrame(geometry.windowRect, display: true)
        if !hidden { window.orderFrontRegardless() }
        Log.app.info("Dynamic Island on \(screen.localizedName, privacy: .public) notch=\(metrics.hasNotch) rect=\(String(describing: geometry.collapsed), privacy: .public)")
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
        window.orderFrontRegardless()
        setPhase(.expanded, animated: true)
    }

    func collapse(animated: Bool = true) {
        flashTask?.cancel()
        closeTask?.cancel()
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

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        let handler: @MainActor () -> Void = { [weak self] in
            guard let self, let geometry = model.geometry else { return }
            switch model.phase {
            case .prompt, .taskDetail: break
            default: return
            }
            if !geometry.rect(for: model.phase.geometryPhase).contains(NSEvent.mouseLocation) { collapse() }
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

    /// Show the color that was just picked for a moment.
    func flashColor(_ entry: ColorEntry) {
        UserDefaults.standard.set(IslandTab.colors.rawValue, forKey: IslandTab.storageKey)
        flash(phase: .flashColor(entry))
    }

    private func flash(phase: IslandModel.Phase) {
        guard model.geometry != nil, model.phase != .expanded else { return }
        flashTask?.cancel()
        closeTask?.cancel()
        window.orderFrontRegardless()
        setPhase(phase, animated: true)
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flashDuration)
            guard !Task.isCancelled, let self, model.phase.isFlash else { return }
            collapse()
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
        case .prompt, .taskDetail: return
        default: break
        }
        if model.phase != .expanded { expand() }
    }

    private func pointerExited() {
        guard model.phase == .expanded else { return }
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            // A drag out of the panel or an open menu keeps it open until they finish.
            while !Task.isCancelled, let self, NSEvent.pressedMouseButtons != 0 || menusTracking > 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, let self else { return }
            if let geometry = model.geometry, geometry.rect(for: model.phase.geometryPhase).contains(NSEvent.mouseLocation) {
                pointerInside = true
                return
            }
            collapse()
        }
    }
}
