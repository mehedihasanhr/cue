import SwiftUI

// MARK: - Glyphs

/// Each agent's mark and colour: Claude's coral asterisk, Codex's terminal.
private extension AgentKind {
    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "terminal"
        }
    }

    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.55, green: 0.78, blue: 1.0)
        }
    }
}

private let askingTint = Color(red: 1.0, green: 0.71, blue: 0.3)

/// The smoke's palette: midnight navy through slate teal to a pale ice blue, low
/// in saturation so it stays quiet behind the cards. Warmth is left to the amber
/// accents of a question, which stand out against it; the smoke only brightens.
enum Smoke {
    static let calm = SmokeTexture.Palette(deep: [0.02, 0.035, 0.07], body: [0.11, 0.24, 0.32], glow: [0.5, 0.68, 0.8])
    static let asking = SmokeTexture.Palette(deep: [0.025, 0.04, 0.08], body: [0.14, 0.29, 0.38], glow: [0.6, 0.76, 0.88])
}

private struct AgentGlyph: View {
    let agent: AgentKind
    var size: CGFloat = 14
    /// Turning while the agent works, the way its own terminal spinner does.
    var spinning = false

    var body: some View {
        Image(systemName: agent.symbol)
            .font(.system(size: size * 0.82, weight: .bold))
            .frame(width: size, height: size)
            .foregroundStyle(agent.tint)
            .modifier(Spin(active: spinning && agent == .claude))
    }
}

/// The agent's own app icon (Claude's sunburst, Codex's knot), from the app
/// installed on this Mac; nil when it is not installed. Asked of macOS rather
/// than shipped with Cue, and looked up once.
@MainActor
private enum AgentAppIcon {
    private static var cache: [AgentKind: NSImage?] = [:]

    static func image(for agent: AgentKind) -> NSImage? {
        if let cached = cache[agent] { return cached }
        let ids = switch agent {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        }
        let icon = ids.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[agent] = icon
        return icon
    }
}

/// A session's tile: the agent's app icon, or its mark on a glass square when the
/// app is not installed. While the agent works, a slow ring of light circles it;
/// Claude at work is its little pixel critter instead, walking in place.
private struct AgentTile: View {
    let agent: AgentKind
    let working: Bool
    var side: CGFloat = 30

    var body: some View {
        if working, agent == .claude {
            ClaudeCritter(side: side)
        } else {
            tile
        }
    }

    private var tile: some View {
        Group {
            if let icon = AgentAppIcon.image(for: agent) {
                // App icons carry their own margin; scaled up a touch so the art fills the tile.
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(1.18)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            } else {
                AgentGlyph(agent: agent, size: side * 0.53, spinning: working)
                    .frame(width: side, height: side)
                    .background {
                        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                            .fill(.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                    }
            }
        }
        .overlay {
            if working { WorkingRing(radius: side * 0.22) }
        }
    }
}

/// Claude's pixel critter, as Claude Code shows it while it works: an orange block
/// with a shaded side, two eyes and slanted legs, typing on a little grey laptop.
/// Drawn square by square: the front arm taps in an uneven rhythm, the laptop's
/// screen flickers with each key, and now and then it blinks.
private struct ClaudeCritter: View {
    let side: CGFloat

    /// o body · d its shaded side · a the typing arm · k eyes · g laptop · c a lit key.
    private static let armUp: [String] = [
        "       ooooooodd  ",
        "       ooooooodd  ",
        "       koookoodd  ",
        "     aaooooooodd  ",
        "     aaooooooodd  ",
        "g      ooooooodd  ",
        " g     ooooooodd  ",
        "  g     o o o o   ",
        "   gggg  o o o o  ",
    ]
    private static let armDown: [String] = [
        "       ooooooodd  ",
        "       ooooooodd  ",
        "       koookoodd  ",
        "       ooooooodd  ",
        "     aaooooooodd  ",
        "gc   aaooooooodd  ",
        " g     ooooooodd  ",
        "  g     o o o o   ",
        "   gggg  o o o o  ",
    ]
    /// Down (true) or up for each beat: typing, not a metronome.
    private static let rhythm: [Bool] = [true, false, true, false, false, true, true, false, true, false, false, false]
    private static let beat = 0.13
    private static let columns = 18, rows = 9
    private static let orange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let shade = Color(red: 0.72, green: 0.38, blue: 0.28)
    private static let arm = Color(red: 0.8, green: 0.43, blue: 0.31)
    private static let laptop = Color(white: 0.6)
    private static let key = Color(red: 0.6, green: 0.85, blue: 1.0)

