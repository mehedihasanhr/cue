import SwiftUI

/// One tab on a rail of tools: a glyph in a squircle, the chosen one washed in the accent.
///
/// The wash is one shape that travels from tab to tab (`namespace`), so changing tool
/// reads as the highlight moving rather than one tab going dark and another lighting up
/// somewhere else on the rail. The glyph fills in when chosen — `symbolVariant(.fill)` — so
/// the choice is still told apart without colour.
struct StudioIconTab: View {
    let systemImage: String
    let title: String
    let help: String
    let isSelected: Bool
    var isAvailable = true
    /// Shared by every tab on one rail, so the highlight can travel between them.
    let namespace: Namespace.ID
    let action: () -> Void

    static let size: CGFloat = 34

    @State private var isHovering = false

    var body: some View {
        let shape = StudioTheme.squircle(StudioTheme.Radius.tab)

        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .imageScale(.medium)
                .foregroundStyle(ink)
                .frame(width: Self.size, height: Self.size)
                .background {
                    if isSelected {
                        shape
                            .fill(StudioTheme.Surface.fieldHover)
                            .matchedGeometryEffect(id: "tool-tab", in: namespace)
                    } else if isHovering {
                        shape.fill(StudioTheme.Surface.field)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(BarButtonStyle(pressedScale: 0.94))
        .disabled(!isAvailable)
        .onHover { isHovering = $0 && isAvailable }
        .animation(StudioMotion.hover, value: isHovering)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var ink: Color {
        if !isAvailable { return StudioTheme.Palette.textTertiary }
        // White when chosen or under the pointer, a soft grey otherwise — the rail is
        // neutral, so the accent stays for what is set on the picture.
        if isSelected || isHovering { return .white }
        return Color(white: 0.62)
    }
}
