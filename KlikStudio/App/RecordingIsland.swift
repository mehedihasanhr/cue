import AppKit
import RecordKit
import SwiftUI

/// The recorder bar, minimized: a small black island with the take's clock on it.
///
/// It rises out of the screen's bottom edge and sits melted into the bezel, the way the
/// notch sits in the top one. Pulled away, it stretches off the edge like a drop of ink
/// and snaps free; let go near the top or bottom edge, it melts back in; anywhere else
/// it floats where it was put. Under the pointer it widens to offer pause and stop, and
/// clicking the clock brings the whole bar back.
///
/// Its own window rather than a shape of the bar's: the bar's window is laid out around
/// a strip, and this one has to reach the screen's edge to melt into it.
@MainActor
final class RecordingIsland {
    private let studio: StudioService
    private let state = IslandState()
    private var panel: NSPanel?
    private var settle: Timer?
    private var velocity = CGVector.zero
    /// Where the pointer and the island were when a drag began.
    private var dragStart: (mouse: CGPoint, center: CGPoint)?
    /// Where it was left, so the next minimize puts it back there.
    private var lastCenter: CGPoint?

    /// Brings the whole bar back.
    var expand: () -> Void = {}

    /// Room around the island for the neck to reach the edge through.
    fileprivate static let margin: CGFloat = 44
    fileprivate static let height: CGFloat = 36
    fileprivate static let compactWidth: CGFloat = 92
    fileprivate static let openWidth: CGFloat = 176
    /// How far the island reaches past its resting middle when it opens: to both sides
    /// alike while it floats or sits on the top or bottom edge, and all of it away from
    /// the wall when it is docked to a side.
    fileprivate static let reach: CGFloat = openWidth - compactWidth / 2
    /// How close to an edge a drop has to be for the island to melt into it.
    private static let snap: CGFloat = 56

