import SwiftUI

/// The kit's tick box: a small squircle that fills with the accent and a check when it is on.
///
/// For choosing among the lines of a list — the stretches a review sheet offers to speed up,
/// the text it offers to hide — where a switch at the head of every line would make the list
/// read as a column of settings rather than a list of things picked. The system checkbox is
/// a bevelled square with a blue gradient when ticked, the one control in the sheet drawn
/// with a different radius and a different blue.
///
/// A `ToggleStyle`, like the switch, so it is still a `Toggle` underneath: the binding,
/// `.disabled` and VoiceOver's "checkbox, checked" come from the system, and only the
/// drawing is ours.
struct StudioCheckboxStyle: ToggleStyle {
    /// Draws the toggle's own label to the right, the way a checkbox's name sits. Off for a
    /// box at the head of a line whose words are already beside it.
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        StudioCheckboxBody(configuration: configuration, showsLabel: showsLabel)
    }
}

private struct StudioCheckboxBody: View {
    let configuration: ToggleStyleConfiguration
    let showsLabel: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private typealias Palette = StudioTheme.Palette

    /// A touch smaller than the switch's height, so a box beside a line of text sits on it
    /// rather than towering over it.
    private static let side: CGFloat = 14

    var body: some View {
        Button {
            withAnimation(StudioMotion.state) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: StudioTheme.Spacing.compact) {
                box
                if showsLabel {
                    configuration.label
                        .font(.system(size: StudioTheme.FontSize.label))
                        .foregroundStyle(Palette.textPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 && isEnabled }
        .animation(StudioMotion.hover, value: isHovering)
        // Said outright: a button drawn as a box says nothing to VoiceOver about being a
        // checkbox, or about whether it is ticked.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "Checked" : "Unchecked")
    }

    private var box: some View {
        let shape = StudioTheme.squircle(4)
        let isOn = configuration.isOn

        return ZStack {
            shape.fill(isOn ? AnyShapeStyle(Palette.accent)
                            : AnyShapeStyle(isHovering ? Palette.fillHover : Palette.fill))
            // The off box needs the stronger edge: it may be the only thing on the line
            // that says a choice is there to be made.
            shape.strokeBorder(isOn ? Color.clear : Palette.strokeStrong)
            Image(systemName: "checkmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Palette.onAccent)
                .opacity(isOn ? 1 : 0)
                .scaleEffect(isOn || StudioMotion.reduceMotion ? 1 : 0.6)
        }
        .frame(width: Self.side, height: Self.side)
        .animation(StudioMotion.state, value: isOn)
    }
}

extension ToggleStyle where Self == StudioCheckboxStyle {
    /// `.toggleStyle(.studioCheckbox)`.
    static var studioCheckbox: StudioCheckboxStyle { StudioCheckboxStyle() }
}
