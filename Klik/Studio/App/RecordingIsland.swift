import AppKit
import RecordKit
import SwiftUI

/// The recorder bar, minimized: a small black island with the take's clock on it.
///
/// It rises out of the screen's bottom edge and sits melted into the bezel, the way the
/// notch sits in the top one. Pulled away, it stretches off the edge like a drop of ink
/// and snaps free; let go, it springs to the nearest edge and melts back in — it never
/// stays out over the middle of the screen. It lies along the edge it is on — a wide pill on the top or bottom, a tall
/// one on either side — and under the pointer it grows along that edge to offer pause and
/// stop. Clicking the clock brings the whole bar back.
///
/// Its own window rather than a shape of the bar's: the bar's window is laid out around
/// a strip, and this one has to reach the screen's edge to melt into it.
@MainActor
final class RecordingIsland {
    private let studio: StudioService
    private let settings: StudioSettings
    private let model: RecorderModel
    private let state = IslandState()
    private var menuObservers: [any NSObjectProtocol] = []
    private var panel: NSPanel?
    private var settle: Timer?
    private var velocity = CGVector.zero
    /// Where the spring has the island, unrounded. Read back from the window it is a
    /// whole number of points, and near the target the rounding undid each step — the
    /// spring never came to rest, so the island never counted as settled: it ignored the
    /// pointer, and the device frame never faded.
    private var springPoint = CGPoint.zero
    private var settleStarted = Date.distantPast
    /// Where the pointer and the island were when a drag began.
    private var dragStart: (mouse: CGPoint, center: CGPoint)?
    /// Where it was left, so the next minimize puts it back there.
    private var lastCenter: CGPoint?

    /// Brings the whole bar back.
    var expand: () -> Void = {}
    /// Starts a take from the island, before one is under way.
    var record: () -> Void = {}
    /// What the opened island's buttons reach back into the app for.
    var choose: (RecorderModel.Mode) -> Void = { _ in }
    var restart: () -> Void = {}
    var showLibrary: () -> Void = {}
    var openSettings: () -> Void = {}

    /// Room around the island for the neck to reach the edge through.
    fileprivate static let margin: CGFloat = 44
    /// Lying along the top or bottom edge, and while it is carried. `open` is the most it
    /// grows to along the edge, which is the room kept for it from the screen's corners
    /// and in its window.
    fileprivate static let wide = (compact: CGSize(width: 92, height: 40), open: CGSize(width: openLength, height: 40))
    /// Standing along the left or right edge.
    fileprivate static let tall = (compact: CGSize(width: 44, height: 64), open: CGSize(width: 44, height: openLength))

    /// Lying flat before a take, round the record button alone.
    fileprivate static let wideReady = CGSize(width: 56, height: 40)

    /// One button's square on the opened island, and the rule between groups.
    fileprivate static let tile: CGFloat = 32
    fileprivate static let rule: CGFloat = 9
    /// Opened before a take: the record button, the four modes, the three inputs, the
    /// gear — in groups.
    fileprivate static let openLength: CGFloat = 44 + rule + tile * 4 + rule + tile * 3 + rule + tile + 6
    /// Opened during one: the clock, then pause, marker, restart, discard and stop.
    fileprivate static func takeLength(standing: Bool) -> CGFloat {
        (standing ? 50 : wide.compact.width) + rule + tile * 5 + 6
    }
    /// How close to a side the island has to come to stand up.
    private static let snap: CGFloat = 56

