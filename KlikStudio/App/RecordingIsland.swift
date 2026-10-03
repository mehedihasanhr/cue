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
    /// How close to an edge a drop has to be for the island to melt into it.
    private static let snap: CGFloat = 56

    init(studio: StudioService) {
        self.studio = studio
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the island, docked under the bar it replaces unless it was left elsewhere.
    func show(below barFrame: NSRect?) {
        let panel = panel ?? makePanel()
        let screen = barFrame.flatMap(Self.screen(containing:)) ?? NSScreen.main ?? NSScreen.screens[0]
        let center = lastCenter ?? CGPoint(x: barFrame?.midX ?? screen.frame.midX,
                                           y: screen.frame.minY + Self.height / 2)
        let landing = resting(for: center)
        state.isHovering = false
        if StudioMotion.reduceMotion {
            place(at: landing)
        } else {
            // Out of the edge it is docked to, the way a drop wells up; a floating island
            // just appears where it was.
            let docked = gap(at: landing)
            place(at: docked.distance < 1
                  ? CGPoint(x: landing.x, y: landing.y + (docked.edge == .bottom ? -Self.height : Self.height))
                  : landing)
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
        let size = NSSize(width: Self.openWidth + Self.margin * 2, height: Self.height + Self.margin * 2)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        let view = IslandView(state: state,
                              drag: { [weak self] in self?.drag() },
                              drop: { [weak self] in self?.drop() },
                              expand: { [weak self] in self?.expand() })
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    // MARK: - Moving

    private func drag() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            settle?.invalidate()
            settle = nil
            dragStart = (mouse, center)
        }
        guard let start = dragStart else { return }
        let wanted = CGPoint(x: start.center.x + mouse.x - start.mouse.x,
                             y: start.center.y + mouse.y - start.mouse.y)
        place(at: clamped(wanted))
    }

    private func drop() {
        dragStart = nil
        let landing = resting(for: center)
        lastCenter = landing
        animate(to: landing)
    }

    /// Where an island let go at `point` comes to rest: melted into the top or bottom edge
    /// when it is near one, and otherwise where it is, kept on the screen.
    private func resting(for point: CGPoint) -> CGPoint {
        let point = clamped(point)
        let screen = Self.screen(containing: CGRect(origin: point, size: .zero)) ?? NSScreen.screens[0]
        let half = Self.height / 2
        let near = gap(at: point)
        guard near.distance < Self.snap else { return point }
        return CGPoint(x: point.x, y: near.edge == .bottom ? screen.frame.minY + half : screen.frame.maxY - half)
    }

    /// Kept on the screen it is over, its full width inside, never pushed past an edge.
    private func clamped(_ point: CGPoint) -> CGPoint {
        let screen = Self.screen(containing: CGRect(origin: point, size: .zero)) ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        let halfWidth = Self.openWidth / 2, half = Self.height / 2
        return CGPoint(x: min(max(point.x, frame.minX + halfWidth), frame.maxX - halfWidth),
                       y: min(max(point.y, frame.minY + half), frame.maxY - half))
    }

    /// The nearer of the top and bottom edges of the island's screen, and how far away it is.
    private func gap(at point: CGPoint) -> (edge: VerticalEdge, distance: CGFloat) {
        let screen = Self.screen(containing: CGRect(origin: point, size: .zero)) ?? NSScreen.main ?? NSScreen.screens[0]
        let half = Self.height / 2
        let below = point.y - half - screen.frame.minY
        let above = screen.frame.maxY - (point.y + half)
        return below <= above ? (.bottom, below) : (.top, above)
    }

    private var center: CGPoint {
        guard let frame = panel?.frame else { return .zero }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func place(at point: CGPoint) {
        guard let panel else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: (point.x - size.width / 2).rounded(), y: (point.y - size.height / 2).rounded()))
        let near = gap(at: point)
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

    private static func screen(containing rect: CGRect) -> NSScreen? {
        let point = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.min { distance($0.frame, point) < distance($1.frame, point) }
    }

    private static func distance(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
    }
}

/// What the island's view draws from, set by the window as it moves.
@MainActor @Observable
private final class IslandState {
    /// The edge the island is nearest, and how far its near side is from it. Zero is
    /// docked: melted into the edge.
    var edge: VerticalEdge = .bottom
    var gap: CGFloat = 0
    var isHovering = false
}

private struct IslandView: View {
    @Environment(StudioService.self) private var studio
    let state: IslandState
    let drag: () -> Void
    let drop: () -> Void
    let expand: () -> Void

    private var width: CGFloat {
        state.isHovering ? RecordingIsland.openWidth : RecordingIsland.compactWidth
    }

    var body: some View {
        ZStack {
            IslandInk(width: width, gap: state.gap, edge: state.edge)
                .allowsHitTesting(false)
            controls
                .frame(width: width, height: RecordingIsland.height)
                .contentShape(Capsule())
                .onHover { inside in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { state.isHovering = inside }
                }
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in drag() }
                    .onEnded { _ in drop() })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            clock
                .padding(.leading, 14)
                .frame(width: RecordingIsland.compactWidth, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: expand)
                .help("Show the recorder bar")
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Show the recorder bar")
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
    let edge: VerticalEdge

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let height = RecordingIsland.height
            let island = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
            context.addFilter(.alphaThreshold(min: 0.5, color: .black))
            context.addFilter(.blur(radius: 6))
            context.drawLayer { layer in
                layer.fill(Path(roundedRect: island, cornerRadius: 15, style: .continuous), with: .color(.black))
                let reach: CGFloat = 80
                let edgeY = edge == .bottom ? island.maxY + gap : island.minY - gap
                let block = CGRect(x: island.minX - 20,
                                   y: edge == .bottom ? edgeY : edgeY - reach,
                                   width: island.width + 40, height: reach)
                layer.fill(Path(block), with: .color(.black))
            }
        }
    }
}
