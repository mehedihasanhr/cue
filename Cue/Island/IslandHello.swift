import SwiftUI

/// What the island shows as Cue starts: the critter peeking out and looking about,
/// "hello" written in one stroke beside it, then a greeting for the time of day, a
/// light passing along the edge as it settles.
struct IslandHello: View {
    /// How long the island holds it before going back into the notch.
    static let duration = 2.8

    @State private var drawn: CGFloat = 0
    @State private var greeted = false
    @State private var critterIn = false
    @State private var sweep: CGFloat = -1

    private static let ink = LinearGradient(colors: [.white, Color(red: 0.72, green: 0.82, blue: 1)], startPoint: .leading, endPoint: .trailing)

    var body: some View {
        HStack(spacing: 12) {
            CueCritter(side: 26, mood: .lookAround)
                .scaleEffect(critterIn ? 1 : 0.3, anchor: .bottom)
                .opacity(critterIn ? 1 : 0)
            HelloLettering()
                .trim(from: 0, to: drawn)
                .stroke(Self.ink, style: SwiftUI.StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                .background {
                    HelloLettering()
                        .trim(from: 0, to: drawn)
                        .stroke(IslandStyle.accent, style: SwiftUI.StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                        .blur(radius: 6)
                        .opacity(0.8)
                }
                .frame(width: 70, height: 30)
            Capsule()
                .fill(.white.opacity(0.14))
                .frame(width: 1, height: 22)
                .opacity(greeted ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.greeting(for: .now))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Cue is ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .fixedSize()
            .offset(x: greeted ? 0 : -6)
            .opacity(greeted ? 1 : 0)
        }
        .padding(.horizontal, 18)
        .overlay {
            // Light running across once, as if catching the edge of the glass.
            LinearGradient(colors: [.clear, .white.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 80)
                .rotationEffect(.degrees(16))
                .offset(x: sweep * 220)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.greeting(for: .now)). Cue is ready.")
        .onAppear(perform: play)
    }

    private func play() {
        guard !IslandView.reduceMotion else {
            critterIn = true; drawn = 1; greeted = true
            return
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.12)) { critterIn = true }
        withAnimation(.easeInOut(duration: 1.05).delay(0.3)) { drawn = 1 }
        withAnimation(.easeOut(duration: 0.4).delay(1.2)) { greeted = true }
        withAnimation(.easeInOut(duration: 0.9).delay(1.5)) { sweep = 1 }
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Hello, night owl"
        }
    }
}
