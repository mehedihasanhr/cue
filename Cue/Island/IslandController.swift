import os
import AppKit
import CoreLocation
import SwiftUI

/// Owns the Dynamic Island: places it on the notch (or as a pill on a plain display),
/// opens the captures panel when the pointer rests on it, closes it when the pointer
/// leaves, and flashes each new capture.
@MainActor
final class IslandController {
    private let window = IslandWindow()
    /// The pane under the island for an opened card, made when first needed.
    private var previewPane: PreviewPaneWindow?
    private let previewModel = PreviewPaneModel()
    private var previewDetail: IslandDetail? { previewModel.detail }
    private let model = IslandModel()
    /// Files parked in the island for now (this session only).
    let shelf = ShelfStore()
    /// What Music or Spotify plays.
    let nowPlaying = NowPlaying()
    /// The charger going in or out, the battery running low; nil without a battery.
    private var battery: BatteryMonitor?
    /// AirPods and other Bluetooth audio devices coming and going.
    private var audioDevices: AudioDeviceMonitor?
    /// Caps Lock and Focus switching.
    private var toggles: ToggleMonitor?
    /// The network, drives and downloads.
    private var notices: NoticeMonitor?
    /// The user's calendar, once they turn it on.
    let calendar = CalendarWatcher()
    /// The weather, once it is turned on.
    let weather = WeatherStore()
    private let preferences: AppPreferences
    private let tasks: TaskStore
    private let snippets: SnippetStore
    private let notes: NoteStore
    private let actions: HistoryActions
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
    /// How long the close animation runs, at the island's pace.
    private static var collapseAnimation: Duration { .seconds(IslandMotion.response(0.38)) }

    /// A snippet's blanks were filled in the compact box (nil: cancelled); set by
    /// the app delegate.
    var onSnippetFilled: (Snippet, [String: String]?) -> Void = { _, _ in }
    /// The Tasks tab asked for the dashboard window; set by the app.
    var onOpenTaskDashboard: () -> Void = {}