    init(studio: StudioService) {
        self.studio = studio
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the island, docked under the bar it replaces unless it was left elsewhere.
    func show(below barFrame: NSRect?) {
        let panel = panel ?? makePanel()
        let screen = barFrame.flatMap { Self.screen(at: CGPoint(x: $0.midX, y: $0.midY)) } ?? NSScreen.main ?? NSScreen.screens[0]
        let center = lastCenter ?? CGPoint(x: barFrame?.midX ?? screen.frame.midX,
                                           y: screen.frame.minY + Self.height / 2)
        let landing = resting(for: center)
        state.isHovering = false
        if StudioMotion.reduceMotion {
            place(at: landing)
        } else {
            // Out of the edge it is docked to, the way a drop wells up; a floating island
            // just appears where it was.
            let near = nearest(at: landing)
            place(at: near.distance < 1 ? Self.offset(landing, into: near.edge, by: Self.height) : landing)
            animate(to: landing)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        settle?.invalidate()
        settle = nil
        panel?.orderOut(nil)
    }

    // MARK: - The window

    private func makePanel() -> NSPanel {
        let size = NSSize(width: Self.reach * 2 + Self.margin * 2, height: Self.height + Self.margin * 2)
        let panel = IslandPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
        let view = IslandView(state: state,
                              began: { [weak self] in self?.dragBegan() },
                              moved: { [weak self] in self?.dragMoved() },
                              ended: { [weak self] click in self?.dragEnded(click: click) })
            .environment(studio)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        // The bar's level and manners: above the target overlay and full-screen apps, on
        // every Space, never in the Window menu. Transparent everywhere but the island,
        // so clicks around it reach whatever is underneath.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    // MARK: - Moving

    private func dragBegan() {
        settle?.invalidate()
        settle = nil
        dragStart = (NSEvent.mouseLocation, center)
    }

    private func dragMoved() {
        guard let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation
        place(at: clamped(CGPoint(x: start.center.x + mouse.x - start.mouse.x,
                                  y: start.center.y + mouse.y - start.mouse.y)))
    }

    private func dragEnded(click: Bool) {
        dragStart = nil
        if click {
            expand()
            return
        }
        let landing = resting(for: center)
        lastCenter = landing
        animate(to: landing)
    }

    /// Where an island let go at `point` comes to rest: melted into whichever edge it is
    /// near, and otherwise where it is, kept on the screen.
    private func resting(for point: CGPoint) -> CGPoint {
        let point = clamped(point)
        guard let frame = Self.screen(at: point)?.frame else { return point }
        let near = nearest(at: point)
        guard near.distance < Self.snap else {
            // Floating: room to open to both sides without leaving the screen.
            let half = Self.openWidth / 2
            return CGPoint(x: min(max(point.x, frame.minX + half), frame.maxX - half), y: point.y)
        }
        let halfWidth = Self.compactWidth / 2, half = Self.height / 2
        return switch near.edge {
        case .bottom: CGPoint(x: min(max(point.x, frame.minX + Self.openWidth / 2), frame.maxX - Self.openWidth / 2), y: frame.minY + half)
        case .top: CGPoint(x: min(max(point.x, frame.minX + Self.openWidth / 2), frame.maxX - Self.openWidth / 2), y: frame.maxY - half)
        case .leading: CGPoint(x: frame.minX + halfWidth, y: point.y)
        case .trailing: CGPoint(x: frame.maxX - halfWidth, y: point.y)
        }
    }

    /// Kept on the screen it is over, never pushed past an edge.
    private func clamped(_ point: CGPoint) -> CGPoint {
        guard let frame = Self.screen(at: point)?.frame else { return point }
        let halfWidth = Self.compactWidth / 2, half = Self.height / 2
        return CGPoint(x: min(max(point.x, frame.minX + halfWidth), frame.maxX - halfWidth),
                       y: min(max(point.y, frame.minY + half), frame.maxY - half))
    }

    /// The nearest of the screen's four edges to the island at rest size, and how far
    /// its near side is from it.
    private func nearest(at point: CGPoint) -> (edge: Edge, distance: CGFloat) {
        guard let frame = Self.screen(at: point)?.frame else { return (.bottom, .infinity) }
        let halfWidth = Self.compactWidth / 2, half = Self.height / 2
        let gaps: [(Edge, CGFloat)] = [
            (.bottom, point.y - half - frame.minY),
            (.top, frame.maxY - (point.y + half)),
            (.leading, point.x - halfWidth - frame.minX),
            (.trailing, frame.maxX - (point.x + halfWidth)),
        ]
        let best = gaps.min { $0.1 < $1.1 }!
        return (best.0, best.1)
    }

    private static func offset(_ point: CGPoint, into edge: Edge, by amount: CGFloat) -> CGPoint {
        switch edge {
        case .bottom: CGPoint(x: point.x, y: point.y - amount)
        case .top: CGPoint(x: point.x, y: point.y + amount)
        case .leading: CGPoint(x: point.x - amount, y: point.y)
        case .trailing: CGPoint(x: point.x + amount, y: point.y)
        }
    }

    /// The island's resting middle, which is the window's middle.
    private var center: CGPoint {
        guard let frame = panel?.frame else { return .zero }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func place(at point: CGPoint) {
        guard let panel else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: (point.x - size.width / 2).rounded(), y: (point.y - size.height / 2).rounded()))
        let near = nearest(at: point)
        state.edge = near.edge
        state.gap = near.distance
    }

    /// Springs the island to `target`, moving the window a step a frame so the neck to the
    /// edge is drawn at every point on the way — an `NSWindow` animation would only say
    /// where it ended.
    private func animate(to target: CGPoint) {
        settle?.invalidate()
        guard !StudioMotion.reduceMotion else {
            place(at: target)
            return
        }
        velocity = .zero
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step(toward: target) }
        }
        RunLoop.main.add(timer, forMode: .common)
        settle = timer
    }