    init(studio: StudioService, settings: StudioSettings, model: RecorderModel) {
        self.studio = studio
        self.settings = settings
        self.model = model
        // Kept open while one of its menus is: the menu takes the pointer, and an island
        // that closed under it would take the menu's button away mid-choice.
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.state.menusOpen += 1 }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let state = self?.state { state.menusOpen = max(0, state.menusOpen - 1) } }
            },
        ]
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the island, docked under the bar it replaces unless it was left elsewhere.
    func show(below barFrame: NSRect?) {
        let panel = panel ?? makePanel()
        let screen = barFrame.flatMap { Self.screen(at: CGPoint(x: $0.midX, y: $0.midY)) } ?? NSScreen.main ?? NSScreen.screens[0]
        // The right edge, half way up, the first time: out of the way of the dock, the
        // menu bar and most of what gets recorded.
        let center = lastCenter ?? CGPoint(x: screen.frame.maxX - Self.tall.compact.width / 2,
                                           y: screen.frame.midY)
        let landing = resting(for: center)
        state.isHovering = false
        if StudioMotion.reduceMotion {
            place(at: landing)
        } else {
            // Out of the edge it is docked to, the way a drop wells up.
            let near = nearest(at: landing)
            let thickness = near.edge.isSide ? Self.tall.compact.width : Self.wide.compact.height
            place(at: Self.offset(landing, into: near.edge, by: thickness))
            animate(to: landing)
        }
        panel.orderFrontRegardless()
        // On screen with the island, empty until a drag fills it. Putting a window up in
        // the middle of a drag cut the drag short: the island stopped following the
        // pointer as soon as the frame appeared.
        if let screen = Self.screen(at: center) { deviceFrame.show(on: screen, below: panel) }
    }

    func hide() {
        settle?.invalidate()
        settle = nil
        state.bezel = 0
        deviceFrame.hide()
        panel?.orderOut(nil)
    }

    // MARK: - The device's frame

    /// The black frame drawn round the screen while the island is carried, for it to
    /// cling to and pour back into — the bezel of the device it lives on, made visible.
    private lazy var deviceFrame = DeviceFrame(state: state)
    /// How deep the frame comes into the screen.
    fileprivate static let bezel: CGFloat = 8

    private func showFrame() {
        withAnimation(.easeOut(duration: 0.22)) { state.bezel = Self.bezel }
    }

    private func fadeFrame() {
        withAnimation(.easeIn(duration: 0.3)) { state.bezel = 0 }
    }

    // MARK: - The window

    private func makePanel() -> NSPanel {
        let size = NSSize(width: Self.openLength + Self.margin * 2, height: Self.openLength + Self.margin * 2)
        let panel = RecordingIslandPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
        let view = RecordingIslandView(state: state,
                              began: { [weak self] in self?.dragBegan(at: $0) },
                              moved: { [weak self] in self?.dragMoved(to: $0) },
                              ended: { [weak self] click in self?.dragEnded(click: click) },
                              actions: IslandActions(record: { [weak self] in self?.record() },
                                                     choose: { [weak self] in self?.choose($0) },
                                                     restart: { [weak self] in self?.restart() },
                                                     showLibrary: { [weak self] in self?.showLibrary() },
                                                     openSettings: { [weak self] in self?.openSettings() },
                                                     expand: { [weak self] in self?.expand() }))
            .environment(studio)
            .environment(settings)
            .environment(model)
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

    private func dragBegan(at mouse: CGPoint) {
        settle?.invalidate()
        settle = nil
        dragStart = (mouse, center)
        if !StudioMotion.reduceMotion { showFrame() }
    }

    private func dragMoved(to mouse: CGPoint) {
        guard let start = dragStart else { return }
        // Collapsed while carried: the buttons are no use mid-air, and a small drop is
        // what pours into the frame.
        if !state.isCarried {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { state.isCarried = true }
        }
        let wanted = clamped(CGPoint(x: start.center.x + mouse.x - start.mouse.x,
                                     y: start.center.y + mouse.y - start.mouse.y))
        place(at: magnetized(wanted))
    }

    /// Held by the nearest edge while it is close: the island lags the pointer, slowly
    /// at first and then all at once, so it has to be pulled off the frame rather than
    /// simply lifted — the neck stretching while it does.
    private func magnetized(_ point: CGPoint) -> CGPoint {
        let near = nearest(at: point)
        guard near.distance > 0, near.distance < Self.snap else { return point }
        let held = Self.snap * pow(near.distance / Self.snap, 2)
        return Self.offset(point, into: near.edge, by: near.distance - held)
    }

    private func dragEnded(click: Bool) {
        dragStart = nil
        if state.isCarried {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { state.isCarried = false }
        }
        if click {
            expand()
            return
        }
        let landing = resting(for: center)
        lastCenter = landing
        animate(to: landing)
    }

    /// Where an island let go at `point` comes to rest: melted into whichever edge is
    /// nearest. It never stays out in the middle of the screen, over the thing being
    /// recorded — let go anywhere, it springs to the closest edge.
    private func resting(for point: CGPoint) -> CGPoint {
        let point = clamped(point)
        guard let frame = Self.screen(at: point)?.frame else { return point }
        let near = nearest(at: point)
        let wide = Self.wide, tall = Self.tall
        func across(_ x: CGFloat) -> CGFloat { min(max(x, frame.minX + wide.open.width / 2), frame.maxX - wide.open.width / 2) }
        func along(_ y: CGFloat) -> CGFloat { min(max(y, frame.minY + tall.open.height / 2), frame.maxY - tall.open.height / 2) }
        return switch near.edge {
        case .bottom: CGPoint(x: across(point.x), y: frame.minY + wide.compact.height / 2)
        case .top: CGPoint(x: across(point.x), y: frame.maxY - wide.compact.height / 2)
        case .leading: CGPoint(x: frame.minX + tall.compact.width / 2, y: along(point.y))
        case .trailing: CGPoint(x: frame.maxX - tall.compact.width / 2, y: along(point.y))
        }
    }

    /// Kept on the screen it is over, never pushed past an edge.
    private func clamped(_ point: CGPoint) -> CGPoint {
        guard let frame = Self.screen(at: point)?.frame else { return point }
        let halfWidth = Self.tall.compact.width / 2, half = Self.wide.compact.height / 2
        return CGPoint(x: min(max(point.x, frame.minX + halfWidth), frame.maxX - halfWidth),
                       y: min(max(point.y, frame.minY + half), frame.maxY - half))
    }

    /// The nearest of the screen's four edges, and how far the island's near side is from
    /// it. Each edge is measured with the island in the shape it takes there — lying down
    /// for the top and bottom, standing for the sides — so the shape it is in does not
    /// change which edge is nearest, and it cannot flip back and forth on the threshold.
    private func nearest(at point: CGPoint) -> (edge: Edge, distance: CGFloat) {
        guard let frame = Self.screen(at: point)?.frame else { return (.bottom, .infinity) }
        let halfWidth = Self.tall.compact.width / 2, half = Self.wide.compact.height / 2
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
        let standing = near.edge.isSide && near.distance < Self.snap
        if standing != state.isStanding {
            withAnimation(StudioMotion.reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78)) {
                state.isStanding = standing
            }
        }
    }

    /// Springs the island to `target`, moving the window a step a frame so the neck to the
    /// edge is drawn at every point on the way — an `NSWindow` animation would only say
    /// where it ended.
    private func animate(to target: CGPoint) {
        settle?.invalidate()
        guard !StudioMotion.reduceMotion else {
            place(at: target)
            fadeFrame()
            return
        }
        velocity = .zero
        springPoint = center
        settleStarted = .now
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
        var point = springPoint
        velocity.dx += (stiffness * (target.x - point.x) - damping * velocity.dx) * dt
        velocity.dy += (stiffness * (target.y - point.y) - damping * velocity.dy) * dt
        point.x += velocity.dx * dt
        point.y += velocity.dy * dt
        springPoint = point
        // At rest, or out of time: a spring this stiff is there well inside a second.
        let done = (hypot(target.x - point.x, target.y - point.y) < 0.5 && hypot(velocity.dx, velocity.dy) < 5)
            || Date.now.timeIntervalSince(settleStarted) > 1.5
        place(at: done ? target : point)
        if done {
            settle?.invalidate()
            settle = nil
            fadeFrame()
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
private final class RecordingIslandPanel: NSPanel {
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
    /// Upright, along a side edge, rather than lying along the top or bottom.
    var isStanding = false
    /// Being dragged: kept at its smallest whatever the pointer is over.
    var isCarried = false
    /// A take is under way, so there are pause and stop to offer.
    var isTaking = false
    /// How far the device's frame reaches into the screen: none at rest, the frame's
    /// depth while the island is carried. The island's ink pours into the frame's inner
    /// edge, so the two have to agree on it at every moment of a fade.
    var bezel: CGFloat = 0

    /// Its size along the edge it is on: small at rest, long enough for every option while
    /// it is open.
    /// One of its menus is open.
    var menusOpen = 0
    /// Open to show every option: under the pointer, or with one of its menus up — and
    /// never while it is carried.
    var isOpen: Bool { (isHovering || menusOpen > 0) && !isCarried }

    var size: CGSize {
        // Before a take there is only the record button to hold: a small pill round it.
        let compact = isStanding ? RecordingIsland.tall.compact
            : (isTaking ? RecordingIsland.wide.compact : RecordingIsland.wideReady)
        guard isOpen else { return compact }
        let length = isTaking ? RecordingIsland.takeLength(standing: isStanding) : RecordingIsland.openLength
        return isStanding ? CGSize(width: compact.width, height: length) : CGSize(width: length, height: compact.height)
    }
}

extension Edge {
    fileprivate var isSide: Bool { self == .leading || self == .trailing }
}

private struct RecordingIslandView: View {
    @Environment(StudioService.self) private var studio
    @Environment(StudioSettings.self) private var settings
    let state: IslandState
    let began: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
    let ended: (_ click: Bool) -> Void
    let actions: IslandActions

    var body: some View {
        GeometryReader { proxy in
            let island = IslandInk.rect(in: proxy.size, size: state.size)
            ZStack(alignment: .topLeading) {
                // Hit-testable on purpose. The window server lets the pointer through any
                // point of a panel that is either see-through or that SwiftUI says it does
                // not take — so an ink that ignored hits let every move under the island
                // reach the app beneath, which lit up its own hover states, and let presses
                // meant for the island land there too.
                IslandInk(size: state.size, gap: state.gap, bezel: state.bezel, edge: state.edge)
                controls
                    .frame(width: island.width, height: island.height)
                    // Behind the buttons, so a press anywhere else on the island is the
                    // island's own: a drag moves it, a click brings the bar back.
                    .background(IslandHandle(began: began, moved: moved, ended: ended))
                    .onHover { inside in
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { state.isHovering = inside }
                    }
                    // Placed, not offset: an offset moves what is drawn but leaves the
                    // grip's AppKit view where layout put it, in the window's corner — so
                    // the island neither took its own drags nor stopped the pointer from
                    // reaching, and lighting up, whatever was underneath.
                    .position(x: island.midX, y: island.midY)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: studio.session.state.isTaking, initial: true) { _, taking in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { state.isTaking = taking }
        }
    }

    /// At rest, the clock — or before a take, the record button. Opened, every option
    /// after it in groups: in a column while the island stands on a side, a row while it
    /// lies along the top or bottom. One set of views in a layout that changes, so turning
    /// moves them rather than fading one arrangement out and another in.
    private var controls: some View {
        let standing = state.isStanding
        let line = standing ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let rest = standing ? RecordingIsland.tall.compact : RecordingIsland.wide.compact
        let open = state.isOpen
        // Before a take the island holds the record button alone, centred.
        let ready = !state.isTaking
        return line {
            clock(stacked: standing, open: open)
                .padding(.leading, standing || ready ? 0 : 14)
                .frame(width: standing ? rest.width : (ready ? (open ? 44 : RecordingIsland.wideReady.width) : rest.width),
                       height: standing ? (open ? (state.isTaking ? 50 : 44) : rest.height) : rest.height,
                       alignment: standing || ready ? .center : .leading)
            if open {
                IslandOptions(standing: standing, isTaking: state.isTaking, actions: actions)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func clock(stacked: Bool, open: Bool = false) -> some View {
        switch studio.session.state {
        case .recording(let started):
            TimelineView(.periodic(from: started, by: 1)) { context in
                time(RecorderModel.elapsed(since: started, at: context.date), paused: false, stacked: stacked)
            }
        case .paused(let started, let pausedAt):
            time(RecorderModel.elapsed(since: started, at: pausedAt), paused: true, stacked: stacked)
        case .preparing, .countdown:
            countdown(stacked: stacked)
        case .finishing:
            ProgressView().controlSize(.small)
                .allowsHitTesting(false)
        default:
            ready(stacked: stacked || open)
        }
    }

    /// Before a take: the record button, which starts one from here.
    private func ready(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button(action: actions.record) {
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                    Circle()
                        .fill(LinearGradient(colors: [Color(red: 1, green: 0.3, blue: 0.3), Color(red: 0.86, green: 0.1, blue: 0.13)],
                                             startPoint: .top, endPoint: .bottom))
                        .padding(4)
                }
                .frame(width: 24, height: 24)
                .contentShape(Circle())
            }
            .buttonStyle(BarButtonStyle(pressedScale: 0.88))
            .help("Start recording")
            .accessibilityLabel("Start recording")
        }
    }

    /// The seconds before the first frame, as a ring that drains around the number.
    @ViewBuilder
    private func countdown(stacked: Bool) -> some View {
        let remaining = studio.session.state.countdownRemaining
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 2)
            if let remaining {
                Circle()
                    .trim(from: 0, to: Double(remaining) / Double(max(1, settings.countdownSeconds)))
                    .stroke(.white, style: SwiftUI.StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: remaining)
                Text("\(remaining)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 26, height: 26)
        .allowsHitTesting(false)
    }

    /// The dot beside the time, or above it while the island stands.
    private func time(_ text: String, paused: Bool, stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 7)) : AnyLayout(HStackLayout(spacing: 7))
        return layout {
            Circle()
                .fill(paused ? BarMood.held.accent : BarMood.live.accent)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: stacked ? 11.5 : 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, stacked ? 4 : 0)
        // Presses go through to the island's grip — a drag moves it, a click opens the bar.
        .allowsHitTesting(false)
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
    var size: CGSize
    let gap: CGFloat
    var bezel: CGFloat
    let edge: Edge

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(size.width, size.height), bezel) }
        set {
            size = CGSize(width: newValue.first.first, height: newValue.first.second)
            bezel = newValue.second
        }
    }

    /// The island in the window. Its resting middle is the window's middle, and it opens
    /// along the edge it is on, to both sides alike.
    static func rect(in bounds: CGSize, size: CGSize) -> CGRect {
        CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
               width: size.width, height: size.height)
    }

    var body: some View {
        Canvas { context, size in
            let island = Self.rect(in: size, size: self.size)
            context.addFilter(.alphaThreshold(min: 0.5, color: .black))
            context.addFilter(.blur(radius: 7))
            context.drawLayer { layer in
                layer.fill(Path(roundedRect: island, cornerRadius: 15, style: .continuous), with: .color(.black))
                // The screen's edge: a block just past it, of which nothing shows but the
                // part that flows in to meet the island.
                let depth: CGFloat = 80, flare: CGFloat = 20
                // Its near side is the frame's inner edge, `bezel` in from the screen's.
                let reach = gap - bezel
                let block: CGRect = switch edge {
                case .bottom: CGRect(x: island.minX - flare, y: island.maxY + reach, width: island.width + flare * 2, height: depth)
                case .top: CGRect(x: island.minX - flare, y: island.minY - reach - depth, width: island.width + flare * 2, height: depth)
                case .leading: CGRect(x: island.minX - reach - depth, y: island.minY - flare, width: depth, height: island.height + flare * 2)
                case .trailing: CGRect(x: island.maxX + reach, y: island.minY - flare, width: depth, height: island.height + flare * 2)
                }
                layer.fill(Path(block), with: .color(.black))
                // The neck: a column of ink between the island and the frame, thinning as
                // the island is pulled away until it parts. The blur and the cut above
                // turn it into the stretched drop of the liquid; without it the two
                // parted at a few points, before anything had visibly stretched.
                let breakAt: CGFloat = 44
                if reach > 0, reach < breakAt {
                    let base = min(island.width, island.height) * 0.62
                    let width = base * pow(1 - reach / breakAt, 0.75)
                    let overlap: CGFloat = 8
                    let neck: CGRect = switch edge {
                    case .bottom: CGRect(x: island.midX - width / 2, y: island.maxY - overlap, width: width, height: reach + overlap * 2)
                    case .top: CGRect(x: island.midX - width / 2, y: island.minY - reach - overlap, width: width, height: reach + overlap * 2)
                    case .leading: CGRect(x: island.minX - reach - overlap, y: island.midY - width / 2, width: reach + overlap * 2, height: width)
                    case .trailing: CGRect(x: island.maxX - overlap, y: island.midY - width / 2, width: reach + overlap * 2, height: width)
                    }
                    if width > 1.5 { layer.fill(Path(neck), with: .color(.black)) }
                }
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
    let began: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
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
            let start = Self.screenPoint(of: event)
            var travelled = false
            handle.began(start)
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let now = Self.screenPoint(of: next)
                if !travelled, hypot(now.x - start.x, now.y - start.y) > 3 { travelled = true }
                if travelled { handle.moved(now) }
            }
            handle.ended(!travelled)
        }

        /// Where the event happened on the screen, from the event itself. Not
        /// `NSEvent.mouseLocation`, which is where the pointer is now and can trail the
        /// event — and not the event's window location either, which is relative to a
        /// window this very drag is moving.
        private static func screenPoint(of event: NSEvent) -> CGPoint {
            guard let global = event.cgEvent?.location else { return NSEvent.mouseLocation }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return CGPoint(x: global.x, y: top - global.y)
        }
    }
}