    init(library: CaptureLibrary, clipboard: ClipboardHistory, assets: AssetStore, colors: ColorStore, groups: GroupStore, tasks: TaskStore, snippets: SnippetStore,
         notes: NoteStore, actions: HistoryActions, preferences: AppPreferences, clock: PrayerClock? = nil, focus: FocusTimer? = nil, agents: AgentStore? = nil) {
        self.preferences = preferences
        self.tasks = tasks
        self.snippets = snippets
        self.notes = notes
        self.actions = actions
        self.library = library
        self.clipboard = clipboard
        self.assets = assets
        self.colors = colors
        self.groups = groups

        let content = IslandDropView(frame: CGRect(origin: .zero, size: window.frame.size))
        content.onDragEntered = { [weak self] in self?.dragEntered() }
        content.onDragExited = { [weak self] in self?.model.dropping = false }
        content.onDragMoved = { [weak self] point in self?.aimDrop(at: point) }
        content.onDrop = { [weak self] urls, image in self?.drop(urls: urls, image: image, into: assets) }
        let host = FirstMouseHostingView(rootView: IslandView(model: model, library: library, clipboard: clipboard, assets: assets, colors: colors, tasks: tasks, snippets: snippets, actions: actions)
            .environment(preferences).environment(clock).environment(focus).environment(groups).environment(notes).environment(shelf).environment(nowPlaying).environment(weather))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = content.bounds
        content.addSubview(host)
        window.contentView = content
        window.onEscape = { [weak self] in self?.escape() }
        shelf.onEmptied = { [weak self] in self?.shelfEmptied() }
        nowPlaying.isEnabled = { [weak preferences] in preferences?.islandNowPlaying ?? false }
        nowPlaying.start()
        model.nowPlaying = nowPlaying
        model.focus = focus
        model.calendar = calendar
        model.weather = weather
        model.onShowWeather = { [weak self] in self?.showWeather() }
        weather.knownPlace = { [weak clock] in clock?.place.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
        model.onOpenURL = { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.collapse()
        }
        calendar.onAlert = { [weak self] meeting in self?.showMeeting(meeting) }
        applyCalendarPreference()
        applyWeatherPreference()
        model.compactTiles = { [weak self, weak preferences, weak focus] in
            guard let self, let preferences, preferences.islandCompactTiles else { return CompactTiles() }
            #if DEBUG
            // Diagnostics: `--env CUE_DEBUG_TILES=clock,battery` shows those two, whatever the settings say.
            if let debug = ProcessInfo.processInfo.environment["CUE_DEBUG_TILES"]?.split(separator: ","), debug.count == 2 {
                return CompactTiles(left: CompactTile(rawValue: String(debug[0])) ?? .none, right: CompactTile(rawValue: String(debug[1])) ?? .none)
            }
            #endif
            // Music playing takes both sides: its artwork, and Cue dancing to it.
            if preferences.islandTilesNowPlaying, preferences.islandNowPlaying, nowPlaying.track != nil, nowPlaying.isPlaying {
                return CompactTiles(left: .artwork, right: .critter)
            }
            // A focus tile with no session running shows nothing.
            let focusing = focus?.isRunning == true
            let left = preferences.islandTileLeft, right = preferences.islandTileRight
            return CompactTiles(left: left == .focus && !focusing ? .none : left, right: right == .focus && !focusing ? .none : right)
        }
        model.nowPlayingEnabled = { [weak preferences] in preferences?.islandNowPlaying ?? false }
        model.onTap = { [weak self] in self?.open() }
        model.agents = agents
        model.onOpenPanel = { [weak self] in self?.expand() }
        model.onAgentsClosed = { [weak self] in self?.collapse() }
        agents?.onRequest = { [weak self] _ in self?.agentAsked() }
        agents?.onRequestsCleared = { [weak self] in self?.agentQuestionsAnswered() }
        agents?.onFinished = { [weak self] session, took in self?.agentFinished(session, took: took) }
        model.onPrompt = { [weak self] prompt in self?.prompt(prompt) }
        model.onShowTask = { [weak self] task in self?.showTask(task) }
        model.onOpenTaskDashboard = { [weak self] in
            self?.collapse()
            self?.onOpenTaskDashboard()
        }
        model.onPanelWidthChanged = { [weak self] in
            // Reported from inside a layout pass; the window resizes after it.
            DispatchQueue.main.async { self?.fitWindow(); self?.placePreview() }
        }
        model.onShowClock = { [weak self] in self?.showClock() }
        model.onShowMedia = { [weak self] in self?.showMedia() }
        model.onHoldStatus = { [weak self] in self?.holdStatus() }
        model.onReveal = { [weak self] url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self?.collapse()
        }
        model.onPreviewPane = { [weak self] detail, direction in self?.showPreview(detail, direction: direction) }
        model.onHidePreview = { [weak self] in self?.hidePreview() }
        model.isPointerInPreview = { [weak self] in self?.pointerInPreview() ?? false }
        window.onArrow = { [weak self] delta in
            guard let self, model.phase == .expanded else { return }
            model.arrowPress = (delta, model.arrowPress.tick + 1)
        }
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
        model.onMediaClosed = model.onClockClosed
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
        let guarded = IslandDragGuard.start { [weak self] in self?.dragEntered() }
        Log.app.info("Island drag guard: \(guarded ? "on" : "off (needs Accessibility)", privacy: .public)")
        // The volume and brightness keys, while the island is closed (or flashing) and
        // free to show them; otherwise the system's overlay, as before.
        LevelKeys.isEnabled = { [weak self] in
            guard let self, preferences.islandLevelHUD, model.geometry != nil, !hidden else { return false }
            return model.phase == .collapsed || model.phase.isFlash
        }
        battery = BatteryMonitor { [weak self] hud in self?.showBattery(hud) }
        audioDevices = AudioDeviceMonitor { [weak self] hud in self?.showAudioDevice(hud) }
        toggles = ToggleMonitor { [weak self] hud in self?.showToggle(hud) }
        notices = NoticeMonitor { [weak self] notice in self?.showNotice(notice) }
        let levels = LevelKeys.start { [weak self] level in self?.showLevel(level) }
        Log.app.info("Island level keys: \(levels ? "on" : "off (needs Accessibility)", privacy: .public); volume settable: \(SystemLevels.canSetVolume); brightness: \(SystemLevels.brightness.map { String($0) } ?? "unavailable", privacy: .public)")
        place()
    }

    private var wakeObserver: (any NSObjectProtocol)?
    private var pointerMonitors: [Any] = []
    private var pointerInside = false
    /// The left button is down (from the press events, which also covers presses the
    /// hardware state misses), and the drag pasteboard's change count at that press.
    private var pressed = false
    private var dragCountAtPress = NSPasteboard(name: .drag).changeCount

    private func pressChanged(down: Bool) {
        pressed = down
        if down { dragCountAtPress = NSPasteboard(name: .drag).changeCount }
    }

    /// The button is held, carrying nothing to drop: a window on its way to another
    /// Space, a selection, a slider. Not files, which write the drag pasteboard.
    private var pressWithoutDrop: Bool {
        pressed && NSPasteboard(name: .drag).changeCount == dragCountAtPress
    }

    /// The window server sends no tracking-area events for a window on the notch, so
    /// the island watches mouse-moved events instead: the global monitor covers the
    /// pointer over other apps, the local one the island itself. The handler is a
    /// single rect test, and nothing runs while the pointer is still.
    private func installPointerMonitors() {
        // Moving with no button down also means any press is over, should its release
        // have gone unseen (a drag session out of the island swallows it).
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            let released = event.type == .mouseMoved
            MainActor.assumeIsolated {
                if released { self?.pressed = false }
                self?.pointerMoved()
            }
        })
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            let released = event.type == .mouseMoved
            MainActor.assumeIsolated {
                if released { self?.pressed = false }
                self?.pointerMoved()
            }
            return event
        })
        // Two-finger swipes over the island move between the agents list and the panel.
        let swipes = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.swipe(event) ?? false } ? nil : event
        })
        // Every press notes the drag pasteboard, so a drag passing over the island can
        // tell files (a drag and drop writes it) from a window being moved.
        let presses = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { [weak self] event in
            let down = event.type == .leftMouseDown
            MainActor.assumeIsolated { self?.pressChanged(down: down) }
        })
        let localPresses = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { [weak self] event in
            let down = event.type == .leftMouseDown
            MainActor.assumeIsolated { self?.pressChanged(down: down) }
            return event
        })
        pointerMonitors = [global, local, swipes, presses, localPresses].compactMap { $0 }
    }

    // MARK: - Swipes

    /// Horizontal travel of the current two-finger gesture, as the fingers moved
    /// (not as the content would scroll), and whether it has already switched.
    private var swipeTravel: CGSize = .zero
    private var swipeDone = false
    /// How far the fingers travel sideways before the island switches.
    private static let swipeThreshold: CGFloat = 70

    /// The agents list and the panel are two pages side by side: fingers moving left
    /// bring in the panel, right bring back the agents. On the panel only its top
    /// (search and tabs) takes the swipe — its card rows scroll sideways themselves.
    /// Returns whether the event was used up.
    private func swipe(_ event: NSEvent) -> Bool {
        guard event.window === window, event.hasPreciseScrollingDeltas, model.showsAmbient else { return false }
        guard model.phase == .agents || (model.phase == .expanded && pointerInPanelTop()) else { return false }
        if event.momentumPhase != [] { return swipeDone } // the glide after the fingers lift
        if event.phase == .began || event.phase == .mayBegin {
            swipeTravel = .zero
            swipeDone = false
        }
        // Scrolling deltas follow the content; flip them back to the fingers' direction.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipeTravel.width += event.scrollingDeltaX * sign
        swipeTravel.height += abs(event.scrollingDeltaY)
        if event.phase == .ended || event.phase == .cancelled {
            defer { swipeTravel = .zero }
            return swipeDone
        }
        guard !swipeDone, abs(swipeTravel.width) > Self.swipeThreshold, abs(swipeTravel.width) > swipeTravel.height * 2 else {
            // Mostly sideways so far: keep it from also scrolling the list under it.
            return model.phase == .agents && abs(swipeTravel.width) > swipeTravel.height
        }
        swipeDone = true
        if swipeTravel.width < 0, model.phase == .agents {
            expand()
        } else if swipeTravel.width > 0, model.phase == .expanded {
            showAgents()
        }
        return true
    }

    /// Whether the pointer is over the open panel's header: the search bar and tabs,
    /// below the notch strip.
    private func pointerInPanelTop() -> Bool {
        guard let geometry = model.geometry else { return false }
        let shape = model.shapeRect(for: .expanded)
        let location = NSEvent.mouseLocation
        return shape.contains(location) && location.y > shape.maxY - geometry.stripHeight - 110
    }

    private func pointerMoved() {
        guard model.geometry != nil, !hidden, window.isVisible else { return }
        let location = NSEvent.mouseLocation
        // The drawn shapes, not the (mostly transparent) window. The pointer stops at
        // the very top edge (y == maxY), which must count as inside.
        let inside = contains(location)
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside { pointerEntered() } else { pointerExited() }
    }

    /// For diagnostics: the island's window, to capture it.
    var windowNumber: Int { window.windowNumber }
    /// For diagnostics: the keyboard goes to the island, as after a click in it.
    func debugMakeKey() { window.makeKey() }
    /// For diagnostics: the island as while a file is dragged over it.
    func debugShowDropZone() { dragEntered() }
    /// For diagnostics: the drop zone saying one file was saved, held until the next drag.
    func debugShowDropSaved() {
        dragEntered()
        model.dropSaved = IslandDropZone.Saved(count: 1, target: .shelf)
        model.dropping = false
    }
    /// For diagnostics: the open shape, in screen coordinates.
    var debugExpandedRect: CGRect { model.shapeRect(for: .expanded) }

    /// The island's drawn shape, and the preview pane under it (with the gap
    /// between): what the pointer may rest on without the island closing.
    private func contains(_ location: CGPoint) -> Bool {
        let shape = model.shapeRect(for: model.phase)
        if location.x >= shape.minX, location.x <= shape.maxX, location.y >= shape.minY, location.y <= shape.maxY { return true }
        guard let pane = previewPane, pane.isVisible, model.phase == .expanded else { return false }
        var frame = pane.frame
        frame.size.height += PreviewPaneWindow.gap
        return frame.contains(location)
    }

    // MARK: - Preview pane

    /// Shows the card in the pane under the island (Settings › Island › Preview opens).
    /// An open pane slides to the next item in `direction` (+1: from the right).
    func showPreview(_ detail: IslandDetail, direction: Int = 0) {
        let pane = previewPane ?? PreviewPaneWindow()
        if previewPane == nil {
            previewPane = pane
            let root = PreviewPaneRoot(model: previewModel, library: library, clipboard: clipboard, assets: assets, colors: colors, notes: notes, tasks: tasks,
                                       actions: actions, onEdit: { [weak self] in self?.edit($0) }, onClose: { [weak self] in self?.hidePreview() },
                                       onLeave: { [weak self] in self?.model.previewLeaveTick += 1 })
                .environment(preferences)
            let host = FirstMouseHostingView(rootView: root)
            host.sizingOptions = []
            pane.contentView = host
        }
        guard previewModel.detail?.id != detail.id else { return }
        if pane.isVisible, previewModel.detail != nil {
            // The view leaving takes the transition it was last drawn with: a changed
            // direction is drawn once before the item changes, or it would leave the wrong way.
            let turned = previewModel.direction != direction
            previewModel.direction = direction
            let slide = { withAnimation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: IslandMotion.response(0.32))) { self.previewModel.detail = detail } }
            if turned { DispatchQueue.main.async(execute: slide) } else { slide() }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { previewModel.detail = detail }
        }
        model.previewOpen = true
        placePreview()
        pane.orderFrontRegardless()
    }

    func hidePreview() {
        previewModel.detail = nil
        model.previewOpen = false
        previewPane?.orderOut(nil)
    }

    /// Whether the pointer is over the visible pane, or the gap between it and the island.
    private func pointerInPreview() -> Bool {
        guard let pane = previewPane, pane.isVisible else { return false }
        var frame = pane.frame
        frame.size.height += PreviewPaneWindow.gap
        return frame.contains(NSEvent.mouseLocation)
    }

    /// Under the island's open shape, as wide as it, with a gap.
    private func placePreview() {
        guard let pane = previewPane, let detail = previewDetail else { return }
        let shape = model.shapeRect(for: .expanded)
        let height = PreviewPaneView.height(for: detail, clipboard: clipboard)
        let rect = CGRect(x: shape.minX, y: shape.minY - PreviewPaneWindow.gap - height, width: shape.width, height: height)
        if pane.frame != rect { pane.setFrame(rect, display: true) }
    }

    /// The pane's Edit: a note or a task opens in the compact island's form.
    private func edit(_ detail: IslandDetail) {
        switch detail {
        case .note(let note): prompt(IslandPrompt(kind: .note(note)))
        case .task(let task): prompt(IslandPrompt(kind: .task(project: task.projectID), editing: task))
        default: break
        }
    }

    /// Removes the island; the controller is dropped afterwards.
    func tearDown() {
        battery?.stop()
        audioDevices?.stop()
        toggles?.stop()
        notices?.stop()
        calendar.stop()
        weather.stop()
        nowPlaying.stop()
        LevelKeys.stop()
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
            IslandDragGuard.active = false
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
        if let screen = targetScreen() {
            IslandDragGuard.update(span: rect.minX...rect.maxX, on: screen)
            IslandDragGuard.active = !hidden
        }
        guard window.frame != rect else { return }
        window.setFrame(rect, display: true)
    }

    /// Hidden for the duration of a capture flow so the selection overlay can't open it.
    func setHidden(_ hidden: Bool) {
        guard self.hidden != hidden else { return }
        self.hidden = hidden
        IslandDragGuard.active = !hidden && model.geometry != nil
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

    /// What a hover or click on the closed island opens: the agent sessions while
    /// any run, otherwise the panel.
    func open() {
        if model.showsAmbient { showAgents() } else { expand() }
    }

    /// Opens the agent sessions list.
    func showAgents() {
        guard model.geometry != nil, !hidden, model.agents != nil, model.phase != .agents else { return }
        closeTask?.cancel()
        flashTask?.cancel()
        hoverTask?.cancel()
        window.orderFrontRegardless()
        setPhase(.agents, animated: true)
        installOutsideClickMonitor()
    }

    /// An agent asked something: open on it, unless the user is in the middle of
    /// typing into the island (a form, a prompt) — the closed island pulses instead.
    private func agentAsked() {
        guard preferences.agentAutoOpen, model.geometry != nil, !hidden else { return }
        switch model.phase {
        case .collapsed, .flash, .status, .expanded: showAgents()
        case .agents, .prompt, .taskDetail, .clock, .media, .weather: break
        }
    }

    /// The last question was answered: close again unless the pointer is on the list.
    private func agentQuestionsAnswered() {
        guard model.phase == .agents else { return }
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, model.phase == .agents, model.agents?.requests.isEmpty != false else { return }
            if !contains(NSEvent.mouseLocation) { collapse() }
        }
    }

    /// An agent finished its turn: the closed island says so for a moment. An open
    /// island already shows it in its list, so it is left alone.
    private func agentFinished(_ session: AgentSession, took: Duration) {
        guard !hidden, model.phase == .collapsed || model.phase.isFlash else { return }
        let done = AgentDone(agent: session.agent, project: session.project, took: took, summary: session.activity)
        flash(phase: .status(IslandStatus(symbol: "checkmark.circle.fill", title: "Task complete", subtitle: session.project,
                                          duration: .seconds(3.6), agentDone: done)))
    }

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

    /// The volume or brightness just changed: the island shows it in place of the
    /// system's overlay. Only over the closed island (or another flash): with a panel
    /// open the keys are left to the system (see `start`), so nothing is covered.
    private func showLevel(_ level: LevelHUD) {
        guard case .status(let current) = model.phase, let shown = current.level, shown.kind == level.kind else {
            flash(phase: .status(IslandStatus(symbol: level.symbol, title: "", duration: Self.levelDuration, level: level)))
            return
        }
        // Already up: the bar moves; the same view stays (no new entrance), and it holds.
        model.phase = .status(IslandStatus(symbol: level.symbol, title: "", duration: Self.levelDuration, level: level))
        holdStatus()
    }

    private static let levelDuration: Duration = .milliseconds(1500)

    /// Watches the calendar while meeting alerts or a calendar tile are on (macOS asks
    /// for access the first time), and stops when neither is.
    private func applyCalendarPreference() {
        let wanted = withObservationTracking {
            preferences.islandCalendar || (preferences.islandCompactTiles && (preferences.islandTileLeft == .calendar || preferences.islandTileRight == .calendar))
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyCalendarPreference() }
        }
        if wanted { calendar.start() } else { calendar.stop() }
    }

    /// A meeting starts in five minutes: the island says so, with Join for a call.
    func showMeeting(_ meeting: MeetingHUD) {
        guard preferences.islandCalendar, model.geometry != nil, !hidden else { return }
        flash(phase: .status(IslandStatus(symbol: "calendar", title: meeting.title, duration: .seconds(12), meeting: meeting)))
    }

    /// The network changed, a drive came or went, a download finished. Going offline
    /// comes over an open panel too; the rest only over the closed island.
    func showNotice(_ notice: NoticeHUD) {
        switch notice.kind {
        case .offline, .online, .vpnOn, .vpnOff: guard preferences.islandNetwork else { return }
        case .driveMounted, .driveEjected: guard preferences.islandDrives else { return }
        case .downloaded: guard preferences.islandDownloads else { return }
        }
        guard model.geometry != nil, !hidden else { return }
        let duration: Duration = notice.kind == .downloaded ? .seconds(4) : .milliseconds(2600)
        flash(phase: .status(IslandStatus(symbol: notice.symbol, title: notice.title, duration: duration, notice: notice)), overPanel: notice.kind == .offline)
    }

    /// Caps Lock or a Focus switched: a moment's HUD over the closed island.
    func showToggle(_ hud: ToggleHUD) {
        switch hud.kind {
        case .capsLock: guard preferences.islandCapsLock else { return }
        case .focus: guard preferences.islandFocus else { return }
        }
        guard model.geometry != nil, !hidden else { return }
        flash(phase: .status(IslandStatus(symbol: hud.symbol, title: hud.title, duration: .milliseconds(1400), toggle: hud)))
    }

    /// AirPods or another Bluetooth audio device connected or went. Only over the
    /// closed island; its batteries, read a moment later, fill in the same HUD.
    func showAudioDevice(_ hud: AudioDeviceHUD) {
        guard preferences.islandAudioDevices, model.geometry != nil, !hidden else { return }
        let status = IslandStatus(symbol: hud.symbol, title: hud.name, duration: hud.connected ? .seconds(3) : .milliseconds(1600), audioDevice: hud)
        if case .status(let current) = model.phase, let shown = current.audioDevice, shown.name == hud.name, shown.connected == hud.connected {
            withAnimation(.easeOut(duration: 0.25)) { model.phase = .status(status) }
            return
        }
        flash(phase: .status(status))
    }

    /// The charger went in or out, or the battery runs low. Low battery comes over an
    /// open panel too; the rest only over the closed island, as a status would.
    func showBattery(_ hud: BatteryHUD) {
        guard preferences.islandBattery, model.geometry != nil, !hidden else { return }
        let status = IslandStatus(symbol: "battery.100", title: hud.title, duration: hud.event == .low ? .seconds(4) : .milliseconds(2600), battery: hud)
        flash(phase: .status(status), overPanel: hud.event == .low)
    }

    #if DEBUG
    /// For diagnostics: the volume HUD at 60%.
    func debugShowLevel() {
        flash(phase: .status(IslandStatus(symbol: "speaker.wave.2.fill", title: "", duration: .seconds(6), level: LevelHUD(kind: .volume, value: 0.6))))
    }
    #endif

    /// Restarts the countdown of the level showing.
    private func holdStatus() {
        guard case .status(let status) = model.phase, status.level != nil else { return }
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: Self.levelDuration)
            guard !Task.isCancelled, let self, model.phase.isFlash else { return }
            // Still dragging: once more.
            if NSEvent.pressedMouseButtons != 0 { holdStatus(); return }
            collapse()
        }
    }

    /// Opens the forecast in the island; ⎋ or a click outside closes it.
    func showWeather() {
        guard model.geometry != nil, model.phase != .weather else { return }
        closeTask?.cancel()
        flashTask?.cancel()
        setPhase(.weather, animated: true)
        installOutsideClickMonitor()
        window.makeKey() // so ⎋ reaches the island
    }

    /// Fetches the weather while it is on, or a weather tile is.
    private func applyWeatherPreference() {
        let wanted = withObservationTracking {
            preferences.islandWeather || (preferences.islandCompactTiles && (preferences.islandTileLeft == .weather || preferences.islandTileRight == .weather))
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyWeatherPreference() }
        }
        if wanted { weather.start() } else { weather.stop() }
    }

    /// Opens the music player in the island; ⎋ or a click outside closes it.
    func showMedia() {
        guard model.geometry != nil, model.phase != .media else { return }
        closeTask?.cancel()
        flashTask?.cancel()
        setPhase(.media, animated: true)
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
        case .note, .task: break
        }
    }

    /// ⎋: back out of a compact phase to the panel; from the panel, close the island.
    private func escape() {
        switch model.phase {
        case .taskDetail:
            model.onTaskDetailClosed(nil)
        case .clock:
            model.onClockClosed()
        case .media:
            model.onMediaClosed()
        case .weather:
            model.onMediaClosed()
        case .prompt(let prompt):
            model.onPromptFinished(prompt, nil)
        default:
            collapse() // the agents list too: its questions stay open, and the closed island pulses
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
            // The task form closes only by its own Cancel / Create or ⎋.
            case .prompt(let prompt) where prompt.isTaskForm: return
            case .prompt, .taskDetail, .clock, .media, .weather, .agents: break
            case .expanded where forExpanded: break
            default: return
            }
            // A question waiting on the list keeps it open: a click in another app is
            // the user getting on with their work, not an answer.
            if model.phase == .agents, model.agents?.requests.isEmpty == false { return }
            if !contains(NSEvent.mouseLocation) { collapse() }
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
        // The clock and a level just close: neither is a way into the panel.
        let isClock = if case .status(let status) = phase { status.clock != nil || status.level != nil || status.notice?.isClickable == true || status.meeting?.joinURL != nil } else { false }
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
        if phase != .expanded { hidePreview() }
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

    /// A file or image dragged over the island: open, and show the drop zone with
    /// the card under the pointer lit.
    private func dragEntered() {
        // A card of the island's own, on its way to a group chip, or files leaving
        // the shelf — not files arriving.
        guard IslandDrag.current == nil, !IslandDrag.fromShelf else { return }
        dropSavedTask?.cancel()
        model.dropSaved = nil
        expand()
        model.dropping = true
        aimDrop(at: NSEvent.mouseLocation)
    }

    /// The drop zone's left card is the shelf, its right one Assets.
    private func aimDrop(at point: CGPoint) {
        guard model.dropping else { return }
        let target: IslandDropZone.Target = point.x < model.shapeRect(for: .expanded).midX ? .shelf : .assets
        if model.dropTarget != target { model.dropTarget = target }
    }

    private func drop(urls: [URL], image: Data?, into assets: AssetStore) {
        let target = model.dropTarget
        let added: Int
        switch target {
        case .shelf:
            added = shelf.add(fileURLs: urls) + (image.map { shelf.add(imageData: $0) } ?? 0)
        case .assets:
            added = assets.add(fileURLs: urls).count + (image.flatMap { assets.add(imageData: $0) } == nil ? 0 : 1)
        }
        if added == 0 {
            model.dropping = false
            FeedbackHUD.show(target == .shelf ? "Already on the shelf" : "Nothing to save", symbol: "tray")
            return
        }
        // The panel shows the files where they went: on Assets, or the shelf (over
        // every tab).
        if target == .assets { UserDefaults.standard.set(IslandTab.assets.rawValue, forKey: IslandTab.storageKey) }
        // The drop zone turns to "saved" before the drag's end clears it, so it stays
        // up to say so, then gives way to the panel — or, if the shelf isn't to open
        // after a drop, the island closes.
        model.dropSaved = IslandDropZone.Saved(count: added, target: target)
        model.dropping = false
        dropSavedTask?.cancel()
        dropSavedTask = Task { [weak self] in
            try? await Task.sleep(for: IslandDropZone.savedDuration)
            guard !Task.isCancelled, let self else { return }
            model.dropSaved = nil
            if target == .shelf, !preferences.islandShelfOpenAfterDrop, !contains(NSEvent.mouseLocation) { collapse() }
        }
    }

    /// The shelf emptied (its last files dragged out or cleared): the island closes
    /// with it, unless the pointer is still on it.
    private func shelfEmptied() {
        guard preferences.islandShelfAutoCollapse, model.phase == .expanded, !contains(NSEvent.mouseLocation) else { return }
        collapse()
    }
    private var dropSavedTask: Task<Void, Never>?

    // MARK: - Pointer

    private func pointerEntered() {
        closeTask?.cancel()
        // The compact prompt / task detail stay as they are until ↩, ⎋ or a click
        // outside; the pointer does not reopen the panel.
        switch model.phase {
        case .prompt, .taskDetail, .clock, .media, .weather, .agents: return
        case .status(let status) where status.clock != nil:
            // The clock ignores the pointer: it neither opens the panel nor stays;
            // a click opens the clock view, otherwise it closes on its own.
            return
        default: break
        }
        guard model.phase != .expanded else { return }
        // Something dragged over the island that isn't files (a window being moved to
        // another Space) passes under it without opening it; files open it to drop.
        guard !pressWithoutDrop else { return }
        // A flash opens at once when hovered; the closed island waits for the delay
        // — or, in click mode, for a click.
        if case .status(let status) = model.phase, status.level != nil || status.notice?.isClickable == true || status.meeting?.joinURL != nil {
            // A level is for dragging, a download's notice for clicking: not ways into the panel.
            return
        } else if model.phase.isFlash {
            expand()
        } else if preferences.islandOpenMode == .hover {
            let delay = preferences.islandHoverDelay
            guard delay > 0 else { open(); return }
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                guard !Task.isCancelled, let self, pointerInside, !pressWithoutDrop else { return }
                open()
            }
        }
    }

    private func pointerExited() {
        hoverTask?.cancel()
        // The sessions list stays while an agent waits on it, until answered or ⎋.
        let agentsCanClose = model.phase == .agents && model.agents?.requests.isEmpty != false
        guard model.phase == .expanded || agentsCanClose, preferences.islandCloseOnLeave else { return }
        closeTask?.cancel()
        let delay = preferences.islandCloseDelay
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            // A drag out of the panel or an open menu keeps it open until they finish.
            while !Task.isCancelled, let self, NSEvent.pressedMouseButtons != 0 || menusTracking > 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, let self else { return }
            if contains(NSEvent.mouseLocation) {
                pointerInside = true
                return
            }
            collapse()
        }
    }
}