    var body: some View {
        // Wider than the tile: the laptop sits out to its left, in the row's margin.
        let width = side * 1.4
        TimelineView(.animation(minimumInterval: Self.beat, paused: IslandView.reduceMotion)) { context in
            let tick = IslandView.reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / Self.beat)
            let down = Self.rhythm[tick % Self.rhythm.count]
            let blinking = tick % 31 == 0
            Canvas { canvas, size in
                let pixel = min(size.width / CGFloat(Self.columns), size.height / CGFloat(Self.rows))
                let origin = CGPoint(x: size.width - pixel * CGFloat(Self.columns), y: (size.height - pixel * CGFloat(Self.rows)) / 2)
                for (row, line) in (down ? Self.armDown : Self.armUp).enumerated() {
                    for (column, mark) in line.enumerated() where mark != " " {
                        let color: Color = switch mark {
                        case "d": Self.shade
                        case "a": Self.arm
                        case "k": blinking ? Self.orange : .black
                        case "g": Self.laptop
                        case "c": Self.key
                        default: Self.orange
                        }
                        // A hair over a pixel so neighbours meet without seams.
                        let rect = CGRect(x: origin.x + CGFloat(column) * pixel, y: origin.y + CGFloat(row) * pixel,
                                          width: pixel + 0.3, height: pixel + 0.3)
                        canvas.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
        .frame(width: width, height: side)
        .padding(.leading, side - width)
        .accessibilityLabel("Claude is working")
    }
}

/// A short arc of light travelling round the tile's edge: working, quietly.
private struct WorkingRing: View {
    let radius: CGFloat

    var body: some View {
        // Driven frame by frame: a gradient's angle does not animate by itself.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: IslandView.reduceMotion)) { context in
            let angle = (context.date.timeIntervalSinceReferenceDate * 160).truncatingRemainder(dividingBy: 360)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .inset(by: -2)
                .stroke(AngularGradient(colors: [.clear, .clear, .white.opacity(0.55), .clear], center: .center, angle: .degrees(angle)),
                        lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct Spin: ViewModifier {
    let active: Bool
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onAppear { start() }
            .onChange(of: active) { start() }
    }

    private func start() {
        guard active, !IslandView.reduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) { angle = 0 }
            return
        }
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { angle = 360 }
    }
}

/// The closed notch while agents run: one thin line of light that runs along the
/// top edge of the screen, down around the notch and out the other side, fading
/// away into the edge on both sides so it never reads as a border. Soft blue-green
/// while agents work, with a highlight drifting left to right now and then; amber,
/// gently pulsing, while one waits on the user. Nothing when idle (the island does
/// not draw it then). The notch itself stays black: the light shows only outside it.
struct NotchGlow: View {
    let shape: NotchShape
    let size: CGSize
    let asking: Bool

    static let working = Color(red: 0.38, green: 0.78, blue: 0.95)
    /// How far the light reaches along the top edge on each side of the notch.
    static let wing: CGFloat = 140
    /// A sweep crosses in this long, then the line rests until the next.
    private static let sweep = 2.4
    private static let sweepRest = 1.6

    /// Room under the notch for the half of the line, and its glow, that hang below
    /// its bottom edge; without it the frame (and the fade's mask) would cut them off.
    private static let below: CGFloat = 12

    var body: some View {
        let path = NotchLightPath(flare: shape.flare, bottomRadius: shape.bottomRadius, wing: Self.wing,
                                  notchHeight: size.height, part: .whole)
        let bottom = NotchLightPath(flare: shape.flare, bottomRadius: shape.bottomRadius, wing: Self.wing,
                                    notchHeight: size.height, part: .bottom)
        let color = asking ? askingTint : Self.working
        let width = size.width + Self.wing * 2
        Group {
            if IslandView.reduceMotion {
                line(path, bottom, color: color, level: 0.7)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    if asking {
                        // A slow pulse, never fully dark.
                        let pulse = 0.5 - 0.5 * cos(t * 2 * .pi / 1.6)
                        line(path, bottom, color: color, level: 0.4 + 0.6 * pulse)
                    } else {
                        let phase = t.truncatingRemainder(dividingBy: Self.sweep + Self.sweepRest) / Self.sweep
                        let progress = min(1, phase)
                        let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
                        ZStack {
                            line(path, bottom, color: color, level: 0.5)
                            line(path, bottom, color: color, level: 1)
                                .mask(highlight(at: -0.15 + 1.3 * eased))
                                .opacity(progress < 1 ? 1 : 0)
                        }
                    }
                }
            }
        }
        // Strongest at the notch, gone by the ends of the wings: it melts into the edge.
        .mask(fade(width: width))
        // The inner half of every stroke sits under the black, so the light reads
        // as coming from behind the notch's edge.
        .overlay(alignment: .top) { shape.fill(.black).frame(width: size.width, height: size.height) }
        .frame(width: width, height: size.height + Self.below, alignment: .top)
        // Hung from the notch's top: the extra room is all below it.
        .padding(.bottom, -Self.below)
        .allowsHitTesting(false)
    }

    /// About 2 pt of line outside the edge with a faint glow, a touch brighter
    /// along the bottom, where the eye looks, than up the sides.
    private func line(_ path: NotchLightPath, _ bottom: NotchLightPath, color: Color, level: Double) -> some View {
        ZStack {
            path.stroke(color, style: SwiftUI.StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                .blur(radius: 6)
                .opacity(0.2 * level)
            path.stroke(color, style: SwiftUI.StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .opacity(0.6 * level)
            bottom.stroke(color, style: SwiftUI.StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                .blur(radius: 6)
                .opacity(0.3 * level)
            bottom.stroke(color, style: SwiftUI.StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                .opacity(0.35 * level)
        }
    }

    /// A soft band of light centred at `position` (0 left end, 1 right end).
    private func highlight(at position: Double) -> some View {
        LinearGradient(stops: [
            .init(color: .clear, location: position - 0.14),
            .init(color: .black, location: position),
            .init(color: .clear, location: position + 0.14),
        ], startPoint: .leading, endPoint: .trailing)
    }

    private func fade(width: CGFloat) -> some View {
        let wing = Double(Self.wing / width)
        return LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.35), location: wing * 0.45),
            .init(color: .black, location: wing),
            .init(color: .black, location: 1 - wing),
            .init(color: .black.opacity(0.35), location: 1 - wing * 0.45),
            .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
}

/// The line the light follows: along the top edge from the left, down the notch's
/// side, along its bottom, up the other side and out along the top edge again.
/// `rect` is the notch's rect (flares included) widened by `wing` on each side.
private nonisolated struct NotchLightPath: Shape {
    enum Part { case whole, bottom }

    let flare: CGFloat
    let bottomRadius: CGFloat
    let wing: CGFloat
    /// The notch's own height; `rect` is taller, with room for the light below it.
    let notchHeight: CGFloat
    var part: Part = .whole

    func path(in rect: CGRect) -> Path {
        let notch = CGRect(x: rect.minX + wing, y: rect.minY, width: rect.width - wing * 2, height: notchHeight)
        let flare = min(self.flare, notch.width / 4)
        let body = notch.insetBy(dx: flare, dy: 0)
        let bottom = min(bottomRadius, body.width / 2, body.height / 2)
        let top = rect.minY
        var path = Path()
        if part == .bottom {
            // The bottom edge with its two curves only.
            path.move(to: CGPoint(x: body.minX, y: body.maxY - bottom))
            path.addQuadCurve(to: CGPoint(x: body.minX + bottom, y: body.maxY), control: CGPoint(x: body.minX, y: body.maxY))
            path.addLine(to: CGPoint(x: body.maxX - bottom, y: body.maxY))
            path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.maxY - bottom), control: CGPoint(x: body.maxX, y: body.maxY))
            return path
        }
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: notch.minX, y: top))
        path.addQuadCurve(to: CGPoint(x: body.minX, y: top + flare), control: CGPoint(x: body.minX, y: top))
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: body.minX + bottom, y: body.maxY), control: CGPoint(x: body.minX, y: body.maxY))
        path.addLine(to: CGPoint(x: body.maxX - bottom, y: body.maxY))
        path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.maxY - bottom), control: CGPoint(x: body.maxX, y: body.maxY))
        path.addLine(to: CGPoint(x: body.maxX, y: top + flare))
        path.addQuadCurve(to: CGPoint(x: notch.maxX, y: top), control: CGPoint(x: body.maxX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        return path
    }
}

