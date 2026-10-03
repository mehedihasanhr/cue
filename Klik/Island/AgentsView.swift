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
/// than shipped with Klik, and looked up once.
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
/// app is not installed. While the agent works, a slow ring of light circles it.
private struct AgentTile: View {
    let agent: AgentKind
    let working: Bool
    var side: CGFloat = 30

    var body: some View {
        Group {
            if let icon = AgentAppIcon.image(for: agent) {
                // App icons carry their own margin; scaled up a touch so the art fills the tile.
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(1.18)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.26, style: .continuous))
            } else {
                AgentGlyph(agent: agent, size: side * 0.53, spinning: working)
                    .frame(width: side, height: side)
                    .background {
                        RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                            .fill(.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: side * 0.3, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                    }
            }
        }
        .overlay {
            if working { WorkingRing(radius: side * 0.3) }
        }
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

/// The closed notch while an agent works: a thin line of red light along its left,
/// bottom and right edges, breathing softly, with a brighter glint gliding to and
/// fro along it. Amber and quicker while an agent waits on the user. The notch
/// itself stays plain black; the light only shows outside its edge.
struct NotchGlow: View {
    let shape: NotchShape
    let size: CGSize
    let asking: Bool

    private static let red = Color(red: 1.0, green: 0.26, blue: 0.22)
    private static let redCore = Color(red: 1.0, green: 0.66, blue: 0.58)
    private static let amberCore = Color(red: 1.0, green: 0.88, blue: 0.66)
    /// How much of the rim the glint covers.
    private static let glint: CGFloat = 0.22

    var body: some View {
        let outline = NotchOutline(flare: shape.flare, bottomRadius: shape.bottomRadius)
        let color = asking ? askingTint : Self.red
        let core = asking ? Self.amberCore : Self.redCore
        Group {
            if IslandView.reduceMotion {
                rim(outline, color: color, level: 0.8)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let breath = 0.5 + 0.5 * sin(t * 2 * .pi / (asking ? 0.9 : 2.2))
                    // To and fro, lingering a moment at each end.
                    let sweep = 0.5 - 0.5 * cos(t * 2 * .pi / (asking ? 1.6 : 2.8))
                    let start = sweep * (1 - Self.glint)
                    ZStack {
                        rim(outline, color: color, level: 0.55 + 0.45 * breath)
                        outline.trim(from: start, to: start + Self.glint)
                            .stroke(color, style: SwiftUI.StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                            .blur(radius: 5)
                            .opacity(0.7)
                        outline.trim(from: start + Self.glint * 0.2, to: start + Self.glint * 0.8)
                            .stroke(core, style: SwiftUI.StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .blur(radius: 0.6)
                    }
                }
            }
        }
        // The inner half of every stroke sits under the black, so the light reads
        // as coming from behind the notch's edge.
        .overlay { shape.fill(.black) }
        .frame(width: size.width, height: size.height)
    }

    private func rim(_ outline: NotchOutline, color: Color, level: Double) -> some View {
        ZStack {
            outline.stroke(color, style: SwiftUI.StrokeStyle(lineWidth: 5, lineJoin: .round))
                .blur(radius: 4)
                .opacity(0.35 * level)
            outline.stroke(color, style: SwiftUI.StrokeStyle(lineWidth: 2, lineJoin: .round))
                .opacity(0.75 * level)
        }
    }
}

/// The notch's visible edges (left side, bottom, right side) as one open line,
/// so a stretch of it can be lit with `trim`. Matches `NotchShape` with no top radius.
private nonisolated struct NotchOutline: Shape {
    let flare: CGFloat
    let bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let flare = min(self.flare, rect.width / 4)
        let body = rect.insetBy(dx: flare, dy: 0)
        let bottom = min(bottomRadius, body.width / 2, body.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: body.minX, y: body.minY + flare))
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: body.minX + bottom, y: body.maxY), control: CGPoint(x: body.minX, y: body.maxY))
        path.addLine(to: CGPoint(x: body.maxX - bottom, y: body.maxY))
        path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.maxY - bottom), control: CGPoint(x: body.maxX, y: body.maxY))
        path.addLine(to: CGPoint(x: body.maxX, y: body.minY + flare))
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

/// The island's rim when a turn finishes: the running agent's red glow comes back
/// green, blooms once and settles while the card is up.
struct CompletionGlow: View {
    let shape: NotchShape
    let size: CGSize
    @State private var lit = false

