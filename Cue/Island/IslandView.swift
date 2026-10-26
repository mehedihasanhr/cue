import SwiftUI
import UniformTypeIdentifiers

/// What the island shows: nothing (a black shape hiding on the notch), the capture
/// that was just taken, or the captures strip.
@Observable
final class IslandModel {
    enum Phase: Equatable {
        case collapsed
        case flash(CaptureItem)
        /// A moment's confirmation on the closed island ("Copied", "Task saved").
        case status(IslandStatus)
        /// A compact box asking for one line of text (a new project's name).
        case prompt(IslandPrompt)
        /// A task opened in the compact island: title, status, description.
        case taskDetail(UUID)
        /// The clock opened in the compact island: time, dates, prayer times.
        case clock
        /// The music player: what Music or Spotify plays, and its controls.
        case media
        /// The weather: now, and the next hours.
        case weather
        /// The camera as a mirror.
        case mirror
        /// The running agent sessions, and what they are asking.
        case agents
        case expanded

        var geometryPhase: IslandGeometry.Phase {
            switch self {
            case .collapsed: .collapsed
            case .flash: .flash
            case .status(let status): status.clock == nil ? .flash : .prompt
            case .prompt(let prompt): prompt.isForm ? .form : .prompt
            case .taskDetail, .clock, .media, .weather, .mirror, .agents: .form
            case .expanded: .expanded
            }
        }

        var isFlash: Bool {
            switch self {
            case .flash, .status: true
            case .collapsed, .expanded, .prompt, .taskDetail, .clock, .media, .weather, .mirror, .agents: false
            }
        }

        /// The compact box is as wide as its row (a flash, a status, a confirmation);
        /// text fields and forms keep a fixed width.
        var fitsContent: Bool {
            switch self {
            case .flash, .status: true
            case .prompt(let prompt): prompt.isConfirm
            case .collapsed, .expanded, .taskDetail, .clock, .media, .weather, .mirror, .agents: false
            }
        }
    }

    var phase: Phase = .collapsed
    var geometry: IslandGeometry?
    /// The compact box's row width, reported by the row itself (see `fitsContent`).
    var contentWidth: CGFloat?
    /// The clock view's height and natural width, reported by the view, so its box
    /// fits it — nothing in it is ever cut short.
    var clockHeight: CGFloat?
    var clockWidth: CGFloat?
    /// Coding-agent sessions; nil until the app delegate hands them over.
    var agents: AgentStore?
    /// What plays; set by the controller.
    var nowPlaying: NowPlaying?
    /// A focus session, for its tile; set by the controller.
    var focus: FocusTimer?
    /// The calendar, for its tile; set by the controller.
    var calendar: CalendarWatcher?
    /// The weather, for its tile and view; set by the controller.
    var weather: WeatherStore?
    /// Opens the forecast; set by the controller.
    var onShowWeather: () -> Void = {}
    /// Opens the camera mirror; set by the controller.
    var onShowMirror: () -> Void = {}
    /// Pops the player out into the mini player; set by the controller.
    var onDetachPlayer: () -> Void = {}
    /// Opens a link (a meeting's call) and closes; set by the controller.
    var onOpenURL: (URL) -> Void = { _ in }
    /// The tiles beside the closed notch, as the settings and what plays have them;
    /// set by the controller.
    var compactTiles: () -> CompactTiles = { CompactTiles() }
    var nowPlayingEnabled: () -> Bool = { false }
    /// Something plays and nobody is asking: the sessions list has the player beside it.
    var showsPlayerBesideAgents: Bool {
        nowPlayingEnabled() && nowPlaying?.track != nil && agents?.requests.isEmpty != false
    }
    /// The sessions list's height, reported by the view.
    var agentsHeight: CGFloat?
    /// Closed, but agents are at work: the notch shows them.
    var showsAmbient: Bool { agents?.isActive == true }
    /// The sessions list's height before it has measured itself (the first time it
    /// opens): close enough that the island opens in one movement, not to a default
    /// size and then again to the real one.
    var estimatedAgentsHeight: CGFloat {
        let sessions = CGFloat(agents?.sessions.count ?? 0)
        let questions = CGFloat(agents?.requests.count ?? 0)
        let workers = CGFloat(agents?.sessions.reduce(0) { $0 + $1.workers.count } ?? 0)
        let withWorkers = CGFloat(agents?.sessions.filter { !$0.workers.isEmpty }.count ?? 0)
        return min(50 + sessions * 74 + withWorkers * 10 + workers * 30 + questions * 160, IslandPanel.size.height)
    }
    /// Opens the full panel from the sessions list; set by the controller.
    var onOpenPanel: () -> Void = {}
    /// Leaves the sessions list; set by the controller.
    var onAgentsClosed: () -> Void = {}
    /// The open panel's width: wide enough for its tab row, at least the fixed size.
    private(set) var panelWidth: CGFloat = IslandPanel.size.width
    /// The open panel's height: what its content needs, at most the fixed size.
    private(set) var panelHeight: CGFloat = IslandPanel.size.height
    /// The window must grow with the panel; set by the controller.
    var onPanelWidthChanged: () -> Void = {}

    func setPanelWidth(_ width: CGFloat) {
        let width = max(width, IslandPanel.size.width).rounded()
        guard width != panelWidth else { return }
        panelWidth = width
        onPanelWidthChanged()
    }

    func setPanelHeight(_ height: CGFloat) {
        let height = min(height, IslandPanel.size.height).rounded()
        guard height != panelHeight else { return }
        panelHeight = height
    }

    /// The drawn shape in `phase`: the fixed rect, or the content-fitted one.
    func shapeRect(for phase: Phase) -> CGRect {
        guard let geometry else { return .zero }
        if phase == .collapsed, !compactTiles().isEmpty { return geometry.collapsed.insetBy(dx: -CompactTiles.sideWidth, dy: 0) }
        if phase == .expanded, showsDropZone { return geometry.dropZone(contentSize: IslandDropZone.size) }
        let width: CGFloat? = switch phase {
        case .expanded: panelWidth
        case .clock: clockWidth
        case .media: NowPlayingDetail.width
        case .weather: WeatherDetail.width
        case .mirror: MirrorView.width
        case .agents: IslandGeometry.agentsWidth + (showsPlayerBesideAgents ? NowPlayingDetail.columnWidth : 0)
        default: phase.fitsContent ? contentWidth : nil
        }
        let height: CGFloat? = switch phase {
        case .clock: clockHeight
        case .media: NowPlayingDetail.height
        case .weather: WeatherDetail.height
        case .mirror: MirrorView.height
        case .agents: max(agentsHeight ?? estimatedAgentsHeight, showsPlayerBesideAgents ? NowPlayingDetail.columnHeight : 0)
        case .expanded: panelHeight
        default: nil
        }
        return geometry.rect(for: phase.geometryPhase, contentWidth: width, contentHeight: height)
    }
    /// A drag with files or an image is over the island.
    var dropping = false
    /// Which of the drop zone's cards the pointer is over.
    var dropTarget: IslandDropZone.Target = .shelf
    /// Files were just dropped (how many, and where): the drop zone says so a moment.
    var dropSaved: IslandDropZone.Saved?
    /// The drop zone is showing, waiting for the drop or saying it was saved.
    var showsDropZone: Bool { dropping || dropSaved != nil }
    /// Asks the compact box for a line of text; called by the panel.
    var onPrompt: (IslandPrompt) -> Void = { _ in }
    /// The prompt's answer (nil: cancelled); set by the controller.
    var onPromptFinished: (IslandPrompt, PromptAnswer?) -> Void = { _, _ in }
    /// Opens a task in the compact island; called by the panel.
    var onShowTask: (TaskItem) -> Void = { _ in }
    /// Opens the task dashboard window; called by the panel, set by the controller.
    var onOpenTaskDashboard: () -> Void = {}
    /// Opens Settings; called by the panel, set by the controller.
    var onOpenSettings: () -> Void = {}
    /// Leaves the task detail (back to the open panel); set by the controller.
    var onTaskDetailClosed: (TaskItem?) -> Void = { _ in }
    /// A click on the closed shape opens it.
    var onTap: () -> Void = {}
    /// Opens the clock in the compact island (a click on a clock status or the
    /// prayer pill); set by the controller.
    var onShowClock: () -> Void = {}
    /// Opens a card in the pane under the island (+1: the next item slides in from
    /// the right, -1 from the left, 0: fades); set by the controller.
    var onPreviewPane: (IslandDetail, Int) -> Void = { _, _ in }
    /// Whether the pane is showing something; set by the controller. The panel reads
    /// it as it needs it rather than observing it, so nothing re-renders for it.
    var previewOpen = false
    /// Closes the pane (the pointer left the card and the pane); set by the controller.
    var onHidePreview: () -> Void = {}
    /// Whether the pointer is over the pane (or the gap above it); set by the controller.
    var isPointerInPreview: () -> Bool = { false }
    /// Bumped by the controller when the pointer leaves the pane, so the panel can
    /// close it unless the pointer went back onto a card.
    var previewLeaveTick = 0
    /// An arrow key that reached the window (the delta, and a count so each press
    /// is seen); set by the controller.
    var arrowPress: (delta: Int, tick: Int) = (0, 0)
    /// Leaves the clock; set by the controller.
    var onClockClosed: () -> Void = {}
    /// Shows a file in Finder (a download's notice clicked) and closes; set by the controller.
    var onReveal: (URL) -> Void = { _ in }
    /// The status showing is being used (a level dragged): it stays a while longer.
    var onHoldStatus: () -> Void = {}
    /// Opens the music player; set by the controller.
    var onShowMedia: () -> Void = {}
    /// Leaves the music player; set by the controller.
    var onMediaClosed: () -> Void = {}
    /// Settings › Time, from the clock; set by the controller.
    var onOpenTimeSettings: () -> Void = {}
}