/// A finished turn, for the island to announce.
struct AgentDone: Equatable {
    let agent: AgentKind
    let project: String
    let took: Duration
    /// The agent's last words, on one line.
    var summary: String? = nil

    static func timeText(seconds: Int) -> String {
        if seconds < 60 { return "\(max(seconds, 1))s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }
}

private let doneGreen = Color(red: 0.36, green: 0.86, blue: 0.56)

/// A finished turn on the island. It plays as one short moment: a check lands on
/// the agent icon's corner, the words come into
/// focus one after the other, and the turn's time counts up to its total.
struct AgentDoneRow: View {
    let done: AgentDone
    @State private var badge = false
    @State private var words = false
    @State private var shownSeconds = 0

    private var subtitle: String {
        if let summary = done.summary, !summary.isEmpty { return "\(done.project) · \(summary)" }
        return "\(done.project) · \(done.agent.shortName)"
    }

    var body: some View {
        HStack(spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                Text("Task complete")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .modifier(FocusIn(shown: words, delay: 0.1))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .truncationMode(.tail)
                    .modifier(FocusIn(shown: words, delay: 0.17))
            }
            .lineLimit(1)
            .frame(maxWidth: 230, alignment: .leading)
            Spacer(minLength: 14)
            timePill
        }
        .padding(.horizontal, 16)
        .onAppear(perform: play)
    }

    private var tile: some View {
        AgentTile(agent: done.agent, working: false, side: 28)
            .padding(3)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark")
                    .font(.system(size: 7.5, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 15, height: 15)
                    .background(doneGreen, in: Circle())
                    .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                    .offset(x: 4, y: 4)
                    .scaleEffect(badge ? 1 : 0.4)
                    .opacity(badge ? 1 : 0)
            }
    }

    private var timePill: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .semibold))
            Text(AgentDone.timeText(seconds: shownSeconds))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText(countsDown: false))
        }
        .foregroundStyle(doneGreen)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(doneGreen.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(doneGreen.opacity(0.25), lineWidth: 0.5))
        .modifier(FocusIn(shown: words, delay: 0.24))
    }

    private func play() {
        let total = max(1, Int(done.took.components.seconds))
        guard !IslandView.reduceMotion else {
            shownSeconds = total
            withAnimation(.easeOut(duration: 0.2)) { badge = true; words = true }
            return
        }
        withAnimation(.spring(duration: 0.4, bounce: 0.3).delay(0.15)) { badge = true }
        words = true
        // Counts up in a handful of steps, quick at first and settling on the total.
        Task { @MainActor in
            let steps = 9
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(55))
                let progress = 1 - pow(1 - Double(step) / Double(steps), 3)
                withAnimation(.snappy(duration: 0.18)) { shownSeconds = max(1, Int(Double(total) * progress)) }
            }
        }
    }
}

/// Comes into focus: from a little blurred, faded and low to sharp and in place.
private struct FocusIn: ViewModifier {
    let shown: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: shown ? 0 : 6)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 5)
            .animation(IslandView.reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.4).delay(delay), value: shown)
    }
}

/// A dot that breathes: something is waiting for the user.
private struct PulseDot: View {
    var size: CGFloat = 8
    @State private var on = false

    var body: some View {
        Circle()
            .fill(askingTint)
            .frame(width: size, height: size)
            .scaleEffect(on ? 1 : 0.7)
            .opacity(on ? 1 : 0.6)
            .onAppear {
                guard !IslandView.reduceMotion else { on = true; return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true }
            }
    }
}

// MARK: - Closed island

/// The closed pill on a display without a notch, while agents run: the busiest
/// agent's mark on the left, and on the right how many sessions there are — or a
/// pulsing dot when one is asking something. (Under a notch nothing would show; the
/// glow beneath it says agents are at work.)
struct AgentAmbientRow: View {
    let store: AgentStore
    let notchWidth: CGFloat

