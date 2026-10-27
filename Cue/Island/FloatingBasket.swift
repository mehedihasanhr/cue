import AppKit
import ImageIO
import SwiftUI

/// A small basket that floats over everything, for files on their way somewhere.
/// Shaking the pointer while dragging files (in any app) brings up four places
/// under the pointer (the basket, Transform, a share link, AirDrop), or the basket
/// alone if Settings says so. In the basket the files wait; later the whole stack
/// is dragged out at once, and the basket goes once it is empty. An empty basket hides itself a
/// moment after the drag ends; one closed with files in it can be reopened from the
/// menu bar.
///
/// Watching the drag needs no permission: a global monitor sees mouse events, and
/// the drag pasteboard tells a drag carrying files from any other press-and-move.
@MainActor
final class BasketController {
    private let preferences: AppPreferences
    private let store = ShelfStore(folderName: "Basket")
    private let model = BasketModel()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    /// The drag pasteboard's count at the last press: changed means a drag and drop.
    private var pressCount = 0
    private var shake = ShakeDetector()
    private var hideTask: Task<Void, Never>?
    /// What was in the basket when it was last closed with files in it.
    private var lastClosed: [URL] = []
    private var gridPanel: NSPanel?
    private let grid = QuickDropModel()
    private var gridHideTask: Task<Void, Never>?
    private var wheelPanel: NSPanel?
    private let wheel = ConvertWheelModel()
    private var wheelHideTask: Task<Void, Never>?

    /// Makes share links for files (set by the app, which has the sharing settings).
    var onShareLink: ([URL]) -> Void = { _ in }
    /// Whether share links can be made.
    var canShare: () -> Bool = { false }

    var canReopen: Bool { !lastClosed.isEmpty && panel?.isVisible != true }

    init(preferences: AppPreferences) {
        self.preferences = preferences
        store.onEmptied = { [weak self] in self?.close() }
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type, time = event.timestamp
            MainActor.assumeIsolated { self?.handle(type, at: time) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type, time = event.timestamp
            MainActor.assumeIsolated { self?.handle(type, at: time) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        close()
        hideGrid()
        hideWheel()
    }

    /// Brings back the basket last closed with files in it, under the pointer.
    func reopen() {
        guard !lastClosed.isEmpty else { return }
        let urls = lastClosed.filter { FileManager.default.fileExists(atPath: $0.path) }
        lastClosed = []
        guard !urls.isEmpty else { return }
        show(at: NSEvent.mouseLocation)
        store.add(fileURLs: urls)
    }

    /// For diagnostics: the basket under the pointer, holding `urls`.
    func debugShow(_ urls: [URL]) {
        show(at: NSEvent.mouseLocation)
        store.add(fileURLs: urls)
    }

    /// For diagnostics: the four places under the pointer, `target` lit.
    func debugShowGrid(hovered target: QuickDropTarget?) {
        showGrid(at: NSEvent.mouseLocation)
        grid.hovered = target
    }

    /// Puts the basket away; what is in it is kept to reopen.
    func close() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        if !store.items.isEmpty { lastClosed = store.takeAll() }
        model.shown = false
        // Out once the view has shrunk away.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !model.shown else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func handle(_ type: NSEvent.EventType, at time: TimeInterval) {
        switch type {
        case .leftMouseDown:
            pressCount = NSPasteboard(name: .drag).changeCount
            shake.reset()
        case .leftMouseDragged:
            guard preferences.basketEnabled, gridPanel?.isVisible != true, wheelPanel?.isVisible != true else { return }
            let drag = NSPasteboard(name: .drag)
            guard drag.changeCount != pressCount, drag.types?.contains(.fileURL) == true else { return }
            // Shift held: the convert wheel, for a picture, whether or not the basket is out.
            let shift = NSEvent.modifierFlags.contains(.shift)
            guard shift || panel?.isVisible != true else { return }
            if shake.feed(x: NSEvent.mouseLocation.x, at: time) {
                let files = (drag.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                if shift, let image = files.first(where: TransformEngine.isImage) {
                    showWheel(at: NSEvent.mouseLocation, file: image)
                } else if preferences.basketQuickActions {
                    showGrid(at: NSEvent.mouseLocation)
                } else {
                    show(at: NSEvent.mouseLocation)
                }
            }
        case .leftMouseUp:
            shake.reset()
            hideIfEmpty()
            hideGridSoon()
            hideWheelSoon()
        default:
            break
        }
    }

    /// An empty basket goes a moment after the drag that brought it ends.
    private func hideIfEmpty() {
        guard panel?.isVisible == true, store.items.isEmpty else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(preferences.basketHideDelay))
            guard !Task.isCancelled, store.items.isEmpty, !model.targeted else { return }
            close()
        }
    }