/// The island's fill. Open panels in Liquid Glass, after the look it was asked for:
/// solid black at the top, where it meets the notch and where the content starts,
/// fading down into glass, so the desktop shows through the lower part of the panel.
/// Not glass all over, and no rim. Everything else (and every panel with the glass
/// off, or before macOS 26) is solid black.
///
/// One view for both looks, crossfading, rather than swapping a black fill for the
/// glass: swapped, both stayed on screen mid-change, the glass at its old size inside
/// the black at the new one, a second island inside the first.
private struct IslandFill: View {
    let shape: NotchShape
    /// Glass is on in Settings: the glass layer exists.
    let glassAllowed: Bool
    /// This panel shows the glass now.
    let glass: Bool
    /// Nothing drawn: the settled closed island beside the notch.
    let clear: Bool
    /// Settings › Island › Glass: clear or frosted, how dark, a tint.
    var style: AppPreferences.GlassStyle = .clear
    var darkness: Double = 0.45
    var tint: Color?
    /// No notch to meet (a plain display, with lighter glass on): no black band at the top.
    var light = false

    /// Where the black starts giving way to glass.
    private var fadeFrom: Double { light ? 0.12 : 0.45 }

    @available(macOS 26, *)
    private var glassKind: Glass {
        let base: Glass = style == .frosted ? .regular : .clear
        return tint.map { base.tint($0.opacity(0.25)) } ?? base
    }

    var body: some View {
        ZStack {
            if #available(macOS 26, *), glassAllowed {
                shape.fill(.clear)
                    .glassEffect(glassKind, in: shape)
                    .opacity(glass ? 1 : 0)
                LinearGradient(stops: [
                    .init(color: .black.opacity(light ? max(darkness, 0.55) : 1), location: 0),
                    .init(color: .black.opacity(light ? max(darkness, 0.4) : 1), location: fadeFrom),
                    .init(color: .black.opacity(darkness), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                // The tint, faint over the dark and stronger down where the glass shows.
                if let tint {
                    LinearGradient(colors: [tint.opacity(0.08), tint.opacity(0.28)], startPoint: .top, endPoint: .bottom)
                        .blendMode(.plusLighter)
                        .opacity(glass ? 1 : 0)
                }
            }
            Color.black.opacity(glass && glassAllowed ? 0 : 1)
        }
        .clipShape(shape)
        .opacity(clear ? 0 : 1)
    }
}

/// New content arriving in the island: faded, a little small and soft until shown.
private struct ContentArrival: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.94, anchor: .top)
            .blur(radius: shown ? 0 : 4)
    }
}

/// A shade around the open island, darkest below it and fading out at its edges,
/// so the panel stands off a busy desktop. Drawn only outside the shape: under the
/// glass it would darken what the glass shows.
private struct IslandHalo: View {
    let shape: NotchShape

    private static let blur: CGFloat = 18
    private static let room: CGFloat = 60

    var body: some View {
        shape
            .fill(LinearGradient(colors: [.clear, .black.opacity(0.22), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom))
            .offset(y: 6)
            .blur(radius: Self.blur)
            .mask {
                Rectangle()
                    .padding(-Self.room)
                    .overlay { shape.padding(Self.room).blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

extension AppPreferences.GlassTint {
    /// The colour washed over the island's glass.
    var color: Color? {
        switch self {
        case .none: nil
        case .blue: Color(red: 0.2, green: 0.5, blue: 1.0)
        case .purple: Color(red: 0.55, green: 0.35, blue: 1.0)
        case .pink: Color(red: 1.0, green: 0.35, blue: 0.65)
        case .orange: Color(red: 1.0, green: 0.55, blue: 0.2)
        case .green: Color(red: 0.25, green: 0.8, blue: 0.5)
        case .graphite: Color(white: 0.55)
        }
    }
}

/// The island silhouette: top corners flare outward into the bezel (a small flare
/// closed, a wide one open), bottom corners are rounded. All radii animate, so the
/// closed notch morphs into the open panel.
nonisolated struct NotchShape: Shape {
    /// Outward curve at the top corners (the notch meeting the bezel).
    var flare: CGFloat
    /// Inward rounding of the top corners (the open panel).
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(flare, AnimatablePair(topRadius, bottomRadius)) }
        set { flare = newValue.first; topRadius = newValue.second.first; bottomRadius = newValue.second.second }
    }

    /// `rect` includes the flares: the body spans `minX + flare … maxX - flare`, and
    /// the flares sweep from the body's top corners out to the rect's top corners.
    func path(in rect: CGRect) -> Path {
        let flare = min(self.flare, rect.width / 4)
        let body = rect.insetBy(dx: flare, dy: 0)
        let top = min(topRadius, body.width / 2, body.height / 2)
        let bottom = min(bottomRadius, body.width / 2, body.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        if flare > 0 {
            path.addQuadCurve(to: CGPoint(x: body.minX, y: body.minY + flare), control: CGPoint(x: body.minX, y: body.minY))
        } else {
            path.addLine(to: CGPoint(x: body.minX + top, y: body.minY))
            path.addQuadCurve(to: CGPoint(x: body.minX, y: body.minY + top), control: CGPoint(x: body.minX, y: body.minY))
        }
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: body.minX + bottom, y: body.maxY), control: CGPoint(x: body.minX, y: body.maxY))
        path.addLine(to: CGPoint(x: body.maxX - bottom, y: body.maxY))
        path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.maxY - bottom), control: CGPoint(x: body.maxX, y: body.maxY))
        if flare > 0 {
            path.addLine(to: CGPoint(x: body.maxX, y: body.minY + flare))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: body.maxX, y: body.minY))
        } else {
            path.addLine(to: CGPoint(x: body.maxX, y: body.minY + top))
            path.addQuadCurve(to: CGPoint(x: body.maxX - top, y: body.minY), control: CGPoint(x: body.maxX, y: body.minY))
        }
        path.closeSubpath()
        return path
    }
}

struct IslandView: View {
    let model: IslandModel
    let library: CaptureLibrary
    let clipboard: ClipboardHistory
    let assets: AssetStore
    let colors: ColorStore
    let tasks: TaskStore
    let snippets: SnippetStore
    let actions: HistoryActions
    @Environment(PrayerClock.self) private var clock: PrayerClock?
    @Environment(AppPreferences.self) private var preferences
    @Environment(NoteStore.self) private var notes
    @Environment(NowPlaying.self) private var nowPlaying

