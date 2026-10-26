import AppKit
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
            guard preferences.basketEnabled, panel?.isVisible != true, gridPanel?.isVisible != true else { return }
            let drag = NSPasteboard(name: .drag)
            guard drag.changeCount != pressCount, drag.types?.contains(.fileURL) == true else { return }
            if shake.feed(x: NSEvent.mouseLocation.x, at: time) {
                if preferences.basketQuickActions { showGrid(at: NSEvent.mouseLocation) } else { show(at: NSEvent.mouseLocation) }
            }
        case .leftMouseUp:
            shake.reset()
            hideIfEmpty()
            hideGridSoon()
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
            NSApp.activate()
            guard let airDrop = NSSharingService(named: .sendViaAirDrop), airDrop.canPerform(withItems: urls) else {
                FeedbackHUD.show("AirDrop isn't available", symbol: "exclamationmark.triangle.fill", subtitle: "Turn on Wi-Fi and Bluetooth")
                return
            }
            airDrop.perform(withItems: urls)
        }
    }

    /// What can be made of the files, as a menu at the pointer; what's made lands in
    /// the basket, ready to be dragged on.
    private func transform(_ urls: [URL], at point: CGPoint) {
        let images = urls.filter(FileActions.isImage)
        let menu = NSMenu()
        func run(_ done: String, from: [URL], each: Bool = true, _ work: @escaping @Sendable ([URL], URL) -> [URL]) {
            show(at: point)
            store.produce(done, from: from, each: each, work)
        }
        if !images.isEmpty {
            let convert = NSMenuItem(title: "Convert to", action: nil, keyEquivalent: "")
            let formats = NSMenu()
            for format in FileActions.ImageFormat.writable {
                formats.addItem(QuickDropMenuItem(format.title) {
                    run("Converted to \(format.title)", from: images) { urls, folder in urls.compactMap { FileActions.convert($0, to: format, into: folder) } }
                })
            }
            convert.submenu = formats
            menu.addItem(convert)
            menu.addItem(QuickDropMenuItem("Make Smaller") {
                run("Made smaller", from: images) { urls, folder in urls.compactMap { FileActions.compress($0, into: folder) } }
            })
        }
        menu.addItem(QuickDropMenuItem(urls.count == 1 ? "Make a ZIP" : "Make a ZIP of \(urls.count)") {
            run("Zipped", from: urls, each: false) { urls, folder in FileActions.zip(urls, into: folder).map { [$0] } ?? [] }
        })
        NSApp.activate()
        menu.popUp(positioning: nil, at: point, in: nil)
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
        content.onDrop = { [weak self] urls, image in
            guard let self else { return }
            store.add(fileURLs: urls)
            if let image { store.add(imageData: image) }
            hideTask?.cancel()
        }
        let host = FirstMouseHostingView(rootView: BasketView(model: model, close: { [weak self] in self?.close() }).environment(store))
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Never its own stack, dragged out and back over it.
        guard (sender.draggingSource as? NSView)?.window !== window else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargeted?(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let image = urls.isEmpty ? (pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)) : nil
        guard !urls.isEmpty || image != nil else { return false }
        onDrop?(urls, image)
        return true
    }
}

/// The basket: a fanned stack of what is in it, or a place to drop when empty.
private struct BasketView: View {
    static let size = CGSize(width: 220, height: 200)
    private static let radius: CGFloat = 28

    let model: BasketModel
    let close: () -> Void
    @Environment(ShelfStore.self) private var store

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .contentTransition(.numericText())
                Spacer()
                Button(action: close) {
                    Icon("xmark", size: 9, weight: .bold)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 20, height: 20)
                        .background(.white.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Put the basket away (reopen it from the menu bar)")
            }
            stack
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(store.items.isEmpty ? "Drop files here" : "Drag the stack out")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(14)
        .frame(width: Self.size.width - 16, height: Self.size.height - 16)
        .background {
            ZStack {
                if #available(macOS 26, *) {
                    shape.fill(.clear).glassEffect(.regular.tint(.black.opacity(0.45)), in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(.black.opacity(0.45))
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .overlay(shape.strokeBorder(model.targeted ? IslandStyle.accent.opacity(0.8) : .white.opacity(0.1), lineWidth: model.targeted ? 1.5 : 1))
        .scaleEffect(model.shown ? (model.targeted ? 1.03 : 1) : 0.8)
        .opacity(model.shown ? 1 : 0)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.72), value: model.shown)
        .animation(.easeOut(duration: 0.15), value: model.targeted)
        .animation(.easeOut(duration: 0.2), value: store.items.map(\.id))
        .environment(\.colorScheme, .dark)
    }

    private var title: String {
        switch store.items.count {
        case 0: "Basket"
        case 1: "1 file"
        case let count: "\(count) files"
        }
    }

    @ViewBuilder
    private var stack: some View {
        if store.items.isEmpty {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(model.targeted ? 0.5 : 0.22), style: SwiftUI.StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .overlay {
                    Icon("tray.and.arrow.down.fill", size: 22)
                        .foregroundStyle(.white.opacity(model.targeted ? 0.9 : 0.5))
                        .offset(y: model.targeted ? 2 : 0)
                }
                .padding(.horizontal, 10)
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
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        .rotationEffect(.degrees(spread * 9))
                        .offset(x: spread * 22, y: abs(spread) * 4)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
                ShelfDragSource(items: { store.items }, onClick: {}, onDelivered: { ids in
                    withAnimation(.easeOut(duration: 0.18)) { store.remove(ids) }
                })
            }
        }
    }
}
