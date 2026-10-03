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

    /// How strongly the smoke shows through the glass.
    fileprivate var glow: Double {
        switch self {
        case .ready: 0.13
        case .live: 0.18
        case .held, .alert: 0.13
        }
    }
}

/// A faint coloured haze behind the bar's controls — a tint, not a show.
///
/// Three soft lights, each a blurred ellipse. They used to drift, on repeating
/// animations, for the whole of every take — see the note on `body`.
struct BarSmoke: View {
    let mood: BarMood

    private struct Wisp {
        let at: UnitPoint
        let width: CGFloat
        let height: CGFloat
    }

    private static let wisps: [Wisp] = [
        Wisp(at: UnitPoint(x: 0.2, y: 0.55), width: 0.42, height: 1.5),
        Wisp(at: UnitPoint(x: 0.75, y: 0.5), width: 0.38, height: 1.4),
        Wisp(at: UnitPoint(x: 0.55, y: 0.75), width: 0.3, height: 1.2),
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                ForEach(Self.wisps.indices, id: \.self) { index in
                    let wisp = Self.wisps[index]
                    Ellipse()
                        .fill(mood.smoke[index])
                        .frame(width: size.width * wisp.width, height: size.height * wisp.height)
                        .position(x: size.width * wisp.at.x, y: size.height * wisp.at.y)
                }
            }
            .blur(radius: size.height * 0.42)
        }
        .opacity(mood.glow)
        .blendMode(.plusLighter)
        .animation(.easeInOut(duration: 0.8), value: mood)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Held still. Drifting, it was a repeating animation for the length of every take:
        // the bar redrawn at the display's rate, and the window server re-blurring the glass
        // behind it each time — a large share of the heat a recording made, for a tint.
    }
}

/// A faint light caught on one stretch of the bar's edge, in the mood's colour.
///
/// An angular gradient — one bright arc, the rest of the turn dark — stroked along the
/// bar's outline at a fixed angle.
struct BarEdgeLight: View {
    let mood: BarMood
    let cornerRadius: CGFloat

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
        // Not turned: a light running round the rim redrew the bar every frame of a take,
        // which is where a recorder's attention — and the laptop's power — should not go.
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
                .rotationEffect(.degrees(-35))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}