    /// Opening overshoots a touch; closing settles without a bounce. With Reduce
    /// Motion on, everything is a short ease instead. The springs quicken on faster
    /// displays (`IslandMotion`): the times here are those at 60 Hz.
    /// Settings › Island › Animation; the view sets it from the preferences it reads.
    nonisolated(unsafe) static var animationStyle: AppPreferences.IslandAnimation = .lively
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || animationStyle != .lively }
    static var openAnimation: Animation { animationStyle == .none ? .linear(duration: 0) : reduceMotion ? .easeOut(duration: 0.18) : .spring(response: IslandMotion.response(0.36), dampingFraction: 0.82, blendDuration: 0) }
    static var closeAnimation: Animation { animationStyle == .none ? .linear(duration: 0) : reduceMotion ? .easeOut(duration: 0.18) : .spring(response: IslandMotion.response(0.45), dampingFraction: 1.0, blendDuration: 0) }
    /// The agents list: rows moving, cards opening, and the island's height
    /// following them, all on one critically damped spring so they move together.
    static var listAnimation: Animation { animationStyle == .none ? .linear(duration: 0) : reduceMotion ? .easeOut(duration: 0.2) : .spring(response: IslandMotion.response(0.42), dampingFraction: 1.0) }
    static var contentAnimation: Animation { animationStyle == .none ? .linear(duration: 0) : reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: IslandMotion.response(0.28)) }

    /// Collapsed and settled: the shape is drawn clear so nothing shows beside the
    /// notch. Closing shrinks into the notch first (black all the way), then fades.
    @State private var faded = true

    /// Diagnostics: `--env CUE_DEBUG_GLASS=frosted,purple,0.3` shows that glass, whatever the settings say.
    private static let debugGlass: (style: AppPreferences.GlassStyle, tint: AppPreferences.GlassTint, darkness: Double)? = {
        #if DEBUG
        guard let parts = ProcessInfo.processInfo.environment["CUE_DEBUG_GLASS"]?.split(separator: ","), parts.count == 3,
              let style = AppPreferences.GlassStyle(rawValue: String(parts[0])), let tint = AppPreferences.GlassTint(rawValue: String(parts[1])),
              let darkness = Double(parts[2]) else { return nil }
        return (style, tint, darkness)
        #else
        return nil
        #endif
    }()

    var body: some View {
        let phase = model.phase
        let _ = { Self.animationStyle = preferences.islandAnimation; IslandMotion.speed = preferences.islandAnimationSpeed }()
        if let geometry = model.geometry {
            let asking = model.agents?.requests.isEmpty == false
            let size = model.shapeRect(for: phase).size
            let collapsed = phase == .collapsed
            let flare: CGFloat = collapsed ? 6 : IslandGeometry.openFlare
            let shape = NotchShape(flare: flare, topRadius: 0, bottomRadius: geometry.radius(for: phase.geometryPhase))
            ZStack(alignment: .top) {
                // Invisible once collapsed (nothing peeks out beside the notch, nor sits
                // on a plain menu bar); the tap target stays.
                IslandFill(shape: shape, glassAllowed: preferences.islandGlass,
                           glass: preferences.islandGlass && Self.hasBackdrop(phase),
                           clear: faded && !preferences.islandNotchBackground && model.compactTiles().isEmpty,
                           style: Self.debugGlass?.style ?? preferences.islandGlassStyle,
                           darkness: Self.debugGlass?.darkness ?? preferences.islandGlassDarkness,
                           tint: (Self.debugGlass?.tint ?? preferences.islandGlassTint).color,
                           light: preferences.islandGlassLightNotchless && !geometry.screen.hasNotch)
                content(for: phase, strip: geometry.stripHeight)
                    .compositingGroup()
                    .padding(.horizontal, flare) // the body; the flares lie outside it
            }
            // Top-aligned: while the height animates the content may be taller than the
            // frame, and it must overflow downward (clipped), never slide up.
            .frame(width: size.width + flare * 2, height: size.height, alignment: .top)
            .clipShape(shape)
            // The rim of every open panel: a hairline that catches the light toward
            // the bottom edge, clear where the shape meets the menu bar. Always there,
            // only faded, so it shrinks with the shape as the island closes rather than
            // being left behind at the open size while it fades.
            .overlay {
                // None on glass: the glass has an edge of its own, and a line drawn over it
                // reads as a border.
                let glass = preferences.islandGlass && Self.hasBackdrop(phase)
                shape.stroke(LinearGradient(colors: [.clear, .white.opacity(0.05), .white.opacity(0.16)], startPoint: .top, endPoint: .bottom),
                             lineWidth: 1)
                    .opacity(Self.hasBackdrop(phase) && !glass ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // A soft shade around every open panel, lifting it off whatever is behind.
            .background {
                IslandHalo(shape: shape)
                    .opacity(Self.hasBackdrop(phase) && Self.animationStyle != .none ? 1 : 0)
            }
            // While agents run, a thin line of light under the closed notch; the
            // notch itself stays plain black.
            .background(alignment: .top) {
                if collapsed, geometry.screen.hasNotch, model.agents?.isBusy == true {
                    NotchGlow(shape: shape, size: CGSize(width: size.width + flare * 2, height: size.height), asking: asking)
                        .transition(.opacity.animation(.easeOut(duration: 0.4)))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .onTapGesture {
                if collapsed {
                    model.onTap()
                } else if case .status(let status) = phase, status.clock != nil {
                    model.onShowClock()
                } else if case .status(let status) = phase, let notice = status.notice, notice.isClickable, let url = notice.url {
                    model.onReveal(url)
                }
            }
            .animation(collapsed ? Self.closeAnimation : Self.openAnimation, value: phase)
            .animation(Self.openAnimation, value: model.contentWidth)
            .animation(Self.openAnimation, value: model.panelWidth)
            .animation(Self.openAnimation, value: model.panelHeight)
            .animation(Self.openAnimation, value: model.showsDropZone)
            .animation(Self.openAnimation, value: model.clockHeight)
            .animation(Self.openAnimation, value: model.clockWidth)
            .animation(Self.listAnimation, value: model.agentsHeight)
            .animation(Self.listAnimation, value: model.showsPlayerBesideAgents)
            .animation(Self.openAnimation, value: model.compactTiles())
            .task(id: phase) {
                guard collapsed else { faded = false; return } // black at once, then grows
                try? await Task.sleep(for: .seconds(IslandMotion.response(0.46))) // the close animation
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { faded = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // While files are dragged over, the drop zone is smaller than the island's
            // span, where the drag is held under the menu bar. A drag beside it must still
            // land on the island (a fully clear pixel lets it through to whatever is
            // behind, and the island would close and reopen under it): a band across the
            // window's width, too faint to see, keeps it.
            .background(alignment: .top) {
                if model.dropping {
                    Color.black.opacity(0.01)
                        .frame(height: geometry.stripHeight + IslandDropZone.size.height + 24)
                        .allowsHitTesting(false)
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder
    private func content(for phase: IslandModel.Phase, strip: CGFloat) -> some View {
        switch phase {
        case .collapsed:
            let tiles = model.compactTiles()
            if !tiles.isEmpty, let geometry = model.geometry {
                // A tile either side of the notch, the notch itself left clear.
                HStack(spacing: 0) {
                    CompactTileView(tile: tiles.left, height: strip, nowPlaying: model.nowPlaying, focus: model.focus, calendar: model.calendar, weather: model.weather)
                    Color.clear.frame(width: geometry.collapsed.width)
                    CompactTileView(tile: tiles.right, height: strip, nowPlaying: model.nowPlaying, focus: model.focus, calendar: model.calendar, weather: model.weather)
                }
                .frame(height: strip)
                .transition(.opacity.animation(Self.contentAnimation))
            } else if model.showsAmbient, let agents = model.agents, let geometry = model.geometry, !geometry.screen.hasNotch {
                AgentAmbientRow(store: agents, notchWidth: max(0, geometry.collapsed.width - 64))
                    .frame(height: strip)
                    .transition(.opacity.animation(Self.contentAnimation))
            }
        case .flash(let item):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                FlashRow(item: item, library: library)
                    .modifier(IdealWidth { model.contentWidth = $0 })
                    .frame(height: IslandGeometry.flashContentHeight, alignment: .top)
            }
            .transition(Self.contentTransition)
        case .status(let status):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                if let clock = status.clock {
                    ClockRow(status: clock)
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.promptContentHeight)
                } else if let meeting = status.meeting {
                    MeetingRow(meeting: meeting, onJoin: { model.onOpenURL($0) })
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.flashContentHeight)
                } else if let notice = status.notice {
                    NoticeRow(notice: notice)
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.flashContentHeight)
                } else if let toggle = status.toggle {
                    ToggleRow(toggle: toggle)
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.flashContentHeight)
                } else if let device = status.audioDevice {
                    AudioDeviceRow(device: device)
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.flashContentHeight)
                } else if let battery = status.battery {
                    BatteryRow(battery: battery)
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.flashContentHeight)
                } else if let level = status.level {
                    LevelRow(level: level, onDrag: { model.onHoldStatus() })
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.flashContentHeight)
                } else if let done = status.agentDone {
                    AgentDoneRow(done: done)
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.flashContentHeight, alignment: .top)
                } else {
                    StatusRow(status: status)
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.flashContentHeight, alignment: .top)
                }
            }
            .transition(Self.contentTransition)
        case .prompt(let prompt):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                if case .snippet = prompt.kind {
                    SnippetFormRow(prompt: prompt, store: snippets, assets: assets) { answer in model.onPromptFinished(prompt, answer) }
                        .frame(height: IslandGeometry.formContentHeight)
                } else if case .fill(let snippet) = prompt.kind {
                    SnippetFillRow(snippet: snippet) { answer in model.onPromptFinished(prompt, answer) }
                        .frame(height: IslandGeometry.formContentHeight)
                } else if case .note = prompt.kind {
                    NoteFormRow(prompt: prompt, store: notes) { answer in model.onPromptFinished(prompt, answer) }
                        .frame(height: IslandGeometry.formContentHeight)
                } else if prompt.isForm {
                    TaskFormRow(prompt: prompt, store: tasks) { answer in model.onPromptFinished(prompt, answer) }
                        .frame(height: IslandGeometry.formContentHeight)
                } else if prompt.isConfirm {
                    ConfirmRow(prompt: prompt, detail: prompt.detail(tasks)) { answer in model.onPromptFinished(prompt, answer) }
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.promptContentHeight)
                } else {
                    PromptRow(prompt: prompt) { answer in model.onPromptFinished(prompt, answer) }
                        .frame(height: IslandGeometry.promptContentHeight)
                }
            }
            .transition(Self.contentTransition)
        case .clock:
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                ClockDetail(clock: clock, openSettings: { model.onOpenTimeSettings() }, close: { model.onClockClosed() })
                    .modifier(IdealHeight { model.clockHeight = $0 })
                    .modifier(IdealWidth { model.clockWidth = $0 })
                    .frame(width: model.shapeRect(for: .clock).width, height: model.clockHeight ?? IslandGeometry.formContentHeight)
            }
            .transition(Self.contentTransition)
        case .mirror:
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                MirrorView(close: { model.onMediaClosed() })
            }
            .transition(Self.contentTransition)
        case .weather:
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                if let weather = model.weather { WeatherDetail(weather: weather) }
            }
            .transition(Self.contentTransition)
        case .media:
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                NowPlayingDetail(nowPlaying: nowPlaying, close: { model.onMediaClosed() }, detach: { model.onDetachPlayer() })
            }
            .transition(Self.contentTransition)
        case .agents:
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                if let agents = model.agents {
                    // Music playing: the player in a column on the left, the sessions beside it.
                    HStack(alignment: .top, spacing: 0) {
                        if model.showsPlayerBesideAgents {
                            NowPlayingDetail(nowPlaying: nowPlaying, column: true)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                        AgentsView(store: agents, openPanel: { model.onOpenPanel() }, close: { model.onAgentsClosed() },
                                   reportHeight: { model.agentsHeight = $0 },
                                   maxHeight: model.geometry.map { $0.expanded.height - $0.stripHeight } ?? IslandPanel.size.height)
                            .frame(width: IslandGeometry.agentsWidth, height: model.agentsHeight ?? model.estimatedAgentsHeight, alignment: .top)
                    }
                    .animation(Self.listAnimation, value: model.showsPlayerBesideAgents)
                }
            }
            .transition(Self.contentTransition)
        case .taskDetail(let id):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                if let task = tasks.tasks.first(where: { $0.id == id }) {
                    TaskDetailRow(task: task, store: tasks, edit: { model.onPrompt(IslandPrompt(kind: .task(project: task.projectID), editing: task)) },
                                  delete: { model.onPrompt(IslandPrompt(kind: .delete(.task(task)))) },
                                  close: { model.onTaskDetailClosed(task) })
                        .frame(height: IslandGeometry.formContentHeight)
                }
            }
            .transition(Self.contentTransition)
        case .expanded:
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                IslandPanel(library: library, clipboard: clipboard, assets: assets, colors: colors, tasksStore: tasks, snippets: snippets, actions: actions,
                            width: model.panelWidth, onIdealWidth: { model.setPanelWidth($0) }, onIdealHeight: { model.setPanelHeight($0) },
                            onPrompt: { model.onPrompt($0) }, onShowTask: { model.onShowTask($0) }, onOpenTaskDashboard: { model.onOpenTaskDashboard() }, onOpenSettings: { model.onOpenSettings() },
                            onShowClock: { model.onShowClock() }, onShowMedia: { model.onShowMedia() }, onShowWeather: { model.onShowWeather() }, onShowMirror: { model.onShowMirror() }, onPreviewPane: { model.onPreviewPane($0, $1) }, isPreviewOpen: { model.previewOpen },
                            onHidePreview: { model.onHidePreview() }, isPointerInPreview: { model.isPointerInPreview() }, previewLeaveTick: model.previewLeaveTick, arrowPress: model.arrowPress)
                    .padding(.horizontal, IslandGeometry.panelHorizontalPadding)
                    .padding(.bottom, IslandGeometry.panelBottomPadding)
                    // Files dragged over: the panel steps aside (kept, so its search and
                    // tab are as they were after) for the drop zone.
                    .opacity(model.showsDropZone ? 0 : 1)
                    .overlay(alignment: .top) {
                        if model.showsDropZone {
                            IslandDropZone(target: model.dropTarget, saved: model.dropSaved)
                                .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity).animation(Self.contentAnimation))
                        }
                    }
            }
            .transition(Self.contentTransition)
        }
    }

    /// The panels that stay open to be used: they get the rim.
    static func hasBackdrop(_ phase: IslandModel.Phase) -> Bool {
        switch phase {
        case .expanded, .agents, .clock, .media, .weather, .mirror, .taskDetail, .prompt: true
        case .collapsed, .flash, .status: false
        }
    }

    /// The outline leads, the content follows: what was showing leaves at once (a
    /// quick fade, so nothing is left hanging outside the outline as it shrinks), and
    /// the new content comes in once the outline is under way, settling out of a soft
    /// blur as it grows to size.
    private static var contentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity.animation(contentAnimation) }
        return .asymmetric(
            insertion: .modifier(active: ContentArrival(shown: false), identity: ContentArrival(shown: true))
                .animation(.easeOut(duration: IslandMotion.response(0.22)).delay(IslandMotion.response(0.06))),
            removal: .opacity.animation(.easeOut(duration: IslandMotion.response(0.1))))
    }
}