    private func show(at point: CGPoint) {
        hideTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        model.canShare = canShare()
        panel.setFrame(Self.frame(around: point, size: BasketView.size), display: false)
        panel.orderFrontRegardless()
        model.shown = true
    }

    // MARK: - The four places

    private func showGrid(at point: CGPoint) {
        gridHideTask?.cancel()
        let panel = gridPanel ?? makeGridPanel()
        gridPanel = panel
        panel.setFrame(Self.frame(around: point, size: QuickDropGrid.size), display: false)
        grid.canShare = canShare()
        grid.hovered = nil
        panel.orderFrontRegardless()
        grid.shown = true
    }

    private func hideGrid() {
        gridHideTask?.cancel()
        guard let gridPanel, gridPanel.isVisible else { return }
        grid.shown = false
        grid.hovered = nil
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !grid.shown else { return }
            self.gridPanel?.orderOut(nil)
        }
    }

    // MARK: - The convert wheel

    private func showWheel(at point: CGPoint, file: URL) {
        wheelHideTask?.cancel()
        let panel = wheelPanel ?? makeWheelPanel()
        wheelPanel = panel
        wheel.file = file
        wheel.hovered = nil
        // Up and to the side of the pointer, as the reference has it: the dragged file
        // stays just outside the ring, clear of the size in the middle, and moves in
        // onto a format. Kept clear of the menu bar and the notch (the visible frame stops
        // below them) and the screen's edges.
        panel.setFrame(Self.frame(around: Self.wheelCentre(beside: point), size: WheelGeometry.window), display: false)
        panel.orderFrontRegardless()
        wheel.shown = true
    }

    private func hideWheel() {
        wheelHideTask?.cancel()
        guard let wheelPanel, wheelPanel.isVisible else { return }
        wheel.shown = false
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !wheel.shown else { return }
            self.wheelPanel?.orderOut(nil)
        }
    }

    private func hideWheelSoon() {
        guard wheelPanel?.isVisible == true else { return }
        wheelHideTask?.cancel()
        wheelHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.hideWheel()
        }
    }

    /// A copy of the file in the format it was dropped on; what's made for the shelf
    /// lands in the basket.
    private func convert(_ urls: [URL], to format: WheelFormat) {
        let point = wheelPanel.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSEvent.mouseLocation
        hideWheel()
        for url in urls where TransformEngine.isImage(url) {
            TransformModel.quickConvert(url, to: format.format) { [weak self] done, from, each, work in
                guard let self else { return }
                show(at: point)
                store.produce(done, from: from, each: each, work)
            }
        }
    }

    private func makeWheelPanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: WheelGeometry.window), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = ConvertWheelDropView(frame: CGRect(origin: .zero, size: WheelGeometry.window))
        content.count = { [weak self] in self?.wheel.formats.count ?? 0 }
        content.onHover = { [weak self] index in
            guard let self else { return }
            wheelHideTask?.cancel()
            let format = index.map { self.wheel.formats[$0] }
            if wheel.hovered != format { wheel.hovered = format }
            if let format { wheel.measure(format) }
        }
        content.onDrop = { [weak self] index, urls in
            guard let self else { return }
            convert(urls, to: wheel.formats[index])
        }
        let host = NSHostingView(rootView: ConvertWheelView(model: wheel))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = content.bounds
        content.addSubview(host)
        panel.contentView = content
        return panel
    }

    /// Where the wheel's centre goes for a drag at `point`: up and to the left, the
    /// pointer just outside the ring; to the right or below where the screen runs out.
    private static func wheelCentre(beside point: CGPoint) -> CGPoint {
        let reach = WheelGeometry.outer + 26
        let dx = reach * 0.8, dy = reach * 0.6
        let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let left = point.x - dx - WheelGeometry.outer >= visible.minX
        let up = point.y + dy + WheelGeometry.outer <= visible.maxY
        return CGPoint(x: point.x + (left ? -dx : dx), y: point.y + (up ? dy : -dy))
    }

    /// For diagnostics: the wheel round the pointer, for `file`, `format` lit.
    func debugShowWheel(file: URL, hovered format: WheelFormat?) {
        showWheel(at: NSEvent.mouseLocation, file: file)
        wheel.hovered = format
        if let format { wheel.measure(format) }
    }

    /// The drag ended somewhere else (or was let go of nowhere): the grid goes.
    private func hideGridSoon() {
        guard gridPanel?.isVisible == true else { return }
        gridHideTask?.cancel()
        gridHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.hideGrid()
        }
    }

    private func drop(on target: QuickDropTarget, urls: [URL], image: Data?) {
        let point = gridPanel.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSEvent.mouseLocation
        hideGrid()
        // A picture dragged out of an app (no file): only the basket can hold it.
        guard !urls.isEmpty else {
            show(at: point)
            if let image { store.add(imageData: image) }
            return
        }
        switch target {
        case .basket:
            show(at: point)
            store.add(fileURLs: urls)
        case .transform:
            transform(urls, at: point)
        case .share:
            onShareLink(urls)
        case .airDrop:
            QuickDropActions.airDrop(urls)
        }
    }

    /// One of the basket's own places, for files dropped on it or what's in the basket.
    private func act(_ target: QuickDropTarget, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        let point = panel.map { CGPoint(x: $0.frame.maxX, y: $0.frame.maxY) } ?? NSEvent.mouseLocation
        switch target {
        case .basket: store.add(fileURLs: urls)
        case .transform: transform(urls, at: point)
        case .share: onShareLink(urls)
        case .airDrop: QuickDropActions.airDrop(urls)
        }
    }

    /// Transform's window on the files; what's made for the shelf lands in the basket,
    /// ready to be dragged on.
    private func transform(_ urls: [URL], at point: CGPoint) {
        TransformWindow.shared.open(urls, near: point) { [weak self] done, from, each, work in
            guard let self else { return }
            show(at: point)
            store.produce(done, from: from, each: each, work)
        }
    }

    private func makeGridPanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: QuickDropGrid.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = QuickDropView(frame: CGRect(origin: .zero, size: QuickDropGrid.size))
        content.onHover = { [weak self] target in
            self?.gridHideTask?.cancel()
            self?.grid.hovered = target
        }
        content.onDrop = { [weak self] target, urls, image in self?.drop(on: target, urls: urls, image: image) }
        let host = NSHostingView(rootView: QuickDropGrid(model: grid))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = content.bounds
        content.addSubview(host)
        panel.contentView = content
        return panel
    }

    /// A window of `size` centred on `point`, kept on its screen.
    private static func frame(around point: CGPoint, size: CGSize) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var frame = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - size.width - 8)
            frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - size.height - 8)
        }
        return frame
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: BasketView.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = BasketDropView(frame: CGRect(origin: .zero, size: BasketView.size))
        content.onTargeted = { [weak self] in self?.model.targeted = $0 }
        content.onHoverAction = { [weak self] target in
            guard let self, model.hoveredAction != target else { return }
            model.hoveredAction = target
        }
        content.onAction = { [weak self] target, urls, fromBasket in
            guard let self else { return }
            // The basket's own files sent somewhere stay in it.
            if fromBasket { model.keepDragged = true }
            act(target, on: urls)
        }
        content.onDrop = { [weak self] urls, image in
            guard let self else { return }
            store.add(fileURLs: urls)
            if let image { store.add(imageData: image) }
            hideTask?.cancel()
        }
        let host = FirstMouseHostingView(rootView: BasketView(model: model, close: { [weak self] in self?.close() }, act: { [weak self] target in
            guard let self else { return }
            act(target, on: store.items.map(\.url))
        }).environment(store))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = content.bounds
        content.addSubview(host)
        panel.contentView = content
        return panel
    }
}