    var body: some View {
        let sessions = store.sessions
        let lead = sessions.first
        HStack(spacing: 0) {
            Group {
                if let lead {
                    AgentTile(agent: lead.agent, working: lead.state == .running, side: 16)
                        .opacity(lead.state == .idle ? 0.55 : 1)
                }
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            Group {
                if !store.requests.isEmpty {
                    PulseDot()
                } else if sessions.count > 1 {
                    Text("\(sessions.count)")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                } else if lead?.state == .idle {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.green.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.requests.isEmpty ? "\(sessions.count) agent sessions" : "An agent is asking something")
    }
}

// MARK: - Smoke and glass

/// Smoke rising and curling behind the list: three copies of a seamless smoke
/// texture (`SmokeTexture`), at different sizes, drifting up at different speeds
/// and slightly sideways. Sliding over one another, the wisps keep changing shape
/// the way real smoke does. Held still with Reduce Motion.
struct SmokeField: View {
    let palette: SmokeTexture.Palette
    var intensity: Double = 1
    /// How far down it stays clear (where the island meets the notch) before it
    /// fades in over 40 points.
    var fadeTop: CGFloat = 56
    @State private var start = Date()
    @State private var loaded = 0

    /// Size of one tile on screen, how fast it rises and drifts (points a second),
    /// and how much of it shows.
    private static let layers: [(scale: CGFloat, rise: CGFloat, drift: CGFloat, opacity: Double)] = [
        (3.2, 4, 1.2, 0.85),
        (2.2, 7, -2, 0.6),
        (4.5, 2.5, 0.8, 0.5),
    ]

    var body: some View {
        let _ = loaded
        if let tile = SmokeTexture.image(for: palette, ready: { loaded += 1 }) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: IslandView.reduceMotion)) { context in
                let time = IslandView.reduceMotion ? 20 : context.date.timeIntervalSince(start) + 20
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ForEach(Self.layers.indices, id: \.self) { index in
                            layer(tile, Self.layers[index], time: time, in: proxy.size)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .clipped()
                }
            }
            .blur(radius: 10)
            .opacity(min(intensity, 1))
            // Out of black at the top, where the island meets the notch.
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: fadeTop)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 40)
                    Color.black
                }
            }
            .transition(.opacity.animation(.easeOut(duration: 0.6)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// One layer: the tile repeated over the view plus one tile's margin, shifted by
    /// the time modulo a tile, so it moves without ever running out.
    private func layer(_ tile: NSImage, _ spec: (scale: CGFloat, rise: CGFloat, drift: CGFloat, opacity: Double),
                       time: TimeInterval, in size: CGSize) -> some View {
        let side = CGFloat(SmokeTexture.size) * spec.scale
        let x = CGFloat(time) * spec.drift
        let y = CGFloat(time) * spec.rise
        let offsetX = x.truncatingRemainder(dividingBy: side) - (x >= 0 ? side : 0)
        let offsetY = -y.truncatingRemainder(dividingBy: side)
        return Image(nsImage: tile)
            .resizable(resizingMode: .tile)
            .scaleEffect(spec.scale, anchor: .topLeading)
            .frame(width: (size.width + side * 2) / spec.scale, height: (size.height + side * 2) / spec.scale, alignment: .topLeading)
            .offset(x: offsetX, y: offsetY)
            .opacity(spec.opacity)
            .blendMode(.screen)
    }
}

/// The header's status light: green while all is well, orange when asked.
private struct LiveDot: View {
    let color: Color
    @State private var glow = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color, radius: glow ? 5 : 2)
            .onAppear {
                guard !IslandView.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever()) { glow = true }
            }
    }
}

// MARK: - Sessions list

/// The open island's list of sessions, with what each is asking under it.
struct AgentsView: View {
    let store: AgentStore
    let openPanel: () -> Void
    let close: () -> Void
    let reportHeight: (CGFloat) -> Void
    /// The most the whole view may take: the island's window is only as tall as
    /// the open panel, and anything below it would be cut off, out of scroll's reach.
    let maxHeight: CGFloat

    @State private var listHeight: CGFloat = 0
    /// How far the list is scrolled down.
    @State private var scrollOffset: CGFloat = 0
    /// The list has been laid out once. Until then its height is unknown and
    /// nothing is reported, so the island opens straight to its full size, in one
    /// movement, the way the panel does — not to the header first and then again.
    @State private var measured = false
    /// The header, the gap under it and the padding around it all.
    private static let chrome: CGFloat = 24 + 12 + 14

    private static let scrollSpace = "agentsList"

    /// Corners nest: a card's radius is the island's less the list's inset from its
    /// edge (34 − 14), and a box inside a card is the card's less its padding (20 − 12).
    static let cardRadius: CGFloat = 20
    static let innerRadius: CGFloat = 8

    /// The user asked to see every session while a question waits.
    @State private var showAll = false
    /// A question is waiting: the island shows it alone, not the whole list.
    private var questionOnly: Bool { !store.requests.isEmpty && !showAll }
    /// The sessions listed: only those asking while a question waits, else all.
    private var shownSessions: [AgentSession] {
        questionOnly ? store.sessions.filter { !store.requests(for: $0).isEmpty } : store.sessions
    }