/// Reports a view's ideal width so the island can fit it. A hidden copy laid out at
/// its ideal size does the measuring; the visible view then gets the clamped width
/// and truncates what does not fit.
/// The vertical twin of `IdealWidth`: the height a view wants at its given width.
struct IdealHeight: ViewModifier {
    let report: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background {
            content
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .disabled(true)
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
        }
    }
}

struct IdealWidth: ViewModifier {
    let report: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background {
            content
                .fixedSize()
                .hidden()
                .disabled(true) // its buttons must not answer clicks or shortcuts
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report($0) }
        }
    }
}

/// "Just captured": the thumbnail and a copied confirmation.
private struct FlashRow: View {
    let item: CaptureItem
    let library: CaptureLibrary

    var body: some View {
        StatusLayout(title: "Copied to clipboard", subtitle: item.dimensions, badge: .success) {
            StatusTile {
                if let thumbnail = library.thumbnail(for: item) {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.1)
                }
            }
        }
    }
}

/// A moment's confirmation: "Copied", "Task saved", "Saved to Assets" — with what it
/// was about (a thumbnail, a swatch, a line of text) when there is one.
struct IslandStatus: Equatable, Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var image: NSImage? = nil
    var swatch: PickedColor? = nil
    /// How long the island holds it before closing again.
    var duration: Duration = .seconds(1.8)
    /// Drawn as the clock (large time, prayer bar) instead of the plain line.
    var clock: ClockStatus? = nil
    /// Drawn as an agent's finished turn instead of the plain line.
    var agentDone: AgentDone? = nil
    /// Drawn as a level bar (the volume, the brightness) instead of the plain line.
    var level: LevelHUD? = nil
    /// Drawn as the battery (charger in or out, running low) instead of the plain line.
    var battery: BatteryHUD? = nil
    /// Drawn as a Bluetooth audio device coming or going, with its batteries.
    var audioDevice: AudioDeviceHUD? = nil
    /// Drawn as something switched on or off (Caps Lock, a Focus).
    var toggle: ToggleHUD? = nil
    /// Drawn as a notice: the network, a drive, a download.
    var notice: NoticeHUD? = nil
    /// Drawn as a meeting about to start, with Join for a call.
    var meeting: MeetingHUD? = nil

    /// Green for done, orange for "nothing to do", white otherwise.
    var tint: Color {
        if symbol.contains("checkmark") || symbol.contains("arrow.down.fill") { return .green }
        if symbol == "tray" || symbol.hasPrefix("exclamationmark") { return .orange }
        return .white
    }
}

/// The status as a row: its image or swatch (or its symbol, on a soft disc), title,
/// subtitle, and a badge saying how it went.
private struct StatusRow: View {
    let status: IslandStatus

    private var badge: StatusBadge {
        switch status.tint {
        case .green: .success
        case .orange: .warning
        default: .none
        }
    }

    var body: some View {
        StatusLayout(title: status.title, subtitle: status.subtitle, badge: badge, duration: status.duration) {
            leading
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let swatch = status.swatch {
            StatusTile { swatch.swiftUIColor }
        } else if let image = status.image {
            StatusTile { Image(nsImage: image).resizable().scaledToFill() }
        } else {
            // A bead in the status's colour: green done, orange "nothing to do", else blue.
            GlossyDisc(symbol: status.symbol, tint: status.tint == .white ? IslandStyle.accent : status.tint, size: statusTileSide)
        }
    }
}

/// A status's picture, or its symbol's disc: 34 pt, 7 in from the island's edge.
private let statusTileSide: CGFloat = 34

/// How a status went, as the badge on its right.
private enum StatusBadge { case success, warning, none }

/// The picture a status is about, on corners nested in the island's (its 18 less
/// the 7 between them).
private struct StatusTile<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: statusTileSide, height: statusTileSide)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }
}

/// Every status alike: what it's about on the left, the words focusing in one after
/// the other, a badge popping in on the right (a tick that draws itself, for one
/// that went well), and a hairline along the foot running down the time it stays.
private struct StatusLayout<Leading: View>: View {
    let title: String
    var subtitle: String?
    var badge: StatusBadge = .none
    /// How long it shows: the hairline runs out with it.
    var duration: Duration?
    @ViewBuilder let leading: () -> Leading

    @State private var shown = false
    @State private var remaining: CGFloat = 1
    /// The tick has landed: a ring pulses out and sparks fly.
    @State private var burst = false
    /// A sheen runs across the picture once it has settled.
    @State private var sheen: CGFloat = -1