    private func step(toward target: CGPoint) {
        // A spring a little short of critical damping: it lands with the smallest give,
        // like a drop settling, rather than bouncing on the edge.
        let stiffness: CGFloat = 260, damping: CGFloat = 2 * sqrt(260) * 0.82, dt: CGFloat = 1.0 / 120
        var point = center
        velocity.dx += (stiffness * (target.x - point.x) - damping * velocity.dx) * dt
        velocity.dy += (stiffness * (target.y - point.y) - damping * velocity.dy) * dt
        point.x += velocity.dx * dt
        point.y += velocity.dy * dt
        let done = hypot(target.x - point.x, target.y - point.y) < 0.5 && hypot(velocity.dx, velocity.dy) < 5
        place(at: done ? target : point)
        if done {
            settle?.invalidate()
            settle = nil
        }
    }

    private static func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.min { distance($0.frame, point) < distance($1.frame, point) }
    }

    private static func distance(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
    }
}

/// Takes clicks without ever becoming key, so pressing the island never takes the
/// keyboard from the app being recorded.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What the island's view draws from, set by the window as it moves.
@MainActor @Observable
private final class IslandState {
    /// The edge the island is nearest, and how far its near side is from it. Zero is
    /// docked: melted into the edge.
    var edge: Edge = .bottom
    var gap: CGFloat = 0
    var isHovering = false
}

private struct IslandView: View {
    @Environment(StudioService.self) private var studio
    let state: IslandState
    let began: () -> Void
    let moved: () -> Void
    let ended: (_ click: Bool) -> Void

    private var width: CGFloat {
        state.isHovering ? RecordingIsland.openWidth : RecordingIsland.compactWidth
    }