    private var listLimit: CGFloat { max(120, maxHeight - Self.chrome) }
    private var overflows: Bool { listHeight > listLimit + 1 }
    /// More below the fold: the list is taller than its window and not scrolled to the end.
    private var moreBelow: Bool { overflows && scrollOffset + listLimit < listHeight - 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if questionOnly { questionHeader } else { header }
            if store.sessions.isEmpty {
                Text("No agent sessions running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        let sessions = shownSessions
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            VStack(spacing: 0) {
                                // Plain rows, parted by a hairline; a card is set apart by its own fill.
                                if index > 0, !AgentSessionCard.showsCard(sessions[index - 1], requests: store.requests(for: sessions[index - 1])),
                                   !AgentSessionCard.showsCard(session, requests: store.requests(for: session)) {
                                    Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 50)
                                }
                                AgentSessionCard(session: session, requests: store.requests(for: session), store: store)
                                    .padding(.vertical, AgentSessionCard.showsCard(session, requests: store.requests(for: session)) ? 4 : 0)
                            }
                                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                                                        removal: .opacity.combined(with: .scale(scale: 0.97))))
                        }
                    }
                    // The list's frame follows its content on the same spring as the rows,
                    // rather than snapping to the new height a frame later.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if measured {
                            withAnimation(IslandView.listAnimation) { listHeight = height }
                        } else {
                            listHeight = height
                            measured = true
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .named(Self.scrollSpace)).minY } action: { offset in
                        scrollOffset = offset
                    }
                }
                .coordinateSpace(name: Self.scrollSpace)
                .scrollIndicators(.never)
                // Until it has measured itself the list takes the room it is given, so
                // the cards are there from the first frame and open with the island,
                // rather than the island opening empty and the cards following.
                .frame(height: measured ? min(listHeight, listLimit) : nil)
                // More below: the bottom edge fades out. Scrolled to the end, it doesn't,
                // so the last row reads in full.
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(moreBelow ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 56)
                    }
                    .animation(.easeOut(duration: 0.2), value: moreBelow)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            guard measured || store.sessions.isEmpty else { return }
            reportHeight(height.rounded(.up))
        }
        .animation(IslandView.listAnimation, value: store.requests.map(\.id))
        .animation(IslandView.listAnimation, value: store.sessions.map(\.id))
        .animation(IslandView.listAnimation, value: showAll)
        // Every question answered: the next one shows alone again.
        .onChange(of: store.requests.isEmpty) { _, none in if none { showAll = false } }
    }

    /// While a question waits: who is asking, and the way back to every session.
    private var questionHeader: some View {
        let asking = shownSessions
        let others = store.sessions.count - asking.count
        return HStack(spacing: 8) {
            PulseDot()
            Text(asking.count == 1 ? "\(asking[0].project) needs you" : "\(asking.count) sessions need you")
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Spacer()
            if others > 0 {
                Button { showAll = true } label: {
                    Text("All sessions · \(store.sessions.count)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Show every session")
            }
            HeaderButton(symbol: "xmark", help: "Close", action: close)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .tracking(-0.1)
        .frame(height: 24)
        .padding(.leading, 6)
    }



    /// A count of sessions and how they stand: "2 sessions | 1 working  1 needs you".
    private var header: some View {
        let sessions = store.sessions
        let working = sessions.filter { $0.state == .running }.count
        let asking = sessions.filter { $0.state == .waiting }.count
        return HStack(spacing: 16) {
            // Plain counts set apart by space alone; only what needs the user is in colour.
            Text("\(sessions.count) \(sessions.count == 1 ? "session" : "sessions")")
                .foregroundStyle(.white.opacity(0.92))
            if working > 0 {
                Text("\(working) working").foregroundStyle(.white.opacity(0.5))
            }
            if asking > 0 {
                Text("\(asking) \(asking == 1 ? "needs" : "need") you").foregroundStyle(askingTint)
            }
            Spacer()
            HeaderButton(symbol: "square.grid.2x2", help: "Open the panel", action: openPanel)
            HeaderButton(symbol: "xmark", help: "Close", action: close)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .tracking(-0.1)
        .monospacedDigit()
        .frame(height: 24)
        .padding(.leading, 6)
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Icon(symbol, size: 13, weight: .semibold)
                .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.6))
                .frame(width: 24, height: 24)
                .background(.white.opacity(hovered ? 0.12 : 0), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

// MARK: - One session

/// How a session stands, in colour.
private enum SessionTone {
    static let working = Color(red: 0.47, green: 0.67, blue: 1.0)
    static let done = Color(red: 0.36, green: 0.82, blue: 0.48)

    static func color(_ state: AgentSession.State) -> Color {
        switch state {
        case .running: working
        case .waiting: askingTint
        case .idle: done
        }
    }
}

/// One session on a soft card: its icon, name, what it is doing and how it stands.
private struct AgentSessionCard: View {
    let session: AgentSession
    let requests: [AgentRequest]
    let store: AgentStore
    @State private var hovered = false

    /// At work it stays on one line; finished, or waiting on the user, it shows in full.
    private var expanded: Bool { Self.showsCard(session, requests: requests) }

    /// Finished, or waiting on the user: shown in full on a card; at work: a plain row.
    static func showsCard(_ session: AgentSession, requests: [AgentRequest]) -> Bool {
        session.state != .running || !requests.isEmpty
    }

    var body: some View {
        Group {
            if expanded { full } else { line }
        }
        .contextMenu { Button("Dismiss", action: dismiss) }
        .onHover { hovered = $0 }
        .animation(IslandView.contentAnimation, value: hovered)
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 4) {
            summary
                .onTapGesture { store.focus(session) }
                .accessibilityAddTraits(.isButton)
                .help(jumpHelp)
            if !session.workers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.workers) { worker in
                        AgentWorkerRow(worker: worker)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.leading, 38)
                .animation(IslandView.listAnimation, value: session.workers.map(\.id))
            }
            ForEach(requests) { request in
                // In line with the text, not the logo.
                AgentRequestCard(request: request, store: store)
                    .padding(.leading, 38)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        // Always the list's full width: a finished card with little to say must not
        // shrink to its text.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        // Clear until the pointer is on it, like the plain rows: the island's own fill
        // shows through, and the card only lifts when it's the one being looked at.
        .background(.white.opacity(hovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: AgentsView.cardRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            dismissButton
                .padding(8)
                .opacity(hovered && requests.isEmpty ? 1 : 0)
                .allowsHitTesting(hovered && requests.isEmpty)
        }
    }

    /// Logo, name and what it is about, and how it stands: the logo already says
    /// which agent; where it runs and for how long are in the tooltip.
    private var line: some View {
        HStack(spacing: 12) {
            AgentTile(agent: session.agent, working: session.state == .running, side: 26)
            name(size: 13.5, weight: .semibold, color: .white.opacity(hovered ? 1 : 0.92))
            Spacer(minLength: 12)
            // On hover the status makes way for the dismiss button, in the same place.
            ZStack(alignment: .trailing) {
                StatusLabel(text: session.usedTool ? "Working" : "Thinking", tone: SessionTone.working)
                    .opacity(hovered ? 0 : 1)
                dismissButton
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: AgentsView.cardRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.focus(session) }
        .accessibilityAddTraits(.isButton)
        .help(session.activity.map { "\($0)\n\(jumpHelp)" } ?? jumpHelp)
    }

    private var jumpHelp: String {
        "Show in \(store.hosts[session.id]?.name ?? session.terminal.map(Self.terminalName) ?? "its terminal")"
    }

    private func dismiss() {
        withAnimation(IslandView.listAnimation) { store.dismiss(session) }
    }

    /// Closes a session that ended without saying so.
    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 20, height: 20)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }

    /// The folder, and under it what the session is about, so two in one folder read apart.
    private func name(size: CGFloat, weight: Font.Weight, color: Color, attention: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(session.project)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
                // What it needs from the user, beside its name: "api  ● Permission required".
                if let attention {
                    HStack(spacing: 5) {
                        RippleDot(color: askingTint)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        Text(attention)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(askingTint)
                    }
                }
            }
            if let title = session.title {
                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.76))
                    .truncationMode(.tail)
            }
        }
    }

    /// The terminal or app the session runs in, as a click on the row brings forward.
    private var source: String? {
        store.hosts[session.id]?.name ?? session.terminal.map(Self.terminalName)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentTile(agent: session.agent, working: session.state == .running, side: 26)
            VStack(alignment: .leading, spacing: 1) {
                name(size: 14, weight: .semibold, color: .white, attention: requests.first?.attention)
                // While it asks, the question says it all; the command is shown below.
                if let ask = requests.first?.ask {
                    Text(ask)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                } else if !requests.isEmpty {
                    // A question: "Answer required" beside the name says it; the question below is the focus.
                    EmptyView()
                } else {
                    Text(session.activity ?? Self.placeholder(for: session.state))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.76))
                        .truncationMode(.tail)
                    stateLabel
                }
            }
            .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    /// "● Working 12s", "Needs you", "● Done — click to jump": a coloured dot and a
    /// quiet label, bright colour kept for what needs the user.
    @ViewBuilder
    private var stateLabel: some View {
        switch session.state {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                StatusLabel(text: "\(session.usedTool ? "Working" : "Thinking") \(Self.elapsed(since: session.turnStartedAt ?? session.startedAt, now: context.date))",
                            tone: SessionTone.working)
            }
        case .waiting:
            Text("Needs you")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(askingTint)
        case .idle:
            StatusLabel(text: "Done — click to jump", tone: SessionTone.done)
        }
    }

    private static func placeholder(for state: AgentSession.State) -> String {
        switch state {
        case .running: "Thinking…"
        case .waiting: "Waiting for you"
        case .idle: "Waiting for a prompt"
        }
    }

    /// "8s", "4m", "1h 5m".
    private static func elapsed(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }

    private static func terminalName(_ program: String) -> String {
        switch program {
        case "Apple_Terminal": "Terminal"
        case "iTerm.app": "iTerm"
        case "vscode": "VS Code"
        case "WarpTerminal": "Warp"
        default: program
        }
    }
}

