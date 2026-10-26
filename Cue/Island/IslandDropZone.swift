import SwiftUI

/// What the island shows while files are dragged over it: a small card hung from the
/// notch, in place of the panel, saying where the drop goes. While the drag hovers it
/// is alive (its dashed edge runs, a glow breathes behind the tray); once the files
/// land it turns to a tick and says they were saved.
struct IslandDropZone: View {
    /// The island's size around it, below the notch strip.
    static let size = CGSize(width: 360, height: 92)
    /// How long the "saved" card stays before the island moves on.
    static let savedDuration: Duration = .milliseconds(1300)

    /// How many files the drop saved; nil while the drag still hovers.
    let saved: Int?

    @State private var lifted = false
    @State private var breathing = false
    @State private var dashPhase: CGFloat = 0
    @State private var ripple = false

    private static let savedTint = Color(red: 0.36, green: 0.82, blue: 0.48)
    private var tint: Color { saved == nil ? IslandStyle.accent : Self.savedTint }
    private var motion: Bool { !IslandView.reduceMotion }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 14) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(saved == nil ? "Images and files are kept in Assets" : "Find it in the Assets tab")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .id(saved == nil) // the words change with a fade, not a jump
            .transition(.opacity.combined(with: .offset(y: 3)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tint.opacity(saved == nil ? 0.05 : 0.1), in: shape)
        .overlay {
            if saved == nil {
                // The edge runs while the drag hovers: the card is waiting for it.
                shape.strokeBorder(tint.opacity(0.6), style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [5, 4], dashPhase: dashPhase))
            } else {
                shape.strokeBorder(tint.opacity(0.55), lineWidth: 1)
            }
        }
        .scaleEffect(saved != nil && ripple ? 1.015 : 1)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: saved)
        .onAppear {
            guard motion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lifted = true }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathing = true }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { dashPhase = -18 }
        }
        .onChange(of: saved) { _, saved in
            guard saved != nil, motion else { return }
            ripple = false
            withAnimation(.easeOut(duration: 0.7)) { ripple = true }
        }
    }

    private var title: String {
        switch saved {
        case nil: "Drop to save as an asset"
        case 1?: "Saved to Assets"
        case let count?: "\(count) files saved to Assets"
        }
    }

    /// The tray in a soft circle, a glow breathing behind it; on a drop, a tick that
    /// pops in with a ring spreading out from it.
    private var badge: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.35))
                .blur(radius: 10)
                .scaleEffect(saved == nil ? (breathing ? 1.15 : 0.85) : 1.2)
                .opacity(saved == nil ? (breathing ? 0.9 : 0.4) : 0.8)
            if saved != nil {
                Circle()
                    .strokeBorder(tint.opacity(0.7), lineWidth: 1.5)
                    .scaleEffect(ripple ? 2.1 : 1)
                    .opacity(ripple ? 0 : 0.9)
            }
            Circle().fill(tint.opacity(saved == nil ? 0.18 : 0.26))
            Circle().strokeBorder(tint.opacity(0.4), lineWidth: 1)
            Group {
                if saved == nil {
                    Icon("tray.and.arrow.down.fill", size: 18)
                        // A slow nod toward the tray: it is waiting for the drop.
                        .offset(y: lifted ? -1.5 : 1.5)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    Icon("checkmark", size: 18, weight: .bold)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
    }
}
