import SwiftUI

/// The end of something on the timeline, as a thing you can take hold of.
///
/// One view for all three lanes. They had a copy each, and the copies had already started
/// to differ — different widths, different opacities, and the sound lane's shown at a
/// different moment from the clip lane's. A handle is the same idea everywhere it appears,
/// so it is one thing here.
///
/// **Why it is white.** It was drawn in the lane's own colour, a little brighter than the
/// chip. On the dark green of a sound run that reads; on a saturated purple zoom chip it is
/// very nearly the same colour as the thing it sits on, and the handle disappears. A
/// control has to be legible against whatever it lands on, and the only value that is
/// legible against every tint the lanes use is white. The dark line down its middle is what
/// makes it read as a grip rather than as a gap in the chip, and it is the same vocabulary
/// as the grab bar on a window divider.
///
/// **Why it is narrow and the target is not.** Two 10-point bars on a short chip were most
/// of that chip, and they pushed its own label out of view. The bar is 7 points; what you
/// can grab is up to 14, reaching inwards where there is nothing to cover. Seeing a small
/// control and hitting a larger one is the right way round — the reverse is the one that
/// makes a drag appear to fail.
struct TimelineHandle: View {
    /// Which end of the chip this is.
    let leading: Bool
    let height: CGFloat
    /// The chip's own width, so a short chip is not mostly handles.
    let chipWidth: CGFloat
    /// The chip's corner radius, carried on the handle's outer side so the two line up.
    let radius: CGFloat
    /// Whether this end is being offered — the chip is selected, or the pointer is on it.
    let isVisible: Bool
    let isHovered: Bool
    /// What this end does, for the tooltip and for VoiceOver.
    let label: String

    /// The widest the grabbable area goes.
    static let target: CGFloat = 14

    @Environment(\.colorScheme) private var colorScheme

    /// The same ink as the selection ring the bars sit on — see
    /// `TimelineChipBackground`. White bars on a light strip vanished into the lane, and
    /// took the ends of the ring with them: a selected chip was two dark lines, one
    /// above it and one below.
    private var ink: Color {
        colorScheme == .dark ? .white : Color(white: 0.08)
    }

    private var mark: Color {
        colorScheme == .dark ? .black.opacity(0.38) : .white.opacity(0.7)
    }

    /// Never more than a quarter of the chip: at that point the two bars and the label are
    /// competing for the same few points, and the label loses.
    private var bar: CGFloat { max(3, min(7, chipWidth / 4)) }

    /// Room to grab, reaching inwards from the edge — but never past the middle, or the two
    /// ends would meet and the body would have nowhere left to be dragged from.
    private var grab: CGFloat { max(bar, min(Self.target, chipWidth / 2)) }

    var body: some View {
        Color.clear
            .frame(width: grab, height: height)
            .overlay(alignment: leading ? .leading : .trailing) {
                UnevenRoundedRectangle(topLeadingRadius: leading ? radius : 0,
                                       bottomLeadingRadius: leading ? radius : 0,
                                       bottomTrailingRadius: leading ? 0 : radius,
                                       topTrailingRadius: leading ? 0 : radius,
                                       style: .continuous)
                    .fill(ink.opacity(isVisible ? (isHovered ? 1 : 0.88) : 0))
                    .overlay { grip }
                    .frame(width: bar, height: height)
                    .animation(StudioMotion.state, value: isVisible)
                    .animation(StudioMotion.state, value: isHovered)
            }
            .contentShape(Rectangle())
            .help(label)
            .accessibilityLabel(label)
    }

    /// The line that says "grip", drawn only where the bar is wide enough to hold one
    /// without becoming two thin slivers.
    @ViewBuilder
    private var grip: some View {
        if bar >= 6 {
            Capsule()
                .fill(mark.opacity(isVisible ? 1 : 0))
                .frame(width: 1.5, height: max(6, height * 0.42))
        }
    }
}