/// A still dot with a soft ring that widens and fades from it, then rests a moment:
/// asks for attention without pulsing at the user.
private struct RippleDot: View {
    let color: Color
    var size: CGFloat = 5

    private static let ripple = 1.8
    private static let rest = 0.9

    var body: some View {
        Circle().fill(color)
            .frame(width: size, height: size)
            .background {
                if !IslandView.reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let elapsed = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: Self.ripple + Self.rest)
                        let progress = min(1, elapsed / Self.ripple)
                        let eased = 1 - pow(1 - progress, 3) // ease-out
                        Circle()
                            .fill(color)
                            .frame(width: size, height: size)
                            .scaleEffect(1 + 2.2 * eased)
                            .opacity(0.35 * (1 - eased))
                    }
                }
            }
    }
}

/// A small coloured dot and a muted label: how a session stands, without shouting.
private struct StatusLabel: View {
    let text: String
    let tone: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone).frame(width: 4, height: 4)
            Text(text)
                .font(.system(size: 11, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
        }
        .fixedSize()
    }
}

/// One subagent or background command under its session: what it was asked to
/// do, what it is doing now, and a spinner while it runs.
private struct AgentWorkerRow: View {
    let worker: AgentWorker

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color(red: 0.48, green: 0.78, blue: 1.0), style: SwiftUI.StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 10, height: 10)
                .modifier(Spin(active: true))
            Image(systemName: worker.kind == .shell ? "terminal" : "person.2")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 14)
            Text(worker.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .layoutPriority(1)
            if let line = worker.activity ?? worker.detail {
                Text(line)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 4)
            if worker.background {
                Text("BG")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.vertical, 3)
    }
}