    var body: some View {
        shape.fill(doneGreen)
            .scaleEffect(x: 1 + 8 / size.width, y: 1 + 6 / size.height, anchor: .top)
            .blur(radius: 6)
            .keyframeAnimator(initialValue: 0.0, trigger: lit) { view, value in
                view.opacity(value)
            } keyframes: { _ in
                CubicKeyframe(0.9, duration: 0.3)
                CubicKeyframe(0.9, duration: 0.35)
                CubicKeyframe(0.3, duration: 0.9)
            }
            .frame(width: size.width, height: size.height)
            .onAppear { lit = true }
    }
}

/// A finished turn on the island. It plays as one short moment: a ring closes
/// around the agent's icon and a check lands on its corner, the words come into
/// focus one after the other, and the turn's time counts up to its total.
struct AgentDoneRow: View {
    let done: AgentDone
    @State private var ring = false
    @State private var badge = false
    @State private var words = false
    @State private var aura: Double = 0
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
        .background(alignment: .leading) {
            // A green light behind the icon, as if the check were lit from inside.
            RadialGradient(colors: [doneGreen.opacity(0.3), .clear], center: .center, startRadius: 2, endRadius: 90)
                .frame(width: 180, height: 120)
                .offset(x: -40)
                .opacity(aura)
                .allowsHitTesting(false)
        }
        .onAppear(perform: play)
    }

    private var tile: some View {
        AgentTile(agent: done.agent, working: false, side: 28)
            .padding(3)
            .overlay {
                Circle()
                    .trim(from: 0, to: ring ? 1 : 0)
                    .stroke(AngularGradient(colors: [doneGreen.opacity(0.15), doneGreen], center: .center),
                            style: SwiftUI.StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(-3)
                    .opacity(badge ? 0.55 : 1)
            }
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
            withAnimation(.easeOut(duration: 0.2)) { ring = true; badge = true; words = true; aura = 0.5 }
            return
        }
        withAnimation(.easeOut(duration: 0.25)) { aura = 1 }
        withAnimation(.easeOut(duration: 0.55).delay(0.05)) { ring = true }
        withAnimation(.spring(duration: 0.4, bounce: 0.3).delay(0.5)) { badge = true }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeOut(duration: 0.8)) { aura = 0.5 }
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
                    AgentTile(agent: lead.agent, working: false, side: 16)
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

/// A card's glass: one even, slightly blue-grey fill with a soft hairline edge.
/// Drawn rather than taken from the system's Liquid Glass, which brightens its rim
/// whenever the island's window becomes active — the card must look the same
/// whether or not the island has the keyboard. Hovered or asking, it lifts a touch.
private struct GlassPane: View {
    let tint: Color
    var lit = false
    var asking = false
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    /// #202328: the card colour measured off the unfocused island.
    private static let fill = Color(red: 0x20 / 255, green: 0x23 / 255, blue: 0x28 / 255)