@MainActor @Observable
final class BasketModel {
    /// On screen (false while it shrinks away).
    var shown = false
    /// A drag with files is over it.
    var targeted = false
    /// The quick action under the drag.
    var hoveredAction: QuickDropTarget?
    /// A share link can be made (Settings › Sharing is set up).
    var canShare = false
    /// The stack was dragged onto one of the basket's own actions: it stays.
    var keepDragged = false
}

/// Back and forth, quickly: four turns, each after at least `leg` points of travel,
/// within `window` seconds.
private struct ShakeDetector {
    private static let leg: CGFloat = 24
    private static let window: TimeInterval = 0.7
    private static let turnsNeeded = 4

    private var lastX: CGFloat?
    private var direction = 0
    private var legStart: CGFloat = 0
    private var turns: [TimeInterval] = []

    mutating func reset() {
        lastX = nil
        direction = 0
        turns = []
    }

    /// True once the pointer has shaken.
    mutating func feed(x: CGFloat, at time: TimeInterval) -> Bool {
        defer { lastX = x }
        guard let lastX else { legStart = x; return false }
        let dx = x - lastX
        guard abs(dx) > 0.5 else { return false }
        let heading = dx > 0 ? 1 : -1
        if heading != direction {
            if direction != 0, abs(lastX - legStart) >= Self.leg { turns.append(time) }
            direction = heading
            legStart = lastX
        }
        turns.removeAll { time - $0 > Self.window }
        guard turns.count >= Self.turnsNeeded else { return false }
        turns = []
        return true
    }
}

