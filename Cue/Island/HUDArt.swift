import SwiftUI

/// The island's HUD pictures: small objects with some depth, drawn rather than
/// shipped as images so they stay crisp at any scale and can move. Each is lit from
/// above-left: a soft highlight on top, the colour deepening toward the bottom, a rim
/// that catches the light and a shadow under it.

/// A glossy bead in `tint` with a symbol set into it; `lit` adds a glow around it.
struct GlossyDisc: View {
    /// nil: a bare bead, its picture laid over it by the caller.
    let symbol: String?
    var tint: Color
    var size: CGFloat = 38
    var lit = true
    /// The symbol's colour; white unless the bead is light.
    var glyph: Color = .white

    var body: some View {
        ZStack {
            Circle().fill(tint)
            // Deeper toward the bottom right, as if round.
            Circle().fill(RadialGradient(colors: [.white.opacity(0.35), .clear, .black.opacity(0.45)],
                                         center: UnitPoint(x: 0.32, y: 0.25), startRadius: 0, endRadius: size * 0.85))
            // The rim: light on top, dark under.
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05), .black.opacity(0.35)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            // The highlight across the top.
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.66, height: size * 0.36)
                .offset(y: -size * 0.24)
            if let symbol {
                Icon(symbol, size: size * 0.4, weight: .bold)
                    .foregroundStyle(glyph)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(lit ? 0.55 : 0), radius: 9)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
    }
}

/// The Caps Lock key itself: a keycap with a bevel and the ⇪ engraved, its little
/// light green when on. It presses down as it appears and the light follows.
struct CapsKeycap: View {
    let on: Bool
    var size: CGFloat = 38
    @State private var pressed = false
    @State private var lightOn: Bool?

    private static let green = Color(red: 0.4, green: 0.95, blue: 0.5)

    var body: some View {
        let light = lightOn ?? !on
        ZStack(alignment: .top) {
            // The key's sides, darker, showing under the face.
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
            // The face, a little concave: lighter at the top edge.
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.22)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    // The light, set in the key's corner as on a Mac keyboard.
                    Circle()
                        .fill(light ? Self.green : Color(white: 0.12))
                        .frame(width: size * 0.12, height: size * 0.12)
                        .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 0.5))
                        .shadow(color: light ? Self.green : .clear, radius: 4)
                        .shadow(color: light ? Self.green.opacity(0.8) : .clear, radius: 1.5)
                        .padding(size * 0.13)
                }
                .overlay {
                    Icon("capslock", size: size * 0.36, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.88))
                        .shadow(color: .black.opacity(0.5), radius: 0.5, y: 0.5)
                        .offset(y: size * 0.04)
                }
                .padding(.horizontal, size * 0.06)
                .padding(.top, size * 0.04)
                .padding(.bottom, pressed ? size * 0.06 : size * 0.13)
                .offset(y: pressed ? size * 0.05 : 0)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
        .shadow(color: light ? Self.green.opacity(0.25) : .clear, radius: 10)
        .onAppear {
            guard !IslandView.reduceMotion else { lightOn = on; return }
            withAnimation(.easeIn(duration: 0.08).delay(0.12)) { pressed = true }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6).delay(0.24)) { pressed = false }
            withAnimation(.easeOut(duration: 0.15).delay(0.2)) { lightOn = on }
        }
    }
}

/// A Focus: a glossy purple orb with the moon in it and stars twinkling round it;
/// grey and still when off.
struct FocusOrb: View {
    let on: Bool
    var size: CGFloat = 38
    @State private var twinkle = false

    private static let purple = Color(red: 0.5, green: 0.36, blue: 0.98)

    var body: some View {
        ZStack {
            GlossyDisc(symbol: "moon.fill", tint: on ? Self.purple : Color(white: 0.32), size: size, lit: on,
                       glyph: on ? Color(red: 1, green: 0.95, blue: 0.75) : .white.opacity(0.7))
            if on {
                ForEach(Array(Self.stars.enumerated()), id: \.offset) { index, star in
                    Image(systemName: "sparkle")
                        .font(.system(size: star.size, weight: .bold))
                        .foregroundStyle(.white)
                        .opacity(twinkle == (index % 2 == 0) ? 1 : 0.25)
                        .scaleEffect(twinkle == (index % 2 == 0) ? 1 : 0.6)
                        .offset(x: star.x * size, y: star.y * size)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard on, !IslandView.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { twinkle = true }
        }
    }

    private static let stars: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [(0.46, -0.42, 7), (0.56, -0.08, 5), (-0.5, -0.36, 5)]
}

/// The volume: a brushed-aluminium bead with the speaker in it; the brightness, an
/// amber one with the sun.
struct LevelArt: View {
    let level: LevelHUD
    var size: CGFloat = 38

    var body: some View {
        switch level.kind {
        case .volume:
            ZStack {
                GlossyDisc(symbol: level.symbol, tint: Color(white: level.muted ? 0.5 : 0.82), size: size, lit: false,
                           glyph: Color(white: level.muted ? 0.25 : 0.18))
                // Brushed: fine rings round the centre.
                Circle()
                    .strokeBorder(AngularGradient(colors: [.white.opacity(0.25), .clear, .white.opacity(0.2), .clear, .white.opacity(0.25)],
                                                  center: .center), lineWidth: size * 0.5)
                    .blendMode(.overlay)
                    .allowsHitTesting(false)
            }
            .frame(width: size, height: size)
        case .brightness:
            GlossyDisc(symbol: level.symbol, tint: Color(red: 1.0, green: 0.68, blue: 0.2), size: size)
        }
    }
}
