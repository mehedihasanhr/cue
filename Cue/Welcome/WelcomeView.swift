import SwiftUI

/// The first thing Cue shows: "hello" written out by hand, the critter looking about,
/// a word of welcome, then a short tour of what Cue does (each page a small Mac
/// playing the feature out), the permissions it asks for, and a send-off.
struct WelcomeView: View {
    enum Step: Hashable {
        case hello, welcome, tour(TourPage), permissions, finale
    }

    let start: Step
    let onDone: () -> Void

    @State private var step: Step
    /// Pages slide in from the side they come from.
    @State private var forward = true
    @State private var helloDrawn: CGFloat = 0
    @State private var helloGone = false
    @State private var critterIn = false
    @State private var textIn = false
    @FocusState private var focused: Bool

    private var motion: Bool { !IslandView.reduceMotion }

    init(start: Step = .hello, onDone: @escaping () -> Void) {
        self.start = start
        self.onDone = onDone
        _step = State(initialValue: start == .hello && IslandView.reduceMotion ? .welcome : start)
    }

    var body: some View {
        ZStack {
            WelcomeBackdrop(tint: tint)
            switch step {
            case .hello, .welcome:
                opening
            case .tour(let page):
                tour(page)
                    .transition(.push(from: forward ? .trailing : .leading))
                    .id(page)
            case .permissions:
                WelcomePermissions(onBack: { go(.tour(TourPage.allCases.last!), forward: false) },
                                   onNext: { go(.finale) })
                    .transition(.push(from: forward ? .trailing : .leading))
            case .finale:
                finale
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: WelcomeWindowController.size.width, height: WelcomeWindowController.size.height)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.rightArrow) { advance(); return .handled }
        .onKeyPress(.leftArrow) { retreat(); return .handled }
        .onAppear { focused = true }
        .task { await playOpening() }
    }

    private var tint: Color {
        switch step {
        case .tour(let page): page.tint
        case .permissions: Color(red: 0.95, green: 0.62, blue: 0.3)
        case .finale: Color(red: 0.36, green: 0.82, blue: 0.48)
        default: IslandStyle.accent
        }
    }

    // MARK: - Opening