/// The basket's window content: takes files dropped on it.
private final class BasketDropView: NSView {
    var onTargeted: ((Bool) -> Void)?
    var onDrop: (([URL], Data?) -> Void)?
    var onHoverAction: ((QuickDropTarget?) -> Void)?
    /// Files dropped on a quick action; true when they came from the basket itself.
    var onAction: ((QuickDropTarget, [URL], Bool) -> Void)?

    private func action(at sender: any NSDraggingInfo) -> QuickDropTarget? {
        BasketView.action(at: convert(sender.draggingLocation, from: nil), in: bounds)
    }

    private func fromBasket(_ sender: any NSDraggingInfo) -> Bool {
        (sender.draggingSource as? NSView)?.window === window
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let target = action(at: sender)
        onHoverAction?(target)
        // Its own stack, dragged out and back over it, only goes to an action.
        if fromBasket(sender) {
            onTargeted?(false)
            return target == nil ? [] : .copy
        }
        onTargeted?(target == nil)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargeted?(false)
        onHoverAction?(nil)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onTargeted?(false)
        onHoverAction?(nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if let target = action(at: sender) {
            guard !urls.isEmpty else { return false }
            onAction?(target, urls, fromBasket(sender))
            return true
        }
        guard !fromBasket(sender) else { return false }
        let image = urls.isEmpty ? (pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)) : nil
        guard !urls.isEmpty || image != nil else { return false }
        onDrop?(urls, image)
        return true
    }
}

/// The basket, as Droppy's: a pane of light glass (dark in dark mode) with a fanned
/// stack of what is in it, or a place to drop when empty, and under it the quick
/// actions (Transform, a share link, AirDrop), which take files dropped on them,
/// the stack dragged onto them, or a click for what's in the basket.
private struct BasketView: View {
    static let size = CGSize(width: 236, height: 262)
    private static let radius: CGFloat = 22
    /// Round the pane, inside the window, for its shadow.
    private static let margin: CGFloat = 12
    private static let padding: CGFloat = 8
    private static let actionsHeight: CGFloat = 52
    static let actions: [QuickDropTarget] = [.transform, .share, .airDrop]

