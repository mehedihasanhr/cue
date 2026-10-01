import SwiftUI

/// The kit's button: a squircle in one of five weights.
///
/// A `ButtonStyle` rather than a view of its own, so everything a `Button` already does —
/// its action, `.keyboardShortcut`, `.disabled`, VoiceOver's "button" — comes along
/// unchanged, and any existing `Button` can be moved onto the kit by its style alone.
///
/// The weights say how big a decision the button is:
/// - `primary`: the reason the window is open. Accent fill. One per screen.
/// - `secondary`: an ordinary action. A soft neutral fill.
/// - `ghost`: a tool. Nothing at all until the pointer is over it, so a row of glyphs is a
///   row of glyphs rather than a row of boxes.
/// - `destructive`: removes something. The neutral fill with red ink — a full red slab is
///   for a confirmation, not for a button that sits in a panel all day.
/// - `text`: a word you can press — Reset, Show all — in the accent, with no chrome.
struct StudioButtonStyle: ButtonStyle {
    enum Variant: Sendable {
        case primary, secondary, ghost, destructive, text
    }

    var variant: Variant = .secondary
    var size: StudioTheme.ControlSize = .regular
    /// A square button holding one glyph.
    var isIconOnly = false
    /// For a button that is a switch — the inspector's, a tool that is on. A ghost that is
    /// on keeps a soft accent wash and accent ink, the way a pressed-in toolbar toggle does.
    var isActive = false
    /// Stretches the button to the width it is offered, for a button that is a row.
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        StudioButtonBody(configuration: configuration, style: self)
    }
}

/// The drawn button. A view of its own because hover is state, and a style's `makeBody`
/// cannot hold any.
private struct StudioButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: StudioButtonStyle

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private typealias Palette = StudioTheme.Palette

    var body: some View {
        let size = style.size
        let shape = StudioTheme.squircle(style.isIconOnly && size == .regular ? StudioTheme.Radius.regular : size.radius)

        configuration.label
            .font(.system(size: size.fontSize, weight: style.variant == .primary ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, style.isIconOnly || style.variant == .text ? 0 : size.horizontalPadding)
            .frame(width: style.isIconOnly ? size.height : nil,
                   height: style.variant == .text ? nil : size.height)
            .frame(maxWidth: style.fillsWidth ? .infinity : nil,
                   alignment: style.fillsWidth ? .leading : .center)
            .background { shape.fill(fill) }
            .overlay {
                if style.variant == .secondary || style.variant == .destructive {
                    shape.strokeBorder(Palette.stroke)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            // The press is felt on the way down, and only as a hint of give: a button that
            // shrinks visibly is a toy.
            .scaleEffect(configuration.isPressed && !StudioMotion.reduceMotion ? 0.97 : 1)
            .onHover { isHovering = $0 && isEnabled }
            .animation(StudioMotion.hover, value: isHovering)
            .animation(StudioMotion.press, value: configuration.isPressed)
            .animation(StudioMotion.state, value: style.isActive)
    }

    private var isPressed: Bool { configuration.isPressed && isEnabled }

    private var fill: Color {
        switch style.variant {
        case .primary:
            // An accent fill cannot get "more filled", so hover and press thin it a little
            // instead — enough to see, not enough to read as disabled.
            return Palette.accent.opacity(isPressed ? 0.78 : isHovering ? 0.9 : 1)
        case .secondary, .destructive:
            return isPressed ? Palette.fillPressed : isHovering ? Palette.fillHover : Palette.fill
        case .ghost:
            if style.isActive { return Palette.accentSoft }
            return isPressed ? Palette.fillPressed : isHovering ? Palette.ghostHover : .clear
        case .text:
            return .clear
        }
    }

    private var ink: AnyShapeStyle {
        switch style.variant {
        case .primary:
            return AnyShapeStyle(Palette.onAccent)
        case .secondary:
            return AnyShapeStyle(Palette.textPrimary)
        case .destructive:
            return AnyShapeStyle(Palette.destructive)
        case .ghost:
            if style.isActive { return AnyShapeStyle(Palette.accent) }
            return AnyShapeStyle(isHovering || isPressed ? Palette.textPrimary : Palette.textSecondary)
        case .text:
            return AnyShapeStyle(Palette.accent.opacity(isPressed ? 0.6 : isHovering ? 0.85 : 1))
        }
    }
}

/// A button with a title and, optionally, a glyph before it.
struct StudioButton: View {
    let title: String
    var systemImage: String?
    var variant: StudioButtonStyle.Variant = .secondary
    var size: StudioTheme.ControlSize = .regular
    let action: () -> Void

    init(_ title: String,
         systemImage: String? = nil,
         variant: StudioButtonStyle.Variant = .secondary,
         size: StudioTheme.ControlSize = .regular,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.variant = variant
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: size == .regular ? 6 : 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size.iconSize - 1, weight: .medium))
                }
                Text(title)
            }
        }
        .buttonStyle(StudioButtonStyle(variant: variant, size: size))
    }
}

/// A square button holding one glyph: the title bar's tools, the transport's controls.
///
/// The help text is required rather than optional because a glyph with no words is only
/// usable if hovering it says what it does — and it doubles as the VoiceOver label unless
/// a shorter one is given.
struct StudioIconButton: View {
    let systemImage: String
    let help: String
    var accessibilityName: String?
    var variant: StudioButtonStyle.Variant = .ghost
    var size: StudioTheme.ControlSize = .regular
    var isActive = false
    /// A glyph a touch larger than the size's own — the play button, which is the one the
    /// hand goes to first.
    var iconSize: CGFloat?
    let action: () -> Void

    init(systemImage: String,
         help: String,
         accessibilityName: String? = nil,
         variant: StudioButtonStyle.Variant = .ghost,
         size: StudioTheme.ControlSize = .regular,
         isActive: Bool = false,
         iconSize: CGFloat? = nil,
         action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.accessibilityName = accessibilityName
        self.variant = variant
        self.size = size
        self.isActive = isActive
        self.iconSize = iconSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize ?? size.iconSize, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(StudioButtonStyle(variant: variant, size: size, isIconOnly: true, isActive: isActive))
        .help(help)
        .accessibilityLabel(accessibilityName ?? help)
    }
}

extension ButtonStyle where Self == StudioButtonStyle {
    /// `.buttonStyle(.studio(.ghost, size: .small))`.
    static func studio(_ variant: StudioButtonStyle.Variant = .secondary,
                       size: StudioTheme.ControlSize = .regular,
                       isIconOnly: Bool = false,
                       isActive: Bool = false,
                       fillsWidth: Bool = false) -> StudioButtonStyle {
        StudioButtonStyle(variant: variant, size: size, isIconOnly: isIconOnly,
                          isActive: isActive, fillsWidth: fillsWidth)
    }
}

/// No chrome at all, only the press: for a button whose label *is* its look — a swatch, a
/// disclosure row, a thumbnail. Replaces `.plain`, which gives no sign a press was heard.
struct StudioPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(StudioMotion.press, value: configuration.isPressed)
    }
}