    /// "hello" written in one stroke, then it lifts away and the critter comes up to
    /// look around, with the welcome under it.
    private var opening: some View {
        ZStack {
            HelloLettering()
                .trim(from: 0, to: helloDrawn)
                .stroke(LinearGradient(colors: [.white, Color(red: 0.78, green: 0.86, blue: 1)], startPoint: .leading, endPoint: .trailing),
                        style: SwiftUI.StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                .background {
                    HelloLettering()
                        .trim(from: 0, to: helloDrawn)
                        .stroke(IslandStyle.accent, style: SwiftUI.StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
                        .blur(radius: 14)
                        .opacity(0.7)
                }
                .frame(width: 340, height: 150)
                .scaleEffect(helloGone ? 0.7 : 1)
                .offset(y: helloGone ? -60 : 0)
                .opacity(helloGone ? 0 : 1)
                .blur(radius: helloGone ? 8 : 0)

            VStack(spacing: 0) {
                CueCritter(side: 96, mood: .lookAround)
                    .shadow(color: IslandStyle.accent.opacity(0.5), radius: 24)
                    .scaleEffect(critterIn ? 1 : 0.4, anchor: .bottom)
                    .offset(y: critterIn ? 0 : 40)
                    .opacity(critterIn ? 1 : 0)
                    .padding(.bottom, 26)
                VStack(spacing: 10) {
                    Text("Welcome to Cue.")
                        .font(.system(size: 34, weight: .bold))
                    Text("Cue puts a shelf for files, your music, your clipboard and more in the notch, a glance away. Here's a quick tour.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .offset(y: textIn ? 0 : 12)
                .opacity(textIn ? 1 : 0)
                VStack(spacing: 10) {
                    WelcomeButton("Take the tour", prominent: true) { go(.tour(TourPage.allCases[0])) }
                    Button("Skip tour") { go(.permissions) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.top, 34)
                .opacity(textIn ? 1 : 0)
            }
            .allowsHitTesting(textIn)
        }
    }

    private func playOpening() async {
        guard step == .hello || step == .welcome else { return }
        if step == .welcome || !motion {
            helloGone = true; critterIn = true; textIn = true
            step = .welcome
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        withAnimation(.easeInOut(duration: 1.9)) { helloDrawn = 1 }
        try? await Task.sleep(for: .milliseconds(2500))
        withAnimation(.easeIn(duration: 0.45)) { helloGone = true }
        try? await Task.sleep(for: .milliseconds(250))
        step = .welcome
        withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { critterIn = true }
        try? await Task.sleep(for: .milliseconds(450))
        withAnimation(.easeOut(duration: 0.5)) { textIn = true }
    }

    // MARK: - Tour

    private func tour(_ page: TourPage) -> some View {
        let index = TourPage.allCases.firstIndex(of: page) ?? 0
        return VStack(spacing: 0) {
            TourStage(page: page)
                .padding(.top, 46)
            VStack(spacing: 8) {
                Text(page.headline)
                    .font(.system(size: 26, weight: .bold))
                Text(page.line)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 26)
            Spacer(minLength: 0)
            HStack {
                Button("Back") { retreat() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 90, alignment: .leading)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(TourPage.allCases, id: \.self) { other in
                        Capsule()
                            .fill(.white.opacity(other == page ? 0.9 : 0.22))
                            .frame(width: other == page ? 16 : 6, height: 6)
                    }
                }
                Spacer()
                WelcomeButton(index == TourPage.allCases.count - 1 ? "Continue" : "Next", prominent: true, compact: true) { advance() }
                    .frame(width: 90, alignment: .trailing)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 26)
        }
        .overlay(alignment: .topTrailing) {
            Button("Skip tour") { go(.permissions) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 14)
                .padding(.trailing, 18)
        }
    }

    private func advance() {
        switch step {
        case .hello, .welcome: go(.tour(TourPage.allCases[0]))
        case .tour(let page):
            if let next = page.next { go(.tour(next)) } else { go(.permissions) }
        case .permissions: go(.finale)
        case .finale: onDone()
        }
    }

    private func retreat() {
        switch step {
        case .tour(let page):
            if let previous = page.previous { go(.tour(previous), forward: false) } else { go(.welcome, forward: false) }
        case .permissions: go(.tour(TourPage.allCases.last!), forward: false)
        default: break
        }
    }

    private func go(_ next: Step, forward: Bool = true) {
        self.forward = forward
        if next == .welcome { helloGone = true; critterIn = true; textIn = true }
        withAnimation(motion ? .spring(response: 0.5, dampingFraction: 0.86) : .easeOut(duration: 0.15)) { step = next }
    }

    // MARK: - Finale

    private var finale: some View {
        VStack(spacing: 0) {
            CueCritter(side: 110, mood: .dance)
                .shadow(color: Color(red: 0.36, green: 0.82, blue: 0.48).opacity(0.45), radius: 26)
                .padding(.bottom, 28)
            Text("You're all set.")
                .font(.system(size: 34, weight: .bold))
            Text("Cue lives in the notch now. Move the pointer up to it, or drag a file there.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.top, 10)
            WelcomeButton("Start using Cue", prominent: true) { onDone() }
                .padding(.top, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { if motion { Confetti().allowsHitTesting(false) } }
    }
}

/// One stop on the tour.
enum TourPage: String, CaseIterable, Hashable {
    case shelf, transform, shake, music, mini, clipboard, huds, notifications, compact, agents, glass, plainMac

    var headline: String {
        switch self {
        case .shelf: "Keep files within reach."
        case .transform: "Transform any file."
        case .shake: "Gather files as you go."
        case .music: "Your music, one glance up."
        case .mini: "Your music, floating free."
        case .clipboard: "Never lose what you copied."
        case .huds: "Volume, brightness and more."
        case .notifications: "Notifications, in the notch."
        case .compact: "Glances beside the island."
        case .agents: "Your agents, at a glance."
        case .glass: "Liquid Glass, your way."
        case .plainMac: "Every Mac gets an island."
        }
    }

    var line: String {
        switch self {
        case .shelf: "Drag files to the top of the screen and drop them on the shelf. They wait there until you drag them into any app."
        case .transform: "Drop images on Transform to convert them to WebP, JPEG or HEIC, make them smaller, or zip them up."
        case .shake: "Shake the pointer while you drag and four places come up right under it: the basket, Transform, a share link and AirDrop."
        case .music: "See what's playing, scrub through it and read along with synced lyrics. Music, Spotify and your browser."
        case .mini: "Pull the player out of the island and it floats over your apps, as a small pill or a card."
        case .clipboard: "Everything you copy is kept: links, text, colours and pictures, ready to paste again."
        case .huds: "Volume, brightness, AirPods and your battery show up at the top of the screen, then step aside."
        case .notifications: "Banners from every app arrive in the island, and the Notifications tab keeps them. Turn it on in Settings."
        case .compact: "The time, your battery, the next meeting or the weather, either side of the notch."
        case .agents: "Claude Code and Codex sessions, with their usage limits, answered right from the island."
        case .glass: "Choose the glass, how dark it is and its tint in Settings › Island."
        case .plainMac: "No notch? Cue draws an island at the top of any display that works just the same."
        }
    }

    /// The colour the page glows with.
    var tint: Color {
        switch self {
        case .shelf, .shake: Color(red: 0.4, green: 0.55, blue: 1)
        case .transform: Color(red: 0.6, green: 0.45, blue: 1)
        case .music, .mini: Color(red: 1, green: 0.42, blue: 0.55)
        case .clipboard: Color(red: 0.32, green: 0.78, blue: 0.86)
        case .huds, .compact: Color(red: 0.4, green: 0.8, blue: 0.5)
        case .notifications: Color(red: 1, green: 0.6, blue: 0.3)
        case .agents: Color(red: 0.86, green: 0.5, blue: 0.36)
        case .glass, .plainMac: IslandStyle.accent
        }
    }

    var next: TourPage? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    var previous: TourPage? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }
}

// MARK: - Pieces

/// Near-black with a slow glow of the page's colour from the top.
private struct WelcomeBackdrop: View {
    let tint: Color

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.07), Color(white: 0.02)], startPoint: .top, endPoint: .bottom)
            Ellipse()
                .fill(tint.opacity(0.32))
                .frame(width: 620, height: 300)
                .blur(radius: 110)
                .offset(y: -230)
            Ellipse()
                .fill(tint.opacity(0.12))
                .frame(width: 500, height: 200)
                .blur(radius: 120)
                .offset(y: 300)
        }
        .animation(.easeInOut(duration: 0.6), value: tint)
        .ignoresSafeArea()
    }
}

/// The tour's buttons: a white pill for the way on, otherwise quiet.
struct WelcomeButton: View {
    let title: String
    var prominent = false
    var compact = false
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, compact: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, compact ? 16 : 26)
                .padding(.vertical, compact ? 7 : 11)
                .background(Capsule().fill(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(prominent ? .defaultAction : nil)
    }
}

/// "hello" in joined-up handwriting, as one stroke to be drawn out.
nonisolated struct HelloLettering: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn on a 260 × 120 grid and scaled to fit.
        let scale = min(rect.width / 260, rect.height / 120)
        let origin = CGPoint(x: rect.midX - 130 * scale, y: rect.midY - 60 * scale)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        var path = Path()
        path.move(to: p(4, 96))
        // h: up the loop, down its back, over the hump.
        path.addCurve(to: p(42, 12), control1: p(22, 80), control2: p(46, 32))
        path.addCurve(to: p(28, 102), control1: p(36, -6), control2: p(20, 42))
        path.addCurve(to: p(62, 100), control1: p(36, 56), control2: p(62, 50))
        path.addCurve(to: p(80, 90), control1: p(64, 106), control2: p(72, 104))
        // e
        path.addCurve(to: p(104, 66), control1: p(96, 84), control2: p(110, 76))
        path.addCurve(to: p(88, 78), control1: p(98, 54), control2: p(84, 62))
        path.addCurve(to: p(120, 94), control1: p(90, 98), control2: p(108, 102))
        // l
        path.addCurve(to: p(152, 12), control1: p(138, 82), control2: p(160, 34))
        path.addCurve(to: p(136, 98), control1: p(146, -6), control2: p(130, 40))
        path.addCurve(to: p(160, 92), control1: p(140, 106), control2: p(152, 104))
        // l
        path.addCurve(to: p(190, 12), control1: p(176, 80), control2: p(198, 34))
        path.addCurve(to: p(174, 98), control1: p(184, -6), control2: p(168, 40))
        path.addCurve(to: p(198, 82), control1: p(178, 106), control2: p(192, 100))
        // o, and a flourish off its top.
        path.addCurve(to: p(218, 64), control1: p(200, 70), control2: p(208, 62))
        path.addCurve(to: p(224, 100), control1: p(236, 66), control2: p(238, 98))
        path.addCurve(to: p(206, 78), control1: p(210, 102), control2: p(202, 90))
        path.addCurve(to: p(224, 66), control1: p(208, 70), control2: p(216, 64))
        path.addCurve(to: p(256, 68), control1: p(234, 68), control2: p(246, 74))
        return path
    }
}