/// A session's state in its own colour, breathing while something is happening:
/// ice blue and slow while working, amber and quicker while it needs the user,
/// a steady green once it is ready for the next prompt.
private struct StatusText: View {
    let state: AgentSession.State
    @State private var inhale = false

    private static let working = Color(red: 0.48, green: 0.78, blue: 1.0)
    private static let ready = Color(red: 0.36, green: 0.86, blue: 0.56)

    private var text: String {
        switch state {
        case .waiting: "Needs you"
        case .running: "Working"
        case .idle: "Ready"
        }
    }

    private var color: Color {
        switch state {
        case .waiting: askingTint
        case .running: Self.working
        case .idle: Self.ready
        }
    }

    /// Seconds per breath; nil holds still.
    private var breath: Double? {
        switch state {
        case .waiting: 0.9
        case .running: 1.6
        case .idle: nil
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .shadow(color: color.opacity(inhale ? 0.9 : 0.3), radius: inhale ? 4 : 1.5)
            Text(text)
                .foregroundStyle(color)
                .shadow(color: color.opacity(inhale ? 0.45 : 0), radius: 4)
        }
        .opacity(breath == nil ? 1 : (inhale ? 1 : 0.55))
        .onAppear { breathe() }
        .onChange(of: state) { breathe() }
    }

    private func breathe() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { inhale = false }
        guard let breath, !IslandView.reduceMotion else {
            inhale = breath == nil
            return
        }
        withAnimation(.easeInOut(duration: breath).repeatForever(autoreverses: true)) { inhale = true }
    }
}

// MARK: - One question

private struct AgentRequestCard: View {
    let request: AgentRequest
    let store: AgentStore

    var body: some View {
        switch request.kind {
        case .permission(let summary):
            PermissionCard(request: request, summary: summary, store: store)
        case .plan(let plan):
            PlanCard(request: request, plan: plan, store: store)
        case .questions(let questions):
            QuestionsCard(request: request, questions: questions, store: store)
        }
    }
}

private struct PermissionCard: View {
    let request: AgentRequest
    let summary: AgentToolSummary
    let store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let detail = summary.detail, !detail.isEmpty {
                // Whole lines only (three at most); the full command is in the tooltip.
                Text(detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(1.5)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: AgentsView.innerRadius, style: .continuous))
                    .help(detail)
            }
            // All the answers together on the right, the default one last; a session in
            // the agent's own app can be sent back there to answer.
            HStack(spacing: 6) {
                if let app = request.appName {
                    AnswerButton("Ask in \(app)", role: .quiet) { store.answerInTerminal(request) }
                        .help("Answer in \(app) instead; it asks there")
                }
                Spacer(minLength: 0)
                AnswerButton("Deny", role: .quiet) { store.answer(request, .deny) }
                if request.canAllowAlways {
                    AnswerButton(request.agent == .codex ? "Allow for session" : "Always allow", role: .secondary) { store.answer(request, .allowAlways) }
                        .help(request.agent == .codex ? "Allow this command again without asking until the session ends" : "Allow this and don’t ask again, the way Claude Code’s own prompt offers")
                }
                AnswerButton("Allow once", role: .primary) { store.answer(request, .allowOnce) }
            }
        }
    }

}

extension AgentRequest {
    /// The kind of attention it needs, in a word or two.
    var attention: String {
        switch kind {
        case .permission: "Permission required"
        case .plan: "Approval required"
        case .questions: "Answer required"
        }
    }

    /// What it asks, in a few words, shown in place of the session's status line;
    /// nil when the card below carries its own questions.
    var ask: String? {
        switch kind {
        case .permission(let summary):
            switch summary.tool {
            case "Bash": "Run this command?"
            case "Edit", "MultiEdit", "Write", "NotebookEdit", "Edit files": "Make this edit?"
            case "WebFetch": "Fetch this page?"
            default: "Use \(summary.tool)?"
            }
        case .plan: "Ready to start on this plan?"
        case .questions: nil
        }
    }
}

private struct PlanCard: View {
    let request: AgentRequest
    let plan: String
    let store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !plan.isEmpty {
                ScrollView(.vertical) {
                    Text((try? AttributedString(markdown: plan, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(plan))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: AgentsView.innerRadius, style: .continuous))
            }
            HStack(spacing: 6) {
                AnswerButton("Keep planning", role: .quiet) { store.answer(request, .deny) }
                Spacer(minLength: 0)
                if request.canApprovePlan {
                    // Claude Code takes a plan's approval only from its own dialog, so
                    // these press that dialog's keys in the agent's pane.
                    AnswerButton("Approve, review edits", role: .secondary) { store.answer(request, .approvePlan(reviewEdits: true)) }
                        .help("Approve, and ask before each edit")
                    AnswerButton("Approve", role: .primary) { store.answer(request, .approvePlan(reviewEdits: false)) }
                        .help("Approve, as Return does in the terminal")
                } else {
                    // No pane to type in (a terminal other than WezTerm or tmux): the
                    // approval has to be given in the terminal itself.
                    AnswerButton("Approve in Terminal", role: .primary) { store.answerInTerminal(request) }
                }
            }
        }
    }
}

/// AskUserQuestion: each question with its options. A single question with a single
/// answer goes as soon as an option is clicked; otherwise Submit sends them all.
/// AskUserQuestion, one question at a time the way the CLI asks: the question in
/// full and its options as radio (or check) rows. A single choice moves on to the
/// next question by itself; Back returns to change one. Nothing is sent until the
/// last question is answered and Continue pressed; the terminal can still answer.
private struct QuestionsCard: View {
    let request: AgentRequest
    let questions: [AgentRequest.Question]
    let store: AgentStore