    var body: some View {
        let raised = lit || asking
        shape
            .fill(Self.fill.opacity(0.9))
            .overlay(shape.fill(.white.opacity(raised ? 0.035 : 0)))
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
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

/// A faint ice-blue glow around the open list, breathing in and out: slow while
/// the agents work, a little quicker and amber while one is asking. Two shadows of the island's
/// own shape, a wide soft one and a close one, so it reads as light, not a border.
struct AgentGlow<S: Shape>: View {
    let shape: S
    let asking: Bool
    /// How far down from the top the glow fades in.
    var fadeTop: CGFloat = 64
    /// Off: a still, faint halo (the panel, the clock), half way between breaths.
    var breathing = true
    /// 0 hides it. It stays in place at 0 rather than coming and going, so it always
    /// has the island's current shape and grows with it — a glow made fresh would
    /// appear at its final size first, a second layer ahead of the island.
    var strength: Double = 1
    @State private var inhale = false

    private var color: Color { asking ? Color(red: 1.0, green: 0.7, blue: 0.32) : Color(red: 0.45, green: 0.66, blue: 0.86) }

    var body: some View {
        shape
            .fill(.black)
            .shadow(color: color.opacity(breathing ? (inhale ? 0.38 : 0.12) : 0.2), radius: breathing ? (inhale ? 24 : 14) : 20)
            .shadow(color: color.opacity(breathing ? (inhale ? 0.18 : 0.06) : 0.08), radius: breathing ? (inhale ? 6 : 3) : 4)
            // None along the top, where the shape flares into the menu bar: the glow
            // starts below the notch and reaches past the sides and bottom.
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: fadeTop)
                    Color.black
                }
                .padding(.horizontal, -60)
                .padding(.bottom, -60)
            }
            .opacity(strength)
            .onAppear { breathe() }
            .onChange(of: asking) { breathe() }
            .onChange(of: breathing) { breathe() }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func breathe() {
        guard breathing, !IslandView.reduceMotion else { inhale = true; return }
        inhale = false
        withAnimation(.easeInOut(duration: asking ? 1.6 : 3.2).repeatForever(autoreverses: true)) { inhale = true }
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
    /// The list has been laid out once. Until then its height is unknown and
    /// nothing is reported, so the island opens straight to its full size, in one
    /// movement, the way the panel does — not to the header first and then again.
    @State private var measured = false
    /// The header, the gap under it and the padding around it all.
    private static let chrome: CGFloat = 24 + 12 + 14

    private var listLimit: CGFloat { max(120, maxHeight - Self.chrome) }
    private var overflows: Bool { listHeight > listLimit + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if store.sessions.isEmpty {
                Text("No agent sessions running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(store.sessions) { session in
                            AgentSessionCard(session: session, requests: store.requests(for: session), store: store)
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
                }
                .scrollIndicators(overflows ? .automatic : .never)
                // Until it has measured itself the list takes the room it is given, so
                // the cards are there from the first frame and open with the island,
                // rather than the island opening empty and the cards following.
                .frame(height: measured ? min(listHeight, listLimit) : nil)
                // More below: the last card fades out at the bottom edge.
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(overflows ? 0.15 : 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 28)
                    }
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
    }



    private var header: some View {
        HStack(spacing: 8) {
            LiveDot(color: store.requests.isEmpty ? .green : askingTint)
            Text("AGENTS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(2.2)
                .foregroundStyle(.white.opacity(0.92))
            Text(String(format: "%02d", store.sessions.count))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(.white.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            Spacer()
            HeaderButton(symbol: "square.grid.2x2", help: "Open the panel", action: openPanel)
            HeaderButton(symbol: "xmark", help: "Close", action: close)
        }
        .frame(height: 24)
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

private struct AgentSessionCard: View {
    let session: AgentSession
    let requests: [AgentRequest]
    let store: AgentStore
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { store.focus(session) } label: { summary }
                .buttonStyle(.plain)
                .help("Show in \(store.hosts[session.id]?.name ?? session.terminal.map(Self.terminalName) ?? "its terminal")")
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
                AgentRequestCard(request: request, store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .padding(10)
        .background { GlassPane(tint: session.agent.tint, lit: hovered, asking: !requests.isEmpty) }
        .onHover { hovered = $0 }
        .animation(IslandView.contentAnimation, value: hovered)
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentTile(agent: session.agent, working: session.state == .running)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(session.profile.map { "\(session.agent.shortName) · \($0)" } ?? session.agent.shortName)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer(minLength: 6)
                    stateLabel
                }
                Text(session.activity ?? Self.placeholder(for: session.state))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .truncationMode(.tail)
            }
            .lineLimit(1)
            // Where it runs: the terminal's or app's own icon, which a click brings forward.
            if let icon = store.hosts[session.id]?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .opacity(hovered ? 1 : 0.7)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 6.5, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(2)
                            .background(.black.opacity(0.7), in: Circle())
                            .offset(x: 3, y: 3)
                            .opacity(hovered ? 1 : 0)
                    }
            } else {
                Icon("arrow.up.forward.app", size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(hovered ? 0.8 : 0.35))
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var stateLabel: some View {
        HStack(spacing: 5) {
            StatusText(state: session.state)
            if session.state == .running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(since: session.updatedAt, now: context.date))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
    }

    private static func placeholder(for state: AgentSession.State) -> String {
        switch state {
        case .running: "Thinking…"
        case .waiting: "Waiting for you"
        case .idle: "Waiting for a prompt"
        }
    }

    private static func elapsed(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
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
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).font(.system(size: 11.5, weight: .semibold))
            } icon: {
                Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(askingTint)
            if let detail = summary.detail, !detail.isEmpty {
                // Whole lines only (five at most); the full command is in the tooltip.
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(5)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
                    .help(detail)
            }
            HStack(spacing: 6) {
                AnswerButton("Deny", role: .quiet) { store.answer(request, .deny) }
                Spacer(minLength: 0)
                if request.canAllowAlways {
                    AnswerButton(request.agent == .codex ? "Allow for session" : "Always allow", role: .secondary) { store.answer(request, .allowAlways) }
                        .help(request.agent == .codex ? "Allow this command again without asking until the session ends" : "Allow this and don’t ask again, the way Claude Code’s own prompt offers")
                }
                AnswerButton("Allow once", role: .primary) { store.answer(request, .allowOnce) }
            }
        }
    }

    private var title: String {
        switch summary.tool {
        case "Bash": "Run this command?"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "Edit files": "Make this edit?"
        case "WebFetch": "Fetch this page?"
        default: "Use \(summary.tool)?"
        }
    }
}

private struct PlanCard: View {
    let request: AgentRequest
    let plan: String
    let store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Ready to start on this plan?").font(.system(size: 11.5, weight: .semibold))
            } icon: {
                Image(systemName: "list.bullet.clipboard").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(askingTint)
            if !plan.isEmpty {
                ScrollView(.vertical) {
                    Text((try? AttributedString(markdown: plan, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(plan))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 6) {
                AnswerButton("Keep planning", role: .quiet) { store.answer(request, .deny) }
                Spacer(minLength: 0)
                if request.canAllowAlways {
                    AnswerButton("Approve, auto-edit", role: .secondary) { store.answer(request, .allowAlways) }
                        .help("Approve and let Claude make edits without asking")
                }
                AnswerButton("Approve", role: .primary) { store.answer(request, .allowOnce) }
            }
        }
    }
}

/// AskUserQuestion: each question with its options. A single question with a single
/// answer goes as soon as an option is clicked; otherwise Submit sends them all.
private struct QuestionsCard: View {
    let request: AgentRequest
    let questions: [AgentRequest.Question]
    let store: AgentStore

    @State private var chosen: [String: [String]] = [:]
    @State private var other: [String: String] = [:]
    @State private var typing: String?

    private var answersAtOnce: Bool { questions.count == 1 && questions[0].multiSelect == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = question.header, !header.isEmpty {
                        Text(header.uppercased())
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(askingTint)
                    }
                    Text(question.question)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 4) {
                        ForEach(question.options) { option in
                            OptionRow(label: option.label, description: option.description, multi: question.multiSelect,
                                      selected: chosen[question.question, default: []].contains(option.label)) {
                                pick(option.label, in: question)
                            }
                        }
                        otherRow(for: question)
                    }
                }
            }
            HStack(spacing: 6) {
                AnswerButton("Answer in terminal", role: .quiet) { store.answerInTerminal(request) }
                Spacer(minLength: 0)
                if !answersAtOnce {
                    AnswerButton("Submit", role: .primary) { submit() }
                        .disabled(!complete)
                        .opacity(complete ? 1 : 0.45)
                }
            }
        }
    }

    @ViewBuilder
    private func otherRow(for question: AgentRequest.Question) -> some View {
        if typing == question.question {
            HStack(spacing: 6) {
                TextField("Type an answer", text: Binding(get: { other[question.question] ?? "" }, set: { other[question.question] = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white)
                    .onSubmit { useOther(in: question) }
                AnswerButton("Use", role: .secondary) { useOther(in: question) }
            }
            .padding(.leading, 10)
            .padding(.vertical, 4)
            .padding(.trailing, 4)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        if answersAtOnce { submit() }
    }

    private func useOther(in question: AgentRequest.Question) {
        let text = (other[question.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        typing = nil
        guard !text.isEmpty else { return }
        var labels = (chosen[question.question] ?? []).filter { label in question.options.contains { $0.label == label } }
        if question.multiSelect { labels.append(text) } else { labels = [text] }
        chosen[question.question] = labels
        if answersAtOnce { submit() }
    }

    private func submit() {
        guard complete else { return }
        store.answer(request, .answers(chosen))
    }
}

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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? askingTint : .white.opacity(0.45))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(selected ? 0.14 : hovered ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
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
            Text(title)
                .font(.system(size: 11.5, weight: role == .primary ? .semibold : .medium))
                .foregroundStyle(role == .primary ? .black : .white.opacity(role == .quiet ? 0.7 : 0.9))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(background, in: Capsule())
                .overlay {
                    if role == .secondary { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
                }
                .shadow(color: role == .primary ? .white.opacity(hovered ? 0.45 : 0.22) : .clear, radius: hovered ? 10 : 6)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var background: Color {
        switch role {
        case .primary: .white.opacity(hovered ? 1 : 0.92)
        case .secondary: .white.opacity(hovered ? 0.2 : 0.13)
        case .quiet: .white.opacity(hovered ? 0.1 : 0)
        }
    }
}
