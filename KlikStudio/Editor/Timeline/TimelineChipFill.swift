import SwiftUI

extension Color {
    /// A timeline chip's fill, strong enough for the white on top of it in either appearance.
    ///
    /// The lanes were tuned in dark mode, where a tint at a third of its strength over a
    /// near-black lane is a clear, saturated colour. Over a light lane the same wash comes
    /// out as a pastel, and every white thing drawn on it — the badges, the handles, the
    /// waveform — all but disappears: a timeline of beige and lilac with nothing legible on
    /// it. In light mode the chip is filled closer to the tint itself, so the white reads
    /// the same in both.
    ///
    /// `darkOpacity` is the strength the chip has always had in dark mode; the ordering it
    /// encodes — selected over resting — is kept in light mode too.
    func chipFill(_ darkOpacity: Double, in scheme: ColorScheme) -> Color {
        scheme == .dark ? opacity(darkOpacity) : opacity(min(1, 0.5 + darkOpacity * 0.55))
    }
}

/// The timeline's own colours, for the lanes that are chips rather than waveforms.
///
/// Picked rather than taken from the system palette: `.orange` and `.purple` are tuned to
/// be tints, and filled solid across a whole lane they read as a warning and as a toy.
/// A warmer amber for the footage and a blue-leaning violet for zooms are the same two ideas
/// at a strength a chip can carry edge to edge, with white on top of it, in either appearance.
enum TimelinePalette {
    static let clip = Color(red: 0.86, green: 0.55, blue: 0.12)
    static let zoom = Color(red: 0.42, green: 0.31, blue: 0.96)
}

/// What a chip on the timeline is drawn as: a solid, faintly top-lit fill with a light
/// edge, and a white outline when it is selected.
///
/// Solid rather than a wash. A tint at a third of its strength was a different colour in
/// light mode and dark, and too weak in both for the white label on it; a solid fill is the
/// same chip everywhere, and the thin light edge is what separates two chips that touch.
struct TimelineChipBackground: View {
    let tint: Color
    let isSelected: Bool
    var radius: CGFloat = TimelineChipBackground.radius

    static let radius: CGFloat = 8

    @Environment(\.colorScheme) private var colorScheme

    /// The selection ring: white on a dark strip, dark ink on a light one. A white ring
    /// round a chip on a light strip is a ring round nothing.
    private var ring: Color {
        colorScheme == .dark ? .white.opacity(0.95) : Color(white: 0.08).opacity(0.85)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(tint.gradient)
            .overlay(shape.fill(.white.opacity(isSelected ? 0.1 : 0)))
            .overlay(shape.strokeBorder(isSelected ? ring : .white.opacity(0.22),
                                        lineWidth: isSelected ? 2 : 1))
    }
}

/// A chip's words: the faint name of what it is, and under it what it says.
///
/// Centred, as a player's timeline centres them. The name goes when the chip is too short
/// to hold two lines, and the whole label fades when the chip is too narrow to hold it —
/// faded rather than removed, because this changes mid-drag and a label blinking out under
/// the pointer reads as something breaking.
struct TimelineChipLabel<Detail: View>: View {
    let title: String
    let height: CGFloat
    let width: CGFloat
    var minimumWidth: CGFloat = 60
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        VStack(spacing: 1) {
            if height >= 34 {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            detail()
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .fixedSize()
        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        .frame(width: width, height: height)
        .opacity(width > minimumWidth ? 1 : 0)
        .animation(StudioMotion.state, value: width > minimumWidth)
    }
}