    private static var green: Color { Color(red: 0.36, green: 0.86, blue: 0.56) }
    private static var orange: Color { Color(red: 1.0, green: 0.71, blue: 0.3) }

    var body: some View {
        HStack(spacing: 11) {
            leading()
                // A sheen across it once it has settled, like light catching it.
                .overlay {
                    LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 18)
                        .rotationEffect(.degrees(20))
                        .offset(x: sheen * 40)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                // Dropped in from above with a tilt, settling on a spring.
                .scaleEffect(shown ? 1 : 0.7)
                .rotationEffect(.degrees(shown ? 0 : -8))
                .offset(y: shown ? 0 : -10)
                .opacity(shown ? 1 : 0)
                .animation(IslandMotion.bouncy(0.42, damping: 0.62), value: shown)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .modifier(FocusIn(shown: shown, delay: 0.06))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                        .modifier(FocusIn(shown: shown, delay: 0.13))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 14)
            badgeView
        }
        .padding(.horizontal, 16)
        // A touch above centre, leaving the foot to the hairline.
        .padding(.bottom, duration == nil ? 0 : 4)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if duration != nil {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(width: proxy.size.width * remaining, height: 1.5)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 1.5)
                // Clear of the island's rounded corners.
                .padding(.horizontal, 24)
                .padding(.bottom, 2)
            }
        }
        .onAppear {
            shown = true
            if !IslandView.reduceMotion {
                Task {
                    // As the picture lands, then as the tick finishes drawing.
                    try? await Task.sleep(for: .milliseconds(380))
                    withAnimation(.easeInOut(duration: 0.6)) { sheen = 1 }
                    try? await Task.sleep(for: .milliseconds(120))
                    burst = true
                }
            }
            if let duration, !IslandView.reduceMotion {
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                withAnimation(.linear(duration: seconds)) { remaining = 0 }
            }
        }
    }

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .success:
            ZStack {
                // The burst, once: a ring pulsing out and sparks flying from the rim,
                // both gone before and after.
                ZStack {
                    Circle().strokeBorder(Self.green.opacity(0.7), lineWidth: 1.5)
                    ForEach(0..<6, id: \.self) { index in
                        Circle()
                            .fill(Self.green)
                            .frame(width: 3, height: 3)
                            .offset(y: -12)
                            .rotationEffect(.degrees(Double(index) * 60 + 30))
                    }
                }
                .keyframeAnimator(initialValue: 0.0, trigger: burst) { burst, progress in
                    burst
                        .scaleEffect(1 + 0.8 * progress)
                        .opacity(progress == 0 ? 0 : 1 - progress)
                } keyframes: { _ in
                    LinearKeyframe(0.0, duration: 0.01)
                    CubicKeyframe(1.0, duration: 0.6)
                }
                Circle().fill(Self.green.opacity(0.18))
                Circle().strokeBorder(Self.green.opacity(0.45), lineWidth: 1.2)
                TickShape()
                    .trim(from: 0, to: shown ? 1 : 0)
                    .stroke(Self.green, style: SwiftUI.StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .animation(.easeOut(duration: 0.35).delay(0.18), value: shown)
            }
            .frame(width: 24, height: 24)
            .scaleEffect(shown ? 1 : 0.4)
            .animation(IslandMotion.bouncy(0.38, damping: 0.6).delay(0.08), value: shown)
        case .warning:
            Icon("exclamationmark", size: 13, weight: .bold)
                .foregroundStyle(Self.orange)
                .frame(width: 24, height: 24)
                .background(Self.orange.opacity(0.18), in: Circle())
                .overlay(Circle().strokeBorder(Self.orange.opacity(0.45), lineWidth: 1.2))
                .scaleEffect(shown ? 1 : 0.4)
                .animation(IslandMotion.bouncy(0.38, damping: 0.6).delay(0.08), value: shown)
        case .none:
            EmptyView()
        }
    }
}

/// A tick, drawn as one stroke so it can draw itself.
private nonisolated struct TickShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.66))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.71, y: rect.minY + rect.height * 0.37))
        return path
    }
}

/// Something the compact island asks for: one line (a project's name) or a small
/// form (a task).
struct IslandPrompt: Hashable {
    enum Kind: Hashable {
        case project(parent: UUID?)
        case task(project: UUID?)
        /// Rename a card (capture, asset, clipboard entry or color).
        case rename(IslandDetail)
        /// Confirm deleting a task or a project.
        case delete(TaskDeletion)
        /// A new snippet (from a template text or an asset), or an edit of one.
        case snippet(Snippet?, initialText: String, assetID: UUID?)
        /// Fill a snippet's blanks before it is pasted.
        case fill(Snippet)
        /// A new note, or an edit of one.
        case note(Note?)
        /// A new group for captures, clipboard entries or colors (with an item to
        /// put in it), or a rename of one.
        case group(GroupKind, assign: GroupAssignment?, editing: ItemGroup?)
    }

    let kind: Kind
    /// What is being created, for the label ("New sub-project in Work").
    var context: String? = nil
    /// An existing task to edit instead of creating one.
    var editing: TaskItem? = nil
    /// The current name, prefilled and selected, for renames.
    var initial = ""
    /// A new task's description to start from (a capture, say).
    var initialNotes = ""
    /// A thumbnail to show beside a rename.
    var image: NSImage? = nil
    /// A swatch to show beside a rename.
    var swatch: PickedColor? = nil
    let id = UUID()

    static func == (lhs: IslandPrompt, rhs: IslandPrompt) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isForm: Bool {
        switch kind {
        case .task, .snippet, .fill, .note: true
        default: false
        }
    }

    /// A new task or an edit of one.
    var isTaskForm: Bool {
        if case .task = kind { return true }
        return false
    }

    /// A yes/no box (Cancel / Delete) rather than a text field.
    var isConfirm: Bool {
        if case .delete = kind { return true }
        return false
    }

    /// What a confirmation is about: the task's title, or the project and what goes with it.
    func detail(_ store: TaskStore) -> String {
        switch kind {
        case .delete(.task(let task)): task.title
        case .delete(.project(let project)): store.deletionSummary(for: project)
        default: ""
        }
    }

    var title: String {
        switch kind {
        case .delete(.task): return "Delete this task?"
        case .delete(.project): return "Delete this project?"
        case .project(let parent):
            if parent == nil { return "New project" }
            return context.map { "New sub-project in \($0)" } ?? "New sub-project"
        case .task: return editing == nil ? "New task" : "Edit task"
        case .group(_, _, let editing): return editing == nil ? "New group" : "Rename group"
        case .snippet(let snippet, _, let asset): return snippet == nil ? (asset == nil ? "New snippet" : "New snippet from this file") : "Edit snippet"
        case .fill(let snippet): return "Fill in \(snippet.title)"
        case .note(let note): return note == nil ? "New note" : "Edit note"
        case .rename(let detail):
            switch detail {
            case .capture: return "Rename capture"
            case .asset: return "Rename file"
            case .clipboard: return "Name this clipboard entry"
            case .color: return "Name this color"
            case .note, .task: return "Name"
            }
        }
    }

    var placeholder: String {
        switch kind {
        case .project: "Project name"
        case .group: "Group name"
        case .task: "Task title"
        case .rename: "Name"
        case .delete, .snippet, .fill, .note: ""
        }
    }

    var symbol: String {
        switch kind {
        case .project, .group: "folder.badge.plus"
        case .task: "checklist"
        case .rename: "pencil"
        case .delete: "trash"
        case .snippet, .fill: "text.badge.plus"
        case .note: "note.text"
        }
    }
}

/// What a prompt hands back.
struct PromptAnswer {
    var title: String
    var notes = ""
    /// A task's whole text (its title is the first line of it).
    var text = ""
    var projectID: UUID?
    var priority: TaskPriority = .medium
    /// A snippet's name.
    var name = ""
    /// A snippet's filled blanks.
    var values: [String: String] = [:]
    /// Where a new note goes besides its folder (`NoteDestination` raw values).
    var sendTo: [String] = []
}