    @State private var chosen: [String: [String]] = [:]
    @State private var other: [String: String] = [:]
    @State private var typing: String?
    /// The question on screen.
    @State private var step = 0

    private var current: AgentRequest.Question { questions[min(step, questions.count - 1)] }
    private var isLast: Bool { step >= questions.count - 1 }
    private func answered(_ question: AgentRequest.Question) -> Bool { !(chosen[question.question] ?? []).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let question = current
                VStack(alignment: .leading, spacing: 5) {
                    if questions.count > 1 { progress }
                    prompt(question)
                    VStack(spacing: 0) {
                        ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                            if index > 0 { separator }
                            OptionRow(label: option.label, description: option.description, multi: question.multiSelect,
                                      selected: chosen[question.question, default: []].contains(option.label)) {
                                pick(option.label, in: question)
                            }
                        }
                        separator
                        otherRow(for: question)
                    }
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .id(step)
                .transition(.opacity)
            HStack(spacing: 6) {
                if step > 0 {
                    AnswerButton("Back", role: .quiet) { go(to: step - 1) }
                }
                Spacer(minLength: 0)
                AnswerButton("Answer in Terminal", role: .quiet) { store.answerInTerminal(request) }
                    .help("Leave this to the terminal; the agent waits there")
                if isLast {
                    AnswerButton("Continue", role: .primary) { submit() }
                        .disabled(!complete)
                        .opacity(complete ? 1 : 0.4)
                } else {
                    AnswerButton("Next", role: .primary) { go(to: step + 1) }
                        .disabled(!answered(question))
                        .opacity(answered(question) ? 1 : 0.4)
                }
            }
        }
    }

    /// "2 of 3" and a dot per question: filled once answered, brighter for this one.
    private var progress: some View {
        HStack(spacing: 6) {
            Text("\(step + 1) of \(questions.count)")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 4) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    Circle()
                        .fill(.white.opacity(index == step ? 0.9 : answered(question) ? 0.45 : 0.15))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }

    private func go(to index: Int) {
        typing = nil
        withAnimation(.easeOut(duration: 0.15)) { step = min(max(index, 0), questions.count - 1) }
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 30)
    }

    /// The question, in full, with its short topic, when there is one, quietly above it.
    @ViewBuilder
    private func prompt(_ question: AgentRequest.Question) -> some View {
        if let header = question.header, !header.isEmpty {
            Text(header)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        // In full: a decision needs the whole question.
        Text(question.question)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func otherRow(for question: AgentRequest.Question) -> some View {
        if typing == question.question {
            HStack(spacing: 6) {
                TextField("Type an answer", text: Binding(get: { other[question.question] ?? "" }, set: { other[question.question] = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .onSubmit { useOther(in: question) }
                AnswerButton("Use", role: .secondary) { useOther(in: question) }
            }
            .padding(.leading, 30)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
        } else {
            OptionRow(label: "Other…", description: nil, multi: question.multiSelect,
                      selected: chosen[question.question, default: []].contains { label in !question.options.contains { $0.label == label } }) {
                typing = question.question
            }
        }
    }

    private var complete: Bool {
        questions.allSatisfy { !(chosen[$0.question] ?? []).isEmpty }
    }

    private func pick(_ label: String, in question: AgentRequest.Question) {
        var labels = chosen[question.question] ?? []
        if question.multiSelect {
            if let index = labels.firstIndex(of: label) { labels.remove(at: index) } else { labels.append(label) }
        } else {
            labels = [label]
        }
        chosen[question.question] = labels
        // One choice made: on to the next question, as the CLI does.
        if !question.multiSelect, !isLast { advanceSoon() }
    }

    /// A beat to see the pick land before the next question replaces it.
    private func advanceSoon() {
        let from = step
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if step == from { go(to: from + 1) }
        }
    }

    private func useOther(in question: AgentRequest.Question) {
        let text = (other[question.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        typing = nil
        guard !text.isEmpty else { return }
        var labels = (chosen[question.question] ?? []).filter { label in question.options.contains { $0.label == label } }
        if question.multiSelect { labels.append(text) } else { labels = [text] }
        chosen[question.question] = labels
        if !question.multiSelect, !isLast { advanceSoon() }
    }

    private func submit() {
        guard complete else { return }
        store.answer(request, .answers(chosen))
    }
}

/// One choice: a radio (or check) mark, its label, and a one-line note. Chosen
/// reads as a filled mark and brighter text, not a coloured block.
private struct OptionRow: View {
    let label: String
    let description: String?
    let multi: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.35))
                    .frame(width: 14)
                // The label, and under it its note in full: what each choice means is
                // what the decision rests on.
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.88))
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(selected ? 0.06 : hovered ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AnswerButton: View {
    enum Role { case primary, secondary, quiet }

    let title: String
    let role: Role
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, role: Role, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            // A Mac's push buttons: small rounded rectangles, the default one in the accent.
            Text(title)
                .font(.system(size: 12, weight: role == .primary ? .semibold : .medium))
                .foregroundStyle(role == .primary ? .white : .white.opacity(role == .quiet ? 0.65 : 0.8))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var background: Color {
        switch role {
        case .primary: Color(red: 0.2, green: 0.45, blue: 1.0).opacity(hovered ? 1 : 0.9)
        case .secondary: .white.opacity(hovered ? 0.12 : 0.07)
        case .quiet: .white.opacity(hovered ? 0.1 : 0)
        }
    }
}
