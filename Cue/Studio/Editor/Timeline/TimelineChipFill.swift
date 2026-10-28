import SwiftUI
import TimelineKit

/// What a chip on the timeline is drawn as: a solid, faintly top-lit fill with a light
/// edge, and a white outline when it is selected.
///
/// Solid rather than a wash. A tint at a third of its strength was a different colour in
/// light mode and dark, and too weak in both for the white label on it; a solid fill is the
/// same chip everywhere, and the thin light edge is what separates two chips that touch.
struct TimelineChipBackground: View {
    let tint: Color
    let isSelected: Bool
    /// The pointer is over it: lifted a shade, so the chip a click will land on answers
    /// before the click does.
    var isHovered = false
    var radius: CGFloat = TimelineChipBackground.radius
    /// The footage: solid and lit. Everything else on the timeline — zooms, masks, notes,
    /// captions — is a wash of its colour with a fine edge until it is chosen, so the
    /// recording is the one thing the eye lands on and the rest reads as marks on it.
    var isPrimary = false

    /// One radius for every chip, run and lane well, so the strip reads as one family of
    /// shapes rather than one per lane.
    static let radius: CGFloat = 8

    @Environment(\.colorScheme) private var colorScheme

    /// The selection ring: white on a dark strip, dark ink on a light one. A white ring
    /// round a chip on a light strip is a ring round nothing.
    ///
    /// Shared with the sound lane, whose runs are selected the same way and must look it.
    static func ring(in scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.95) : Color(white: 0.08).opacity(0.85)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if isPrimary {
                shape
                    .fill(tint)
                    // Lit from above and shaded below, top to bottom, as the reference's
                    // blocks are: the solid lanes have body the quieter ones do not.
                    .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.18)],
                                                       startPoint: .top, endPoint: .bottom)))
                    .overlay(shape.fill(.white.opacity(isSelected ? 0.1 : (isHovered ? 0.06 : 0))))
                    .overlay(shape.strokeBorder(isSelected ? Self.ring(in: colorScheme) : .white.opacity(0.14),
                                                lineWidth: isSelected ? 2 : 1))
            } else {
                shape
                    .fill(tint.opacity(isSelected ? 0.9 : (isHovered ? 0.4 : 0.24)))
                    .overlay(shape.strokeBorder(isSelected ? Self.ring(in: colorScheme) : tint.opacity(0.42),
                                                lineWidth: isSelected ? 1.5 : 1))
            }
        }
        .animation(StudioMotion.state, value: isHovered)
        .animation(StudioMotion.state, value: isSelected)
    }
}

/// A lane's empty well: the faint track its chips sit in, so a lane with one zoom on it
/// still reads as a lane from end to end.
struct TimelineLaneWell: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: TimelineChipBackground.radius, style: .continuous)
            .fill(Color.white.opacity(0.025))
            .frame(height: height)
    }
}

/// A chip's words, in the most of them that fit.
///
/// Laid out as a ladder rather than as one label behind a visibility gate. It used to be
/// the latter: the whole label was faded out below a fixed width — 48 points, two grab
/// areas and a margin — and drawn at full size above it, for the chip to clip. An auto-zoom
/// at its minimum length on a fitted 34-second take is about 45 points wide, so every one
/// of them fell under the gate and drew as a blank purple block, while the two that happened
/// to be a little longer read "Zoom 1.8×". Nothing about the label needed 48 points; "1.8×"
/// needs 24.
///
/// So a chip offers its words longest first — the name above the details, then the details
/// with the lane's glyph, then the details alone, then the short form — and the first that
/// fits in the room between the grips (`TimelineLayout.labelRoom(forChipWidth:)`) is the one
/// drawn. A chip with no room even for the short form draws nothing, which is honest; one
/// with room for the scale always shows it. `ViewThatFits` does the measuring, so a wider
/// font or a longer number cannot make the rule wrong.
struct TimelineChipLabel<Detail: View, Compact: View>: View {
    let title: String
    let height: CGFloat
    let width: CGFloat
    /// The lane's glyph, drawn before the details when there is room for it. Empty for a
    /// lane whose chips name their own kind.
    var symbol: String = ""
    /// Whether what it says is shortened to fit, with an ellipsis, instead of being offered
    /// whole or not at all.
    ///
    /// The ladder suits a label that is a fact — "1.8×" is either there or not. It does not
    /// suit a sentence: a caption's chip is usually narrower than its words, and the first
    /// few words of a caption are worth more than none of them.
    var truncates = false
    @ViewBuilder let detail: () -> Detail
    /// The least the chip can usefully say — a zoom's scale, a clip's length.
    @ViewBuilder let compact: () -> Compact

    /// The room the words have, once the grips have taken theirs.
    private var room: CGFloat { TimelineLayout.labelRoom(forChipWidth: width) }

    /// Whether there is height for the faint name above the details.
    private var hasTwoLines: Bool { height >= 34 }

    var body: some View {
        Group {
            if truncates {
                sentence
            } else {
                ladder
            }
        }
        .lineLimit(1)
        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        .frame(width: width, height: height)
    }

    /// The longest form that fits, or nothing.
    private var ladder: some View {
        ViewThatFits(in: .horizontal) {
            if hasTwoLines {
                VStack(spacing: 1) {
                    name
                    details(withSymbol: true)
                }
            }
            details(withSymbol: true)
            details(withSymbol: false)
            compact()
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize()
            // Nothing, rather than a cut-off fragment: a chip too narrow for its short form
            // is a coloured mark, and its tooltip still says what it is.
            Color.clear.frame(width: 0, height: 0)
        }
        .frame(width: room)
    }

    /// A sentence shortened to the room, with the name above it while there is space.
    private var sentence: some View {
        VStack(spacing: 1) {
            // The name is never shortened: "C…" names nothing. It goes first when room
            // runs out, and what the chip says keeps the space.
            if hasTwoLines, room >= 56 { name }
            detail()
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .truncationMode(.tail)
        }
        .frame(width: room)
        // A sentence cut down to "E…" is noise, so it gives up sooner than a fact does.
        .opacity(room >= 44 ? 1 : 0)
        .animation(StudioMotion.state, value: room >= 44)
    }

    private var name: some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize()
    }

    private func details(withSymbol: Bool) -> some View {
        HStack(spacing: 5) {
            if withSymbol, !symbol.isEmpty {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            }
            detail()
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.88))
        .fixedSize()
    }
}

extension TimelineChipLabel where Compact == EmptyView {
    /// A label with no short form: the details, or nothing.
    init(title: String, height: CGFloat, width: CGFloat, symbol: String = "",
         truncates: Bool = false, @ViewBuilder detail: @escaping () -> Detail) {
        self.init(title: title, height: height, width: width, symbol: symbol,
                  truncates: truncates, detail: detail, compact: { EmptyView() })
    }
}