    var body: some View {
        GeometryReader { proxy in
            let island = IslandInk.rect(in: proxy.size, width: width, edge: state.edge, gap: state.gap)
            ZStack(alignment: .topLeading) {
                // Hit-testable on purpose. The window server lets the pointer through any
                // point of a panel that is either see-through or that SwiftUI says it does
                // not take — so an ink that ignored hits let every move under the island
                // reach the app beneath, which lit up its own hover states, and let presses
                // meant for the island land there too.
                IslandInk(width: width, gap: state.gap, edge: state.edge)
                controls
                    .frame(width: island.width, height: island.height)
                    // Behind the buttons, so a press anywhere else on the island is the
                    // island's own: a drag moves it, a click brings the bar back.
                    .background(IslandHandle(began: began, moved: moved, ended: ended))
                    .onHover { inside in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { state.isHovering = inside }
                    }
                    // Placed, not offset: an offset moves what is drawn but leaves the
                    // grip's AppKit view where layout put it, in the window's corner — so
                    // the island neither took its own drags nor stopped the pointer from
                    // reaching, and lighting up, whatever was underneath.
                    .position(x: island.midX, y: island.midY)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            clock
                .padding(.leading, 14)
                .frame(width: RecordingIsland.compactWidth, alignment: .leading)
                .allowsHitTesting(false)
                .help("Show the recorder bar")
            if state.isHovering {
                HStack(spacing: 2) {
                    Button { studio.togglePause() } label: {
                        Image(systemName: studio.session.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .help(studio.session.isPaused ? "Resume" : "Pause")
                    .accessibilityLabel(studio.session.isPaused ? "Resume" : "Pause")
                    Button { studio.stop() } label: {
                        ZStack {
                            Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(Color(red: 0.93, green: 0.2, blue: 0.22))
                                .frame(width: 9, height: 9)
                        }
                        .frame(width: 24, height: 24)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                    }
                    .help("Stop and keep this recording")
                    .accessibilityLabel("Stop")
                }
                .buttonStyle(BarButtonStyle())
                .disabled(!studio.session.state.isTaking)
                .padding(.trailing, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var clock: some View {
        switch studio.session.state {
        case .recording(let started):
            TimelineView(.periodic(from: started, by: 1)) { context in
                time(RecorderModel.elapsed(since: started, at: context.date), paused: false)
            }
        case .paused(let started, let pausedAt):
            time(RecorderModel.elapsed(since: started, at: pausedAt), paused: true)
        default:
            time("0:00", paused: false)
        }
    }

    private func time(_ text: String, paused: Bool) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(paused ? BarMood.held.accent : BarMood.live.accent)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
    }
}

/// The island's black, and the screen edge it melts into.
///
/// Both are drawn blurred and then cut at half opacity — the metaball trick — so where
/// the island comes near the edge the two run together: a flared foot while it is docked,
/// a neck that thins as it is pulled away, and a drop that snaps back into the edge when
/// the neck breaks. The edge itself is a block drawn just past the screen's edge, where
/// nothing of it shows but the part that flows up to meet the island.
private struct IslandInk: View, Animatable {
    var width: CGFloat
    let gap: CGFloat
    let edge: Edge

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    /// The island in the window: its resting middle is the window's middle, and it opens
    /// away from a side it is docked to, or to both sides alike.
    static func rect(in size: CGSize, width: CGFloat, edge: Edge, gap: CGFloat) -> CGRect {
        let height = RecordingIsland.height, compact = RecordingIsland.compactWidth
        let docked = gap < 1
        let minX: CGFloat = switch edge {
        case .leading where docked: size.width / 2 - compact / 2
        case .trailing where docked: size.width / 2 + compact / 2 - width
        default: size.width / 2 - width / 2
        }
        return CGRect(x: minX, y: (size.height - height) / 2, width: width, height: height)
    }

    var body: some View {
        Canvas { context, size in
            let island = Self.rect(in: size, width: width, edge: edge, gap: gap)
            context.addFilter(.alphaThreshold(min: 0.5, color: .black))
            context.addFilter(.blur(radius: 6))
            context.drawLayer { layer in
                layer.fill(Path(roundedRect: island, cornerRadius: 15, style: .continuous), with: .color(.black))
                // The screen's edge: a block just past it, of which nothing shows but the
                // part that flows in to meet the island.
                let depth: CGFloat = 80, flare: CGFloat = 20
                let block: CGRect = switch edge {
                case .bottom: CGRect(x: island.minX - flare, y: island.maxY + gap, width: island.width + flare * 2, height: depth)
                case .top: CGRect(x: island.minX - flare, y: island.minY - gap - depth, width: island.width + flare * 2, height: depth)
                case .leading: CGRect(x: island.minX - gap - depth, y: island.minY - flare, width: depth, height: island.height + flare * 2)
                case .trailing: CGRect(x: island.maxX + gap, y: island.minY - flare, width: depth, height: island.height + flare * 2)
                }
                layer.fill(Path(block), with: .color(.black))
            }
        }
    }
}

/// The island's own grip: a drag moves the window with the pointer, event by event, and a
/// press that does not travel is a click.
///
/// AppKit's tracking loop rather than a SwiftUI drag gesture. The gesture reported its
/// moves in the coordinates of a window that was itself moving under it, and lost them
/// to the buttons and the click it shared the island with; here every mouse event moves
/// the window once, in screen points, and nothing else is listening.
private struct IslandHandle: NSViewRepresentable {
    let began: () -> Void
    let moved: () -> Void
    let ended: (_ click: Bool) -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.handle = self
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.handle = self
    }

    final class HandleView: NSView {
        var handle: IslandHandle?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let handle, let window else { return }
            let start = NSEvent.mouseLocation
            var travelled = false
            handle.began()
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let now = NSEvent.mouseLocation
                if !travelled, hypot(now.x - start.x, now.y - start.y) > 3 { travelled = true }
                if travelled { handle.moved() }
            }
            handle.ended(!travelled)
        }
    }
}