    let model: BasketModel
    let close: () -> Void
    let act: (QuickDropTarget) -> Void
    @Environment(ShelfStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    /// The quick action at `point` (in the window, from its bottom left), if any.
    static func action(at point: CGPoint, in bounds: CGRect) -> QuickDropTarget? {
        let row = CGRect(x: bounds.minX + margin + padding, y: bounds.minY + margin + padding,
                         width: bounds.width - (margin + padding) * 2, height: actionsHeight)
        guard row.contains(point) else { return nil }
        let index = Int((point.x - row.minX) / row.width * CGFloat(actions.count))
        return actions[min(max(index, 0), actions.count - 1)]
    }

    private var dark: Bool { scheme == .dark }
    private var ink: Color { dark ? Color(white: 0.9) : Color(light: 0x222222, dark: 0x222222) }
    private var quiet: Color { dark ? Color(white: 0.55) : Color(light: 0x6E6E6E, dark: 0x6E6E6E) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink)
                    .contentTransition(.numericText())
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(quiet)
                        .frame(width: 20, height: 20)
                        .background((dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Put the basket away (reopen it from the menu bar)")
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            stack
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 5) {
                ForEach(Self.actions, id: \.self) { action in actionTile(action) }
            }
            .frame(height: Self.actionsHeight)
        }
        .padding(Self.padding)
        .frame(width: Self.size.width - Self.margin * 2, height: Self.size.height - Self.margin * 2)
        .modifier(DropPane(shape: shape, dark: dark))
        .overlay(shape.strokeBorder(IslandStyle.accent.opacity(model.targeted ? 0.8 : 0), lineWidth: 1.5))
        .scaleEffect(model.shown ? (model.targeted ? 1.02 : 1) : 0.82)
        .opacity(model.shown ? 1 : 0)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.68), value: model.shown)
        .animation(.easeOut(duration: 0.15), value: model.targeted)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: model.hoveredAction)
        .animation(.easeOut(duration: 0.2), value: store.items.map(\.id))
    }

    private var title: String {
        switch store.items.count {
        case 0: "Basket"
        case 1: "1 file"
        case let count: "\(count) files"
        }
    }

    /// A quick action: the grid's tile, small. Lit under a drag; a click acts on the basket.
    private func actionTile(_ action: QuickDropTarget) -> some View {
        let lit = model.hoveredAction == action
        let off = action == .share && !model.canShare
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { act(action) } label: {
            VStack(spacing: 4) {
                Group {
                    if action == .share {
                        Image(systemName: "link")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(LinearGradient(colors: [Color(red: 0.62, green: 0.6, blue: 1), Color(red: 0.4, green: 0.42, blue: 0.98)],
                                                            startPoint: .top, endPoint: .bottom))
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(dark ? Color(white: 0.22) : .white))
                            .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                    } else {
                        Image(systemName: action.symbol)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(ink)
                    }
                }
                .frame(height: 20)
                Text(action == .share ? "Share" : action.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                shape.fill(dark ? AnyShapeStyle(Color.white.opacity(lit ? 0.18 : 0.07))
                                : AnyShapeStyle(LinearGradient(colors: [.black.opacity(lit ? 0.09 : 0.035), .black.opacity(lit ? 0.06 : 0.01)],
                                                               startPoint: .top, endPoint: .bottom)))
            }
            .scaleEffect(lit ? 1.05 : 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(off ? 0.45 : 1)
        .disabled(off || store.items.isEmpty && !lit)
        .help(off ? "Set up sharing in Settings" : "\(action.title) what's in the basket, or drop files here")
    }

    @ViewBuilder
    private var stack: some View {
        if store.items.isEmpty {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder((dark ? Color.white : Color.black).opacity(model.targeted ? 0.4 : (dark ? 0.22 : 0.16)),
                              style: SwiftUI.StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(LinearGradient(colors: dark ? [Color(white: 0.92), Color(white: 0.6)]
                                                                         : [Color(light: 0x8C8A88, dark: 0x8C8A88), Color(light: 0x5E5C5B, dark: 0x5E5C5B)],
                                                            startPoint: .top, endPoint: .bottom))
                            .offset(y: model.targeted ? 2 : 0)
                        Text("Drop files here").font(.system(size: 10.5, weight: .medium)).foregroundStyle(quiet)
                    }
                }
        } else {
            // The last three in, fanned, the newest on top.
            let shown = Array(store.items.suffix(3))
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    let spread = CGFloat(index) - CGFloat(shown.count - 1) / 2
                    Image(nsImage: item.thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 74, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(dark ? 0.35 : 0.18), radius: 4, y: 2)
                        .rotationEffect(.degrees(spread * 9))
                        .offset(x: spread * 22, y: abs(spread) * 4)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
                ShelfDragSource(items: { store.items }, onClick: {}, onDelivered: { ids in
                    // Sent to one of the basket's own actions, the files stay.
                    guard !model.keepDragged else { model.keepDragged = false; return }
                    withAnimation(.easeOut(duration: 0.18)) { store.remove(ids) }
                })
            }
        }
    }
}
