import ImageIO
import SwiftUI

/// What the island shows while files are dragged over it: a row of tiles hung from
/// the notch, in place of the panel, one for each place the drop can go, drawn as
/// Droppy's are. The shelf holds files for now, to be dragged out again; Assets
/// keeps a copy; Transform converts, makes smaller or zips; Share link uploads; and
/// AirDrop sends. The tile under the pointer lifts; once files land on the shelf or
/// in Assets, the row turns to a tick that says where they went.
struct IslandDropZone: View {
    /// The island's size around it, below the notch strip.
    static let size = CGSize(width: 600, height: 118)
    /// How long the "saved" card stays before the island moves on.
    static let savedDuration: Duration = .milliseconds(1300)

    enum Target: CaseIterable, Equatable {
        case shelf, assets, transform, share, airDrop

        var title: String {
            switch self {
            case .shelf: "Shelf"
            case .assets: "Assets"
            case .transform: "Transform"
            case .share: "Share link"
            case .airDrop: "AirDrop"
            }
        }

        var symbol: String {
            switch self {
            case .shelf: "tray.and.arrow.down.fill"
            case .assets: "Folder01"
            case .transform: "arrow.triangle.2.circlepath"
            case .share: "link"
            case .airDrop: "dot.radiowaves.left.and.right"
            }
        }

        /// Files land somewhere Cue keeps them (and the zone says so), rather than
        /// being sent on.
        var keeps: Bool { self == .shelf || self == .assets }
    }

    /// Where a drop went, and how many files (and which, for their pictures).
    struct Saved: Equatable {
        let count: Int
        let target: Target
        var files: [URL] = []
    }

    /// The tile under the pointer.
    let target: Target
    /// Set once the drop has landed; nil while the drag still hovers.
    let saved: Saved?
    /// A share link can be made (Settings › Sharing is set up).
    var canShare = false

    @State private var lifted = false
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
                HStack(spacing: 6) {
                    ForEach(Target.allCases, id: \.self) { card($0) }
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
        }
        .onChange(of: saved) { _, saved in
            guard saved != nil else { return }
            // Without motion it is simply there; with it the files drop in and the tick pops.
            guard motion else { ripple = true; return }
            ripple = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.68)) { ripple = true }
        }
    }

    /// One place to drop: lifted while the pointer is over it, quiet otherwise.
    private func card(_ place: Target) -> some View {
        let active = place == target
        let off = place == .share && !canShare
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return VStack(spacing: 9) {
            DropGlyph(symbol: place.symbol, badge: place == .share, off: off, dim: place == .shelf, size: 24)
                .frame(height: 36)
                .scaleEffect(active ? 1.08 : 1)
                // A slow nod while the drop is awaited.
                .offset(y: active ? (lifted ? -2.5 : -0.5) : 0)
            Text(off ? "Set up sharing" : place.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(white: off ? 0.45 : (active ? 0.97 : 0.8)))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            shape.fill(LinearGradient(colors: [Color(white: active ? 0.22 : 0.085), Color(white: active ? 0.16 : 0.055)],
                                      startPoint: .top, endPoint: .bottom))
        }
        .overlay(shape.strokeBorder(.white.opacity(active ? 0.13 : 0.035), lineWidth: 1))
        .scaleEffect(active ? 1.02 : 1)
    }

    /// The drop landed: the files themselves drop into a fanned stack, a green tick
    /// pops onto it with a ring spreading out, and it says where they went.
    private func savedCard(_ saved: Saved) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let tint = Self.savedTint
        return HStack(spacing: 16) {
            stack(saved)
                .overlay(alignment: .bottomTrailing) {
                    ZStack {
                        Circle()
                            .strokeBorder(tint.opacity(0.8), lineWidth: 1.5)
                            .scaleEffect(ripple ? 2.4 : 1)
                            .opacity(ripple ? 0 : 0.9)
                        GlossyDisc(symbol: "checkmark", tint: tint, size: 24)
                            .scaleEffect(ripple ? 1 : 0.3)
                    }
                    .frame(width: 24, height: 24)
                    .offset(x: 8, y: 6)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title(saved))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(white: 0.97))
                Text(saved.target == .assets ? "Find \(saved.count == 1 ? "it" : "them") in the Assets tab"
                                             : "Drag \(saved.count == 1 ? "it" : "them") out when you need \(saved.count == 1 ? "it" : "them")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(white: 0.55))
            }
            .offset(x: ripple ? 0 : -6)
            .opacity(ripple ? 1 : 0)
            Spacer(minLength: 0)
            DropGlyph(symbol: saved.target.symbol, dim: saved.target == .shelf, size: 26)
                .opacity(0.45)
                .padding(.trailing, 6)
        }
        .padding(.leading, 22)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            shape.fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                // A trace of green from where the tick is, nothing louder.
                .overlay(alignment: .leading) {
                    Circle().fill(tint.opacity(0.18)).frame(width: 140, height: 140).blur(radius: 40).offset(x: -30)
                }
                .clipShape(shape)
        }
        .overlay(shape.strokeBorder(.white.opacity(0.06), lineWidth: 1))
    }

    /// Up to three of the files, fanned, the last dropped on top.
    private func stack(_ saved: Saved) -> some View {
        let files = Array(saved.files.suffix(3))
        return ZStack {
            if files.isEmpty {
                DropGlyph(symbol: saved.target.symbol, dim: saved.target == .shelf, size: 28)
            }
            ForEach(Array(files.enumerated()), id: \.offset) { index, url in
                let spread = CGFloat(index) - CGFloat(files.count - 1) / 2
                Image(nsImage: Self.picture(of: url))
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .rotationEffect(.degrees(spread * 10))
                    .offset(x: spread * 12, y: ripple ? 0 : -18)
                    .scaleEffect(ripple ? 1 : 0.8)
            }
        }
        .frame(width: 64, height: 64)
    }

    /// A small picture of a file: the image itself, else its icon.
    private static func picture(of url: URL) -> NSImage {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func title(_ saved: Saved) -> String {
        switch (saved.target, saved.count) {
        case (.assets, 1): "Saved to Assets"
        case (.assets, let count): "\(count) files saved to Assets"
        case (_, 1): "On the shelf"
        case (_, let count): "\(count) files on the shelf"
        }
    }
}
