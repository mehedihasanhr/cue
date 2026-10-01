import SwiftUI

/// The kit's on-and-off: a small squircle pill with a knob that slides.
///
/// A `ToggleStyle`, so it is still a `Toggle` underneath — the binding, `.disabled`, and
/// VoiceOver's "switch button, on" all come from the system — and only the drawing is
/// ours. The system switch at its small size is a raised, gradient-lit capsule that is the
/// heaviest thing in a row of flat controls; this one is the same flat fill as everything
/// around it, and the accent when it is on.
struct StudioSwitchStyle: ToggleStyle {
    /// Draws the toggle's own label to the left. Off for a switch that sits at the end of
    /// a row whose name is already written.
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        StudioSwitchBody(configuration: configuration, showsLabel: showsLabel)
    }
}

private struct StudioSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    let showsLabel: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @State private var isPressed = false

    private typealias Palette = StudioTheme.Palette

    var body: some View {
        HStack(spacing: StudioTheme.Spacing.regular) {
            if showsLabel {
                configuration.label
                    .font(.system(size: StudioTheme.FontSize.label))
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 0)
            }
            pill
        }
        .opacity(isEnabled ? 1 : 0.45)
        // Said outright rather than left to the style: the pill is drawn from shapes and a
        // gesture, and none of those tells VoiceOver it is a switch or what it is set to.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction {
            guard isEnabled else { return }
            configuration.isOn.toggle()
        }
    }

    private var pill: some View {
        let width = StudioTheme.Height.switchWidth
        let height = StudioTheme.Height.switchTrack
        let inset: CGFloat = 2
        let knob = height - inset * 2
        // Corners a little tighter than a capsule's, so the switch is the same family of
        // shape as the fields beside it rather than the one round thing in the row.
        let shape = StudioTheme.squircle(height * 0.42)
        let knobShape = StudioTheme.squircle(knob * 0.42)
        let isOn = configuration.isOn

        return ZStack(alignment: isOn ? .trailing : .leading) {
            shape.fill(isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(isHovering ? Palette.fillPressed : Palette.track))
            knobShape
                .fill(Palette.knob)
                .shadow(color: Palette.knobShadow, radius: 1, y: 0.5)
                // Stretches a little under the mouse, the way the system's does — the one
                // sign the press was heard before the knob has gone anywhere.
                .frame(width: knob + (isPressed && !StudioMotion.reduceMotion ? 3 : 0), height: knob)
                .padding(inset)
        }
        .frame(width: width, height: height)
        .contentShape(shape)
        .onHover { isHovering = $0 && isEnabled }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if isEnabled { isPressed = true } }
                .onEnded { gesture in
                    isPressed = false
                    // A press that wandered off the switch before letting go is a change
                    // of mind, as it is for a button.
                    let inside = CGRect(x: -4, y: -4, width: width + 8, height: height + 8)
                        .contains(gesture.location)
                    guard isEnabled, inside else { return }
                    withAnimation(StudioMotion.selection) { configuration.isOn.toggle() }
                }
        )
        .animation(StudioMotion.hover, value: isHovering)
        .animation(StudioMotion.press, value: isPressed)
        .animation(StudioMotion.selection, value: isOn)
    }
}

/// A switch on its own, for the end of a row whose name is already written beside it.
struct StudioSwitch: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(StudioSwitchStyle(showsLabel: false))
            .fixedSize()
            .accessibilityLabel(title)
    }
}

extension ToggleStyle where Self == StudioSwitchStyle {
    /// `.toggleStyle(.studio)`.
    static var studio: StudioSwitchStyle { StudioSwitchStyle() }
}