/// The compact island's one-line form: an icon, what is being created, and the field.
private struct PromptRow: View {
    let prompt: IslandPrompt
    let finish: (PromptAnswer?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let image = prompt.image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 44, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.15)))
            } else if let swatch = prompt.swatch {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(swatch.swiftUIColor)
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.15)))
            } else {
                PromptBadge(symbol: prompt.symbol)
            }
            VStack(alignment: .leading, spacing: 4) {
                PromptLabel(prompt.title)
                PromptBox {
                    InlineTextField(placeholder: prompt.placeholder, initial: prompt.initial, font: .system(size: 13, weight: .medium), boxed: false, selectAll: true,
                                    commit: { finish(PromptAnswer(title: $0)) }, cancel: { finish(nil) })
                    KeyCap("↩")
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}

/// The compact island's yes/no box: what is about to be deleted, Cancel and Delete.
/// ⎋ cancels, ↩ deletes; as wide as its content.
private struct ConfirmRow: View {
    let prompt: IslandPrompt
    let detail: String
    let finish: (PromptAnswer?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            PromptBadge(symbol: prompt.symbol, tint: .red)
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            Button("Cancel") { finish(nil) }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.white.opacity(0.1), in: Capsule())
            Button("Delete") { finish(PromptAnswer(title: "")) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(.red.opacity(0.85), in: Capsule())
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }
}

/// The compact island's task form: title, a Markdown description with a formatting
/// bar (images can be pasted or dropped in), and the project — a dropdown that can
/// also create a new project on the spot.
struct TaskFormRow: View {
    /// In the island: a header, a framed editor with its formatting bar, pill
    /// buttons. Floating: one pane — the text alone on the glass, and a bar of
    /// glass buttons under it with a round Create.
    enum Style { case island, floating }

    let prompt: IslandPrompt
    let store: TaskStore
    var style: Style = .island
    let finish: (PromptAnswer?) -> Void

    /// The whole task as one text: the first line is the title (with `#project` and
    /// `!priority` tokens in it, if any), the rest the description.
    @State private var text = ""
    @State private var projectID: UUID?
    @State private var priority: TaskPriority = .medium
    @State private var newProjectName: String?
    /// A project named with `#` that does not exist yet: made when the task is.
    @State private var pendingProject: String?
    @State private var editor = MarkdownEditor.Handle()
    @FocusState private var focus: Field?
    /// The token at the caret (`/`, `#` or `!` and what follows), and the row
    /// highlighted in the list it brings up.
    @State private var token: String?
    @State private var highlighted = 0

    private enum Field { case notes }

    /// One row of a suggestion list: what it shows and what picking it does.
    private struct Suggestion: Identifiable {
        let id: String
        let symbol: String
        let title: String
        var detail: String?
        var tint: Color = .primary
        let pick: () -> Void
    }

    /// `/` lists the formatting commands, `#` the projects, `!` the priorities —
    /// narrowed by what is typed after the mark.
    private var suggestions: [Suggestion] {
        guard let token, let mark = token.first else { return [] }
        let query = token.dropFirst().lowercased()
        func matches(_ text: String) -> Bool { query.isEmpty || TaskTokens.compact(text).contains(query) }
        switch mark {
        case "/":
            let commands: [(String, String, String?, () -> Void)] = [
                ("bold", "Bold", "⌘B", { editor.removeToken(); editor.bold() }),
                ("italic", "Italic", "⌘I", { editor.removeToken(); editor.italic() }),
                ("strikethrough", "Strikethrough", "⌘⇧X", { editor.removeToken(); editor.strikethrough() }),
                ("chevron.left.forwardslash.chevron.right", "Code", "⌘E", { editor.removeToken(); editor.code() }),
                ("textformat.size.larger", "Heading 1", nil, { editor.removeToken(); editor.block(.heading1) }),
                ("textformat.size", "Heading 2", "⌘⇧H", { editor.removeToken(); editor.block(.heading2) }),
                ("textformat.size.smaller", "Heading 3", nil, { editor.removeToken(); editor.block(.heading3) }),
                ("list.bullet", "Bullet list", "⌘⇧L", { editor.removeToken(); editor.block(.bullet) }),
                ("list.number", "Numbered list", "⌘⇧N", { editor.removeToken(); editor.block(.numbered) }),
                ("checklist", "Checklist", "⌘⇧T", { editor.removeToken(); editor.block(.todo) }),
                ("text.quote", "Quote", "⌘⇧Q", { editor.removeToken(); editor.block(.quote) }),
                ("curlybraces", "Code block", nil, { editor.removeToken(); editor.block(.code) }),
                ("photo", "Image…", "⌘⇧I", { editor.removeToken(); chooseImage() }),
                ("folder", "Project…", "#", { editor.replaceToken(with: "#") }),
                ("flag", "Priority…", "!", { editor.replaceToken(with: "!") }),
            ]
            return commands.filter { matches($0.1) }.map { Suggestion(id: $0.1, symbol: $0.0, title: $0.1, detail: $0.2, pick: $0.3) }
        case "#":
            let projects = store.projects.sorted { store.path(to: $0.id).map(\.name).joined(separator: "/") < store.path(to: $1.id).map(\.name).joined(separator: "/") }
            var rows = projects.filter { matches($0.name) }.map { project in
                // The pick shows in the project button; the token has done its work.
                Suggestion(id: project.id.uuidString, symbol: "folder", title: store.path(to: project.id).map(\.name).joined(separator: " › "), pick: {
                    projectID = project.id
                    pendingProject = nil
                    editor.removeToken()
                })
            }
            if !query.isEmpty, !projects.contains(where: { TaskTokens.compact($0.name) == query }) {
                rows.append(Suggestion(id: "new", symbol: "folder.badge.plus", title: "New project “\(token.dropFirst())”", detail: "created when the task is", pick: {
                    pendingProject = String(token.dropFirst())
                    projectID = nil
                    editor.removeToken()
                }))
            }
            return rows
        case "!":
            return TaskPriority.allCases.filter { matches($0.title) }.map { value in
                Suggestion(id: value.rawValue, symbol: value.symbol, title: value.title, detail: "⌘\((TaskPriority.allCases.firstIndex(of: value) ?? 0) + 1)", tint: value.color, pick: {
                    priority = value
                    editor.removeToken()
                })
            }
        default:
            return []
        }
    }

    /// ↑ ↓ move, ↩ ⇥ pick, ⎋ dismisses — while a list is up; otherwise the editor
    /// keeps its keys.
    private func intercept(_ selector: Selector) -> Bool {
        let rows = suggestions
        guard token != nil, !rows.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            highlighted = (highlighted - 1 + rows.count) % rows.count
        case #selector(NSResponder.moveDown(_:)):
            highlighted = (highlighted + 1) % rows.count
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            rows[min(highlighted, rows.count - 1)].pick()
            token = nil
        case #selector(NSResponder.cancelOperation(_:)):
            token = nil
        default:
            return false
        }
        return true
    }

    /// The list, above the caret's line: drawn at the bottom of the editor.
    @ViewBuilder
    private var suggestionList: some View {
        let rows = suggestions
        if token != nil, !rows.isEmpty {
            // Seven rows at a time, the window sliding with the highlight.
            let visible = 7
            let first = max(0, min(highlighted - visible + 1, rows.count - visible))
            let shown = Array(rows.enumerated()).filter { $0.offset >= first && $0.offset < first + visible }
            VStack(spacing: 1) {
                ForEach(shown, id: \.element.id) { index, row in
                    HStack(spacing: 9) {
                        Icon(row.symbol, size: 14, weight: .semibold)
                            .foregroundStyle(row.tint == .primary ? Color.primary.opacity(0.8) : row.tint)
                            .frame(width: 16)
                        Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let detail = row.detail {
                            Text(detail).font(.system(size: 10)).foregroundStyle(.primary.opacity(0.45))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(index == highlighted ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { row.pick(); token = nil }
                    .onHover { if $0 { highlighted = index } }
                }
            }
            .padding(4)
            .frame(width: 260)
            .liquidGlass(cornerRadius: 10)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            .accessibilityLabel("Suggestions")
        }
    }

    /// The first line that says anything, without its block mark — where the
    /// `#project` and `!priority` tokens live.
    private var firstLine: String { TaskText.splitMark(TaskText.titleLine(of: text)).body }

    private var valid: Bool { !TaskText.plain(TaskTokens.parse(firstLine).title).isEmpty }

    /// `#project` / `!priority` on the first line drive the pickers as they are typed.
    private func applyTokens() {
        let parsed = TaskTokens.parse(firstLine)
        if let priority = parsed.priority { self.priority = priority }
        if let name = parsed.project, let project = store.projects.first(where: { TaskTokens.compact($0.name) == TaskTokens.compact(name) }) {
            projectID = project.id
        }
    }

    var body: some View {
        Group {
            switch style {
            case .island: islandBody
            case .floating: floatingBody
            }
        }
        .background { priorityShortcuts }
        .background(KeyWindowFocus())
        .onAppear {
            if let task = prompt.editing {
                text = task.text
                projectID = task.projectID
                priority = task.priority
            } else if case .task(let project) = prompt.kind {
                projectID = project
                text = prompt.initialNotes.isEmpty ? "" : "\n" + prompt.initialNotes
            }
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                focus = .notes
                if text.hasPrefix("\n") { editor.moveToStart() }
            }
        }
        .onExitCommand { finish(nil) }
    }

    private var markdownEditor: some View {
        MarkdownEditor(text: $text, handle: editor, insertImage: { data in store.saveImage(data) }, insertFile: { url in store.saveAttachment(url) },
                       imageURL: { store.imageURL(for: $0) }, attachmentURL: { store.attachmentURL(for: $0) }, fontSize: style == .floating ? 17 : 12)
            .focused($focus, equals: .notes)
            .overlay(alignment: .bottomLeading) {
                // The floating form lists them in a section of its own, as Raycast does.
                if style == .island {
                    suggestionList
                        .padding(.leading, 8)
                        .padding(.bottom, 6)
                        .animation(.easeOut(duration: 0.12), value: token)
                }
            }
            .onAppear {
                editor.onToken = { new in
                    if new != token { highlighted = 0 }
                    token = new
                }
                editor.interceptCommand = { intercept($0) }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(style == .floating ? "What needs doing?" : "What needs doing? #project · !priority · / for formatting")
                        .font(.system(size: style == .floating ? 17 : 13))
                        .foregroundStyle(.primary.opacity(style == .floating ? 0.4 : 0.3))
                        .padding(.horizontal, 12).padding(.top, style == .floating ? 6 : 8)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: text) { _, _ in applyTokens() }
    }

    // MARK: Floating

    @State private var showsActions = false

    /// Raycast's panel: an input row (the task's icon, the text in a large hand, and on
    /// the right the project and priority as quiet menus), `#` `!` `/` suggestions as a
    /// section under it, and a footer — a round menu button on the left, and on the
    /// right a pill of the main action and Actions, each with its keys.
    private var floatingBody: some View {
        // The buttons float over the foot of the text, on no bar of their own.
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                markdownEditor
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                raycastSuggestions
            }
            // Room for the floating buttons, so the last line is never under them.
            .padding(.bottom, 50)
            footer
        }
        .animation(.easeOut(duration: 0.14), value: token)
    }

    /// The project and priority: small bordered menus in the footer.
    @ViewBuilder
    private var accessories: some View {
        HStack(spacing: 2) {
            if newProjectName != nil {
                InlineTextField(placeholder: "New project", font: .system(size: 13), boxed: false) { name in
                    newProjectName = nil
                    if let project = store.addProject(named: name) { projectID = project.id }
                } cancel: {
                    newProjectName = nil
                }
                .frame(width: 130)
            } else {
                Menu { projectMenuItems } label: {
                    accessoryLabel(symbol: pendingProject != nil ? "folder.badge.plus" : "folder",
                                   title: store.project(projectID)?.name ?? pendingProject ?? "No project",
                                   tint: .secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Project — or type #name")
            }
            Menu {
                ForEach(TaskPriority.allCases, id: \.self) { value in
                    Button { priority = value } label: { Label { Text(value.title) } icon: { Icon(value.symbol, weight: .medium) } }
                }
            } label: {
                accessoryLabel(symbol: priority.symbol, title: priority.title, tint: priority == .medium ? .secondary : priority.color)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Priority — or type !urgent, ⌘1–4")
        }
    }

    private func accessoryLabel(symbol: String, title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 160)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .floatingButton(Capsule())
    }

    /// `#` projects, `!` priorities, `/` formatting — a Raycast section under the text.
    @ViewBuilder
    private var raycastSuggestions: some View {
        let rows = suggestions
        if let token, let mark = token.first, !rows.isEmpty {
            let visible = 5
            let first = max(0, min(highlighted - visible + 1, rows.count - visible))
            let shown = Array(rows.enumerated()).filter { $0.offset >= first && $0.offset < first + visible }
            VStack(alignment: .leading, spacing: 2) {
                Text(mark == "#" ? "Projects" : mark == "!" ? "Priority" : "Formatting")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                ForEach(shown, id: \.element.id) { index, row in
                    HStack(spacing: 12) {
                        Icon(row.symbol, size: 14, weight: .semibold)
                            .foregroundStyle(row.tint == .primary ? Color.primary.opacity(0.75) : row.tint)
                            .frame(width: 26, height: 26)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(row.title).font(.system(size: 14)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let detail = row.detail {
                            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(index == highlighted ? Color.primary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { row.pick(); self.token = nil }
                    .onHover { if $0 { highlighted = index } }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityLabel("Suggestions")
        }
    }

    /// The footer: the formatting menu as a round button on the left; on the right a
    /// pill with Create (⌘↩) and Actions (⌘K).
    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Attach Image…", action: chooseImage).keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Bold", action: { editor.bold() }).keyboardShortcut("b")
                Button("Italic", action: { editor.italic() }).keyboardShortcut("i")
                Button("Strikethrough", action: { editor.strikethrough() }).keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Code", action: { editor.code() }).keyboardShortcut("e")
                Divider()
                Button("Heading", action: { editor.block(.heading2) }).keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Bullet List", action: { editor.block(.bullet) }).keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Numbered List", action: { editor.block(.numbered) }).keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Checklist", action: { editor.block(.todo) }).keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Quote", action: { editor.block(.quote) }).keyboardShortcut("q", modifiers: [.command, .shift])
                Button("Code Block", action: { editor.block(.code) })
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .floatingButton(Circle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Formatting and attachments — or type / in the text")

            accessories

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Button(action: create) {
                    HStack(spacing: 8) {
                        Text(prompt.editing == nil ? "Create Task" : "Save Task")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(valid ? Color.primary : Color.primary.opacity(0.4))
                        HStack(spacing: 3) { RaycastKey("⌘"); RaycastKey("↩") }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!valid)

                Rectangle().fill(.primary.opacity(0.1)).frame(width: 1, height: 16)

                Button { showsActions.toggle() } label: {
                    HStack(spacing: 8) {
                        Text("Actions").font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 3) { RaycastKey("⌘"); RaycastKey("K") }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k")
                .popover(isPresented: $showsActions, arrowEdge: .top) { actionsList }
            }
            .padding(.horizontal, 3)
            .frame(height: 28)
            .floatingButton(Capsule())
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    /// What ⌘K lists, Raycast-style: attach, the project, the priority, cancel.
    private var actionsList: some View {
        VStack(alignment: .leading, spacing: 1) {
            actionSection("Task")
            actionRow("Paste from Clipboard", symbol: "doc.on.clipboard", keys: "⌘V") {
                showsActions = false
                // A capture just taken is on the clipboard: it lands in the task.
                if let textView = editor.textView {
                    textView.window?.makeFirstResponder(textView)
                    textView.paste(nil)
                }
            }
            actionRow("Attach Image…", symbol: "photo", keys: "⇧⌘I") { showsActions = false; chooseImage() }
            actionRow("New Project…", symbol: "folder.badge.plus") { showsActions = false; newProjectName = "" }
            actionSection("Project")
            actionRow("No project", symbol: "tray", checked: projectID == nil && pendingProject == nil) { projectID = nil; pendingProject = nil; showsActions = false }
            ForEach(store.projects.sorted { store.path(to: $0.id).map(\.name).joined(separator: "/") < store.path(to: $1.id).map(\.name).joined(separator: "/") }) { project in
                actionRow(store.path(to: project.id).map(\.name).joined(separator: " › "), symbol: "folder", checked: projectID == project.id) {
                    projectID = project.id
                    pendingProject = nil
                    showsActions = false
                }
            }
            actionSection("Priority")
            ForEach(Array(TaskPriority.allCases.enumerated()), id: \.element) { index, value in
                actionRow(value.title, symbol: value.symbol, keys: "⌘\(index + 1)", checked: priority == value, tint: value.color) {
                    priority = value
                    showsActions = false
                }
            }
            Divider().padding(.vertical, 4)
            actionRow("Cancel", symbol: "xmark", keys: "esc") { showsActions = false; finish(nil) }
        }
        .padding(6)
        .frame(width: 280)
    }

    private func actionSection(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func actionRow(_ title: String, symbol: String, keys: String? = nil, checked: Bool = false, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(symbol, size: 13, weight: .medium)
                    .foregroundStyle(tint == .primary ? Color.primary.opacity(0.7) : tint)
                    .frame(width: 18)
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 6)
                if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                if let keys { Text(keys).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(RaycastRowStyle())
    }

    // MARK: Island

    private var islandBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PromptBadge(symbol: prompt.symbol)
                PromptLabel(prompt.title)
                Spacer(minLength: 0)
                KeyCap("esc")
                Text("cancel").font(.system(size: 10)).foregroundStyle(.primary.opacity(0.45))
            }
            VStack(spacing: 0) {
                formatBar
                markdownEditor
            }
            .fieldChrome(focused: focus == .notes)
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                if newProjectName != nil {
                    PromptBox {
                        Icon("folder.badge.plus", size: 14, weight: .semibold).foregroundStyle(.primary.opacity(0.7)).padding(.leading, 8)
                        InlineTextField(placeholder: "New project name", font: .system(size: 12, weight: .medium), boxed: false) { name in
                            newProjectName = nil
                            if let project = store.addProject(named: name) { projectID = project.id }
                        } cancel: {
                            newProjectName = nil
                        }
                    }
                } else {
                    projectMenu
                }
                PriorityMenu(priority: priority) { priority = $0 }
                Spacer(minLength: 0)
                Button("Cancel") { finish(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.primary.opacity(0.1), in: Capsule())
                    .layoutPriority(2)
                Button(action: create) {
                    HStack(spacing: 6) {
                        Text(prompt.editing == nil ? "Create" : "Save").font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        KeyCap("⌘↩")
                    }
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.leading, 14).padding(.trailing, 8)
                    .frame(height: 30)
                    .background(Color.brand, in: Capsule())
                    .opacity(valid ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!valid)
                .layoutPriority(2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// ⌘1–⌘4 set the priority (urgent → low).
    private var priorityShortcuts: some View {
        ForEach(Array(TaskPriority.allCases.enumerated()), id: \.element) { index, value in
            Button("") { priority = value }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Bold, italic, heading, list, quote, image — applied to the selection or the line.
    private var formatBar: some View {
        HStack(spacing: 2) {
            formatButton("bold", help: "Bold", shortcut: KeyboardShortcut("b")) { editor.bold() }
            formatButton("italic", help: "Italic", shortcut: KeyboardShortcut("i")) { editor.italic() }
            formatButton("strikethrough", help: "Strikethrough", shortcut: KeyboardShortcut("x", modifiers: [.command, .shift])) { editor.strikethrough() }
            formatButton("textformat.size", help: "Heading", shortcut: KeyboardShortcut("h", modifiers: [.command, .shift])) { editor.block(.heading2) }
            formatButton("list.bullet", help: "Bullet list", shortcut: KeyboardShortcut("l", modifiers: [.command, .shift])) { editor.block(.bullet) }
            formatButton("list.number", help: "Numbered list", shortcut: KeyboardShortcut("n", modifiers: [.command, .shift])) { editor.block(.numbered) }
            formatButton("checklist", help: "Checklist", shortcut: KeyboardShortcut("t", modifiers: [.command, .shift])) { editor.block(.todo) }
            formatButton("text.quote", help: "Quote", shortcut: KeyboardShortcut("q", modifiers: [.command, .shift])) { editor.block(.quote) }
            formatButton("photo", help: "Insert image…", shortcut: KeyboardShortcut("i", modifiers: [.command, .shift])) { chooseImage() }
            Spacer(minLength: 0)
            Text("/ formats · #project · !priority · ⌘1–4 priority · ⌘B ⌘I")
                .font(.system(size: 9.5))
                .foregroundStyle(.primary.opacity(0.4))
                .lineLimit(1)
                .padding(.trailing, 8)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func formatButton(_ symbol: String, help: String, shortcut: KeyboardShortcut, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(symbol, size: 13, weight: .semibold)
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .help("\(help) (\(shortcut.display))")
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let markdown = store.saveImage(data) else { return }
        editor.insertBlock(markdown)
    }

    /// Every project by its path, "No project", and "New project…".
    @ViewBuilder
    private var projectMenuItems: some View {
        Button("No project") { projectID = nil; pendingProject = nil }
        if !store.projects.isEmpty { Divider() }
        ForEach(store.projects.sorted { store.path(to: $0.id).map(\.name).joined(separator: "/") < store.path(to: $1.id).map(\.name).joined(separator: "/") }) { project in
            Button {
                projectID = project.id
                pendingProject = nil
            } label: {
                if project.id == projectID {
                    Label { Text(store.path(to: project.id).map(\.name).joined(separator: " › ")) } icon: { Icon("checkmark", weight: .medium) }
                } else {
                    Text(store.path(to: project.id).map(\.name).joined(separator: " › "))
                }
            }
        }
        Divider()
        Button("New Project…") { newProjectName = "" }
    }

    private var projectMenu: some View {
        Menu {
            projectMenuItems
        } label: {
            HStack(spacing: 6) {
                Icon("folder", size: 14, weight: .semibold)
                Text(store.project(projectID).map { store.path(to: $0.id).map(\.name).joined(separator: " › ") } ?? "No project")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize()
                Icon("chevron.down", size: 11, weight: .bold)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.primary.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// The whole text is the task; the tokens on its first line pick the project
    /// and priority and are taken out of it.
    private func create() {
        let parsed = TaskTokens.parse(firstLine)
        let cleaned = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TaskText.plain(cleaned).isEmpty else { return }
        var projectID = projectID
        if let name = parsed.project ?? pendingProject {
            // A `#` token names the project; one that matches nothing is created.
            if let project = store.projects.first(where: { TaskTokens.compact($0.name) == TaskTokens.compact(name) }) {
                projectID = project.id
            } else if let project = store.addProject(named: name) {
                projectID = project.id
            }
        }
        let saved = TaskText.replacingTitle(of: text, with: cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        finish(PromptAnswer(title: TaskText.plain(cleaned), text: saved, projectID: projectID, priority: parsed.priority ?? priority))
    }
}

extension KeyboardShortcut {
    /// "⌘⇧H", for help text.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + String(key.character).uppercased()
    }
}

/// A plain-text Markdown editor (an `NSTextView`) that takes pasted and dropped
/// images and files, saving them through `insertImage` / `insertFile` and inserting
/// the returned Markdown.
/// A task in the compact island: title, project and status on top, the rendered
/// description below, Edit and Close.
private struct TaskDetailRow: View {
    let task: TaskItem
    let store: TaskStore
    let edit: () -> Void
    let delete: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PromptBadge(symbol: task.status.symbol, tint: task.status == .pending ? Color.white.opacity(0.2) : task.status.color)
                HStack(spacing: 6) {
                    if let project = store.project(task.projectID) {
                        Label { Text(store.path(to: project.id).map(\.name).joined(separator: " › ")) } icon: { Icon("folder", weight: .medium) }
                    }
                    Text("Added \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                Spacer(minLength: 0)
                PriorityMenu(priority: task.priority) { store.setPriority($0, for: task) }
                statusMenu
            }
            ScrollView {
                MarkdownView(markdown: task.text, imageURL: { store.imageURL(for: $0) }, attachmentURL: { store.attachmentURL(for: $0) })
                    .opacity(task.status == .complete ? 0.6 : 1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    KeyCap("esc")
                    Text("back").font(.system(size: 10)).foregroundStyle(.primary.opacity(0.45))
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: close) // the hint is a button too
                Spacer(minLength: 0)
                Button("Delete…", action: delete)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.white.opacity(0.08), in: Capsule())
                Button(action: edit) {
                    Label { Text("Edit") } icon: { Icon("pencil", weight: .medium) }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Color.brand, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .foregroundStyle(.primary)
    }

    private var statusMenu: some View {
        Menu {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button { store.setStatus(status, for: task) } label: { Label { Text(status.title) } icon: { Icon(status.symbol, weight: .medium) } }
            }
        } label: {
            HStack(spacing: 5) {
                Icon(task.status.symbol, size: 14, weight: .semibold).foregroundStyle(task.status.color)
                Text(task.status.title).font(.system(size: 12, weight: .semibold))
                Icon("chevron.down", size: 10, weight: .bold).foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.primary.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.primary.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The priority as a pill with a menu, the same shape as the status pill.
struct PriorityMenu: View {
    let priority: TaskPriority
    let pick: (TaskPriority) -> Void

    var body: some View {
        Menu {
            ForEach(TaskPriority.allCases, id: \.self) { value in
                Button { pick(value) } label: { Label { Text(value.title) } icon: { Icon(value.symbol, weight: .medium) } }
            }
        } label: {
            HStack(spacing: 5) {
                Icon(priority.symbol, size: 14, weight: .semibold).foregroundStyle(priority.color)
                Text(priority.title).font(.system(size: 12, weight: .semibold))
                Icon("chevron.down", size: 10, weight: .bold).foregroundStyle(.primary.opacity(0.5))
            }
            .foregroundStyle(.primary.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.primary.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Priority")
    }
}

// MARK: - Prompt pieces

struct PromptBadge: View {
    let symbol: String
    var tint: Color = .brand

    var body: some View {
        Icon(symbol, size: 18, weight: .semibold)
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint, in: Circle())
    }
}

struct PromptLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.6))
            .lineLimit(1)
    }
}

/// A bordered field container.
/// A field's box, in the forms' shared chrome.
struct PromptBox<Content: View>: View {
    var height: CGFloat = 32
    var focused = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) { content() }
            .padding(.trailing, 6)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .fieldChrome(focused: focused)
    }
}

/// The one look every field and card in the forms shares: a faint fill and no
/// edge at all; the focused field's fill is a little brighter. Radius 10 everywhere.
struct FieldChrome: ViewModifier {
    var focused = false
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(.primary.opacity(focused ? 0.085 : 0.05), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

extension View {
    func fieldChrome(focused: Bool = false, radius: CGFloat = 10) -> some View {
        modifier(FieldChrome(focused: focused, radius: radius))
    }
}

/// Makes the island the key window so the form's fields receive typing.
struct KeyWindowFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) {}

    final class KeyView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { window.makeKey() }
        }
    }
}


/// A key as Raycast draws one in its footer: a small rounded square, outlined.
struct RaycastKey: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 17, minHeight: 17)
            .padding(.horizontal, key.count > 1 ? 4 : 0)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.15)))
    }
}

/// A list row that lights up under the pointer, as Raycast's do.
struct RaycastRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    /// A button that floats over the text: an opaque face and a grey hairline, no shadow.
    func floatingButton(_ shape: some InsettableShape) -> some View {
        self
            .background(NotionStyle.card, in: shape)
            .overlay(shape.strokeBorder(.primary.opacity(0.12)))
            .contentShape(shape)
    }
}
