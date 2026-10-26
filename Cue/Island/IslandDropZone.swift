import SwiftUI

/// What the island shows while files are dragged over it: two small cards hung
/// from the notch, in place of the panel, one for each place the drop can go. The
/// shelf holds files for now, to be dragged out again; Assets keeps a copy. The card
/// under the pointer is alive (its dashed edge runs, a glow breathes behind its
/// icon); once the files land, one card turns to a tick and says where they went.
struct IslandDropZone: View {
    /// The island's size around it, below the notch strip.
    static let size = CGSize(width: 440, height: 96)
    /// How long the "saved" card stays before the island moves on.
    static let savedDuration: Duration = .milliseconds(1300)

    enum Target: Equatable {
        case shelf, assets

        var title: String {
            switch self {
            case .shelf: "Shelf"
            case .assets: "Assets"
            }
        }

        var subtitle: String {
            switch self {
            case .shelf: "Hold it here for now"
            case .assets: "Keep a copy in Cue"
            }
        }

        var symbol: String {
            switch self {
            case .shelf: "tray.and.arrow.down.fill"
            case .assets: "Folder01"
            }
        }
    }

    /// Where a drop went, and how many files.
    struct Saved: Equatable {
        let count: Int
        let target: Target
    }

    /// The card under the pointer.
    let target: Target
    /// Set once the drop has landed; nil while the drag still hovers.
    let saved: Saved?

    @State private var lifted = false
    @State private var breathing = false
    @State private var dashPhase: CGFloat = 0
    @State private var ripple = false

    private static let savedTint = Color(red: 0.36, green: 0.82, blue: 0.48)
    private static let radius: CGFloat = 18
    private var motion: Bool { !IslandView.reduceMotion }

    var body: some View {
        Group {
            if let saved {
                savedCard(saved)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else {
                HStack(spacing: 8) {
                    card(.shelf)
                    card(.assets)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
        .animation(IslandMotion.bouncy(0.35, damping: 0.7), value: saved)
        .animation(.easeOut(duration: 0.15), value: target)
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

    /// One place to drop: lit and running while the pointer is over it, quiet otherwise.
    private func card(_ place: Target) -> some View {
        let active = place == target
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let tint = IslandStyle.accent
        return HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.35))
                    .blur(radius: 9)
                    .scaleEffect(breathing ? 1.15 : 0.85)
                    .opacity(active ? (breathing ? 0.9 : 0.4) : 0)
                Circle().fill(active ? tint.opacity(0.2) : .white.opacity(0.06))
                Circle().strokeBorder(active ? tint.opacity(0.45) : .white.opacity(0.08), lineWidth: 1)
                Icon(place.symbol, size: 15)
                    .foregroundStyle(.white.opacity(active ? 1 : 0.55))
                    // A slow nod toward the tray: it is waiting for the drop.
                    .offset(y: active ? (lifted ? -1.5 : 1.5) : 0)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(active ? 1 : 0.6))
                Text(place.subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(active ? 0.5 : 0.3))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(active ? tint.opacity(0.07) : .white.opacity(0.03), in: shape)
        .overlay {
            if active {
                // The edge runs while the drag hovers: the card is waiting for it.
                shape.strokeBorder(tint.opacity(0.6), style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [5, 4], dashPhase: dashPhase))
            } else {
                shape.strokeBorder(.white.opacity(0.07), lineWidth: 1)
            }
        }
        .scaleEffect(active ? 1 : 0.97)
    }

    /// The drop landed: a tick that pops in with a ring spreading out from it, and
    /// where the files went.
    private func savedCard(_ saved: Saved) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let tint = Self.savedTint
        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.35))
                    .blur(radius: 10)
                    .scaleEffect(1.2)
                    .opacity(0.8)
                Circle()
                    .strokeBorder(tint.opacity(0.7), lineWidth: 1.5)
                    .scaleEffect(ripple ? 2.1 : 1)
                    .opacity(ripple ? 0 : 0.9)
                Circle().fill(tint.opacity(0.26))
                Circle().strokeBorder(tint.opacity(0.4), lineWidth: 1)
                Icon("checkmark", size: 18, weight: .bold)
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(saved))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(saved.target == .shelf ? "Drag it out when you need it" : "Find it in the Assets tab")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tint.opacity(0.1), in: shape)
        .overlay(shape.strokeBorder(tint.opacity(0.55), lineWidth: 1))
        .scaleEffect(ripple ? 1.015 : 1)
    }

    private static func title(_ saved: Saved) -> String {
        switch (saved.target, saved.count) {
        case (.shelf, 1): "On the shelf"
        case (.shelf, let count): "\(count) files on the shelf"
        case (.assets, 1): "Saved to Assets"
        case (.assets, let count): "\(count) files saved to Assets"
        }
    }
}
