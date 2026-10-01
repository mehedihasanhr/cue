import SwiftUI

/// What the bar's light is saying: ready, live, held, or something wrong.
enum BarMood: Equatable {
    case ready, live, held, alert

    /// The three lights of the smoke, back to front.
    fileprivate var smoke: [Color] {
        switch self {
        case .ready:
            [StudioPalette.brand, Color(red: 0.56, green: 0.32, blue: 1), Color(red: 0.16, green: 0.72, blue: 1)]
        case .live:
            [Color(red: 1, green: 0.2, blue: 0.24), Color(red: 1, green: 0.36, blue: 0.62), Color(red: 1, green: 0.5, blue: 0.2)]
        case .held:
            [Color(red: 1, green: 0.62, blue: 0.1), Color(red: 1, green: 0.45, blue: 0.2), Color(red: 1, green: 0.8, blue: 0.3)]
        case .alert:
            [Color(red: 1, green: 0.45, blue: 0.1), Color(red: 1, green: 0.25, blue: 0.2), Color(red: 1, green: 0.7, blue: 0.25)]
        }
    }

    /// The bar's one colour for this mood: the light round the edge, and what is chosen
    /// or switched on — so the controls and the light are plainly the same thing.
    var accent: Color {
        switch self {
        case .ready: Color(red: 0.25, green: 0.47, blue: 1)
        case .live: Color(red: 1, green: 0.27, blue: 0.3)
        case .held: Color(red: 1, green: 0.62, blue: 0.16)
        case .alert: Color(red: 1, green: 0.5, blue: 0.16)
        }
    }

    fileprivate var edge: Color { accent }

    /// How long the edge light takes to go once round. Quicker while a take is live: the
    /// bar is the one thing on screen saying "this is being recorded".
    fileprivate var lap: Double {
        switch self {
        case .ready: 16
        case .live: 9
        case .held, .alert: 18
        }
    }

    /// How strongly the smoke shows through the glass.
    fileprivate var glow: Double {
        switch self {
        case .ready: 0.13
        case .live: 0.18
        case .held, .alert: 0.13
        }
    }
}

/// A faint coloured haze drifting behind the bar's controls — a tint, not a show.
///
/// Three soft lights, each a blurred ellipse wandering between two places on its own
/// clock. The clocks are deliberately not multiples of one another, so the three never
/// fall back into the same arrangement and the drift reads as weather rather than a loop.
/// Animated by SwiftUI's own repeating animations rather than redrawn from a timeline:
/// the movement is interpolated by the renderer, and nothing here is laid out again per
/// frame — this sits on screen through a whole take, over the thing being recorded.
///
/// Still under Reduce Motion: the same light, not moving.
struct BarSmoke: View {
    let mood: BarMood
    @State private var drifting = false

    private struct Wisp {
        let from: UnitPoint
        let to: UnitPoint
        let width: CGFloat
        let height: CGFloat
        let period: Double
    }

    private static let wisps: [Wisp] = [
        Wisp(from: UnitPoint(x: 0.08, y: 0.7), to: UnitPoint(x: 0.42, y: 0.25), width: 0.42, height: 1.5, period: 9.3),
        Wisp(from: UnitPoint(x: 0.88, y: 0.3), to: UnitPoint(x: 0.55, y: 0.8), width: 0.38, height: 1.4, period: 12.1),
        Wisp(from: UnitPoint(x: 0.5, y: 1.0), to: UnitPoint(x: 0.75, y: 0.1), width: 0.3, height: 1.2, period: 7.7),
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                ForEach(Self.wisps.indices, id: \.self) { index in
                    let wisp = Self.wisps[index]
                    let at = drifting ? wisp.to : wisp.from
                    Ellipse()
                        .fill(mood.smoke[index])
                        .frame(width: size.width * wisp.width, height: size.height * wisp.height)
                        .scaleEffect(drifting ? 1.15 : 0.9)
                        .position(x: size.width * at.x, y: size.height * at.y)
                        .animation(drift(wisp.period), value: drifting)
                }
            }
            .blur(radius: size.height * 0.42)
        }
        .opacity(mood.glow)
        .blendMode(.plusLighter)
        .animation(.easeInOut(duration: 0.8), value: mood)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if !StudioMotion.reduceMotion { drifting = true } }
    }

    private func drift(_ period: Double) -> Animation {
        .easeInOut(duration: period).repeatForever(autoreverses: true)
    }
}

/// A faint light that travels round the bar's edge.
///
/// An angular gradient — one bright arc, the rest of the turn dark — stroked along the
/// bar's outline and turned. Round a long, thin bar the arc dashes along the short ends and
/// slows down the long ones, which is what makes it read as light running round a rim
/// rather than a spinner.
struct BarEdgeLight: View {
    let mood: BarMood
    let cornerRadius: CGFloat
    @State private var turned = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            // A thin line of light and nothing round it: the bar sits over somebody's work,
            // and a glow there pulled the eye off it.
            sweep.mask(shape.strokeBorder(lineWidth: 1))
                .opacity(0.6)
            // A fine highlight along the top, as glass catches light from above.
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03), .clear],
                                              startPoint: .top, endPoint: .bottom),
                               lineWidth: 1)
        }
        .compositingGroup()
        .blendMode(.plusLighter)
        .animation(.easeInOut(duration: 0.8), value: mood)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { spin() }
        .onChange(of: mood) { _, _ in spin() }
    }

    /// The light itself: a square of angular gradient — one bright arc, the rest of the
    /// turn dark — big enough to cover the bar at any angle, turned about the bar's middle.
    /// Turned as a view rather than by animating the gradient's angle, which SwiftUI does
    /// not interpolate.
    private var sweep: some View {
        GeometryReader { proxy in
            let side = hypot(proxy.size.width, proxy.size.height)
            AngularGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.7),
                    .init(color: mood.edge.opacity(0.4), location: 0.82),
                    .init(color: .white.opacity(0.6), location: 0.87),
                    .init(color: mood.edge.opacity(0.4), location: 0.92),
                    .init(color: .clear, location: 1),
                ],
                center: .center)
                .frame(width: side, height: side)
                .rotationEffect(.degrees(turned ? 360 : 0))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    /// Round and round at the mood's pace. Restarted when the mood changes, because a
    /// repeating animation keeps the duration it was started with.
    private func spin() {
        guard !StudioMotion.reduceMotion else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { turned = false }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: mood.lap).repeatForever(autoreverses: false)) { turned = true }
        }
    }
}