/// The device's black frame round the screen, shown while the island is carried.
///
/// A window of its own, the size of the screen, that the pointer passes straight through.
/// The island draws the same edge into its own ink, just where this frame's inner edge
/// is, so the neck it pulls out of the frame is one piece with it.
@MainActor
private final class DeviceFrame {
    private let state: IslandState
    private var panel: NSPanel?

    init(state: IslandState) {
        self.state = state
    }

    func show(on screen: NSScreen, below island: NSWindow) {
        let panel = panel ?? make()
        panel.setFrame(screen.frame, display: false)
        panel.order(.below, relativeTo: island.windowNumber)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: DeviceFrameView(state: state))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }
}

private struct DeviceFrameView: View {
    let state: IslandState

    var body: some View {
        Bezel(depth: state.bezel)
            .fill(.black, style: FillStyle(eoFill: true))
            .ignoresSafeArea()
    }
}

/// The screen with a rounded hole in it: a band `depth` deep all the way round, its inner
/// corners rounded like a display's, and nothing at all at a depth of zero.
nonisolated private struct Bezel: Shape {
    var depth: CGFloat

    var animatableData: CGFloat {
        get { depth }
        set { depth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let radius = depth * 1.75
        path.addRoundedRect(in: rect.insetBy(dx: depth, dy: depth),
                            cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return path
    }
}

/// What the opened island's buttons do, handed in by the window that owns it.
private struct IslandActions {
    let record: () -> Void
    let choose: (RecorderModel.Mode) -> Void
    let restart: () -> Void
    let showLibrary: () -> Void
    let openSettings: () -> Void
    let expand: () -> Void
}

/// Every option, compact, for the opened island.
///
/// Before a take: the four modes, the three inputs as one-press switches, and the gear.
/// During one: pause, marker, restart, discard and stop. A device or the apps whose sound
/// is heard are still chosen on the full bar — the gear's Show Recorder Bar, or a click
/// on the island — since a list of them has no room here.
private struct IslandOptions: View {
    @Environment(StudioService.self) private var studio
    @Environment(StudioSettings.self) private var settings
    @Environment(RecorderModel.self) private var model
    let standing: Bool
    let isTaking: Bool
    let actions: IslandActions

    var body: some View {
        let line = standing ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        line {
            rule
            if isTaking { takeOptions } else { setupOptions }
        }
    }

    @ViewBuilder
    private var setupOptions: some View {
        ForEach(RecorderModel.Mode.allCases) { mode in
            IslandTile(symbol: mode.symbol, name: mode.title, isSelected: model.mode == mode) {
                actions.choose(mode)
            }
            .disabled(!mode.isAvailable)
        }
        rule
        IslandTile(symbol: settings.recordsCamera ? "video" : "video.slash",
                   name: settings.recordsCamera ? "Camera on" : "Camera off", isOn: settings.recordsCamera) {
            model.setCamera(!settings.recordsCamera)
        }
        IslandTile(symbol: settings.recordsMicrophone ? "mic" : "mic.slash",
                   name: settings.recordsMicrophone ? "Microphone on" : "Microphone off", isOn: settings.recordsMicrophone) {
            settings.recordsMicrophone.toggle()
        }
        IslandTile(symbol: settings.recordsSystemAudio ? "music.note.tv" : "music.note.tv",
                   name: settings.recordsSystemAudio ? "System audio on" : "System audio off", isOn: settings.recordsSystemAudio) {
            settings.recordsSystemAudio.toggle()
        }
        rule
        Menu {
            Button("Show Recorder Bar", action: actions.expand)
            Divider()
            Button("Recordings\u{2026}", action: actions.showLibrary)
            Button("Settings\u{2026}", action: actions.openSettings)
            Divider()
            Button("Quit Klik") { NSApp.terminate(nil) }
        } label: {
            IslandGlyph(symbol: "gearshape", isOn: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    @ViewBuilder
    private var takeOptions: some View {
        let taking = studio.session.state.isTaking
        IslandTile(symbol: studio.session.isPaused ? "play" : "pause",
                   name: studio.session.isPaused ? "Resume" : "Pause") { studio.togglePause() }
            .disabled(!taking)
        IslandTile(symbol: "flag", name: "Add marker") { studio.addMarker() }
            .disabled(!taking)
        IslandTile(symbol: "arrow.counterclockwise", name: "Start again", action: actions.restart)
            .disabled(!taking)
        IslandTile(symbol: "trash", name: "Discard this recording") { studio.cancel() }
            .disabled(!taking)
        Button { studio.stop() } label: {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color(red: 0.93, green: 0.2, blue: 0.22))
                    .frame(width: 9, height: 9)
            }
            .frame(width: 22, height: 22)
            .frame(width: RecordingIsland.tile, height: RecordingIsland.tile)
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.88))
        .disabled(!taking)
        .help("Stop and keep this recording")
        .accessibilityLabel("Stop")
    }

    /// The hairline between groups, across the island.
    private var rule: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: standing ? 18 : 1, height: standing ? 1 : 18)
            .frame(width: standing ? RecordingIsland.tile : RecordingIsland.rule,
                   height: standing ? RecordingIsland.rule : RecordingIsland.tile)
    }
}

/// One option on the opened island: a glyph in a square, lit under the pointer.
private struct IslandTile: View {
    let symbol: String
    let name: String
    var isSelected = false
    var isOn = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IslandGlyph(symbol: symbol, isOn: isOn, isSelected: isSelected)
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.9))
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct IslandGlyph: View {
    let symbol: String
    var isOn = true
    var isSelected = false
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.white.opacity(!isEnabled ? 0.3 : (isOn || isSelected ? 0.92 : 0.5)))
            .frame(width: RecordingIsland.tile, height: RecordingIsland.tile)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.14 : (isHovering && isEnabled ? 0.08 : 0)))
            }
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(StudioMotion.hover) { isHovering = inside } }
    }
}
