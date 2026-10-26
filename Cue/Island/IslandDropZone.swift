import SwiftUI

/// What the island shows while files are dragged over it: a small card hung from the
/// notch, in place of the panel, saying where the drop goes.
struct IslandDropZone: View {
    /// The island's size around it, below the notch strip.
    static let size = CGSize(width: 360, height: 92)

    @State private var lifted = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(IslandStyle.accent.opacity(0.18))
                Circle().strokeBorder(IslandStyle.accent.opacity(0.35), lineWidth: 1)
                Icon("tray.and.arrow.down.fill", size: 18)
                    .foregroundStyle(.white)
                    // A slow nod toward the tray: it is waiting for the drop.
                    .offset(y: lifted ? -1.5 : 1.5)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Drop to save as an asset")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Images and files are kept in Assets")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(IslandStyle.accent.opacity(0.55), style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
        .onAppear {
            guard !IslandView.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lifted = true }
        }
    }
}