/// A burst of paper falling from the top, for the send-off.
private struct Confetti: View {
    private struct Piece {
        let x: CGFloat, delay: Double, speed: Double, spin: Double, sway: Double, size: CGSize, color: Color
    }

    @State private var start = Date()
    private static let colors: [Color] = [Color(red: 0.36, green: 0.82, blue: 0.48), Color(red: 0.4, green: 0.6, blue: 1),
                                          Color(red: 1, green: 0.5, blue: 0.6), Color(red: 1, green: 0.8, blue: 0.3), .white]
    private let pieces: [Piece] = (0..<70).map { index in
        var generator = SeededGenerator(seed: UInt64(index) &* 2_654_435_761 &+ 1)
        return Piece(x: .random(in: 0...1, using: &generator), delay: .random(in: 0...0.9, using: &generator),
                     speed: .random(in: 0.32...0.6, using: &generator), spin: .random(in: -6...6, using: &generator),
                     sway: .random(in: 8...26, using: &generator),
                     size: CGSize(width: .random(in: 5...9, using: &generator), height: .random(in: 8...14, using: &generator)),
                     color: colors[index % colors.count])
    }

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                for piece in pieces {
                    let age = time - piece.delay
                    guard age > 0 else { continue }
                    let y = -20 + age * piece.speed * size.height
                    guard y < size.height + 20 else { continue }
                    let x = piece.x * size.width + sin(age * 3 + piece.x * 10) * piece.sway
                    var paper = canvas
                    paper.translateBy(x: x, y: y)
                    paper.rotate(by: .radians(age * piece.spin))
                    // Turning over: narrower as it flips.
                    let width = piece.size.width * abs(cos(age * piece.spin * 0.7))
                    paper.opacity = min(1, max(0, 3.5 - age))
                    paper.fill(Path(CGRect(x: -width / 2, y: -piece.size.height / 2, width: width, height: piece.size.height)),
                               with: .color(piece.color))
                }
            }
        }
    }
}

/// The same numbers every time, so the confetti falls the same way on each look.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
