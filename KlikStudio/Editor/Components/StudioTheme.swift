import AppKit
import SwiftUI

/// Every number and colour the editor's own controls are drawn from.
///
/// The editor draws its controls itself — buttons, sliders, switches, menus, colour wells —
/// because the system's are built for a settings window: a raised bezel, a large knob, a
/// blue-gradient pop-up, each in its own idea of a size. Nine of those in a column read as a
/// form; the work in the middle of the window should be the loudest thing on screen. A kit
/// of hand-drawn controls only stays one kit if they all ask the same place for their
/// sizes and colours, which is this.
///
/// The rules the tokens encode:
/// - **Squircles.** Every rounded thing is a continuous-corner rounded rectangle. A plain
///   circular corner beside a continuous one is visibly a different shape at these sizes.
/// - **One accent.** The app's accent (Klik blue, from the asset catalog) marks what is
///   chosen, set or primary. Nothing else is coloured, so colour always means something.
/// - **Soft neutrals.** Fills are the label colour at a few percent, so they are the same
///   *amount* of fill in light and dark rather than one appearance's grey pasted into the
///   other.
/// - **Hairlines, not shadows.** A control is told apart from the panel by a fill and a
///   one-point edge. The only shadow in the kit is the faint one under a knob, which is
///   the one part meant to look like it sits on top.
enum StudioTheme {
    // MARK: - Colour

    enum Palette {
        /// The one accent. `accentColor` rather than a literal so a build that changes the
        /// asset catalog changes every control with it.
        static let accent = Color.accentColor
        /// The accent as a wash: the chosen tab, a selected row in a menu.
        static let accentSoft = Color.accentColor.opacity(0.16)
        /// The accent at the strength a focus ring wants: present, not shouting.
        static let focusRing = Color.accentColor.opacity(0.55)
        /// What goes on top of an accent fill.
        static let onAccent = Color.white

        static let destructive = Color(nsColor: .systemRed)

        /// Ink, in three weights. The system's label colours, so they follow Increase
        /// Contrast and the appearance without help.
        static let textPrimary = Color(nsColor: .labelColor)
        static let textSecondary = Color(nsColor: .secondaryLabelColor)
        static let textTertiary = Color(nsColor: .tertiaryLabelColor)

        /// A control at rest: a field, a secondary button, the trough of a segmented row.
        static let fill = dynamic(light: .black.withAlphaComponent(0.05),
                                  dark: .white.withAlphaComponent(0.07))
        /// The same control under the pointer.
        static let fillHover = dynamic(light: .black.withAlphaComponent(0.08),
                                       dark: .white.withAlphaComponent(0.11))
        /// The same control with the mouse down on it.
        static let fillPressed = dynamic(light: .black.withAlphaComponent(0.12),
                                         dark: .white.withAlphaComponent(0.15))
        /// A ghost control under the pointer: lighter than `fillHover`, because there was
        /// nothing there a moment ago and a full fill appearing reads as a flash.
        static let ghostHover = dynamic(light: .black.withAlphaComponent(0.06),
                                        dark: .white.withAlphaComponent(0.08))
        /// The chosen segment, lifted out of its trough: white on light, a lighter grey on
        /// dark — the way a system segmented control draws it, without the bevel.
        static let raised = dynamic(light: .white,
                                    dark: .white.withAlphaComponent(0.16))
        /// A slider's trough and a switch that is off.
        static let track = dynamic(light: .black.withAlphaComponent(0.10),
                                   dark: .white.withAlphaComponent(0.13))

        /// The one-point edge around a control. Strong enough to find a field on the
        /// panel, faint enough that a column of them is not a grid of boxes.
        static let stroke = dynamic(light: .black.withAlphaComponent(0.09),
                                    dark: .white.withAlphaComponent(0.08))
        /// The edge of something that has to be seen against anything: a colour swatch,
        /// which may be the exact colour of the panel behind it.
        static let strokeStrong = dynamic(light: .black.withAlphaComponent(0.16),
                                          dark: .white.withAlphaComponent(0.18))

        /// A knob: always white, in both appearances, because it is a physical thing on
        /// a track rather than part of the panel.
        static let knob = Color.white
        static let knobEdge = Color.black.opacity(0.14)
        static let knobShadow = Color.black.opacity(0.22)

        /// The surface of a popover's list, a shade off the popover's own background so a
        /// hovered row has something to sit on.
        static let menuHover = dynamic(light: .black.withAlphaComponent(0.06),
                                       dark: .white.withAlphaComponent(0.09))

        /// A colour that is one thing in the light appearance and another in the dark.
        ///
        /// Resolved by AppKit at draw time, so a view does not need to read the colour
        /// scheme — and so the right one is drawn inside a popover, which can have a
        /// different appearance from the window that opened it.
        static func dynamic(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                                            .accessibilityHighContrastVibrantDark]) != nil ? dark : light
            })
        }
    }

    // MARK: - Shape

    enum Radius {
        /// A regular (28-point) control.
        static let regular: CGFloat = 8
        /// A small (24-point) control.
        static let small: CGFloat = 7
        /// A segment inside a trough, or a row inside a menu: the trough's radius less the
        /// inset, so the inner and outer corners run parallel.
        static let inner: CGFloat = 5
        /// A tool tab on the rail.
        static let tab: CGFloat = 9
        /// A popover's content and a large swatch.
        static let panel: CGFloat = 10
        /// A colour chip in a grid.
        static let swatch: CGFloat = 6
    }

    /// A squircle: the continuous-corner rounded rectangle every control is cut from.
    static func squircle(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    // MARK: - Size

    enum Height {
        /// A button in a bar, the Export button, a tool tab's hit area.
        static let regular: CGFloat = 28
        /// Anything in a panel row: a pop-up field, a small button, a stepper.
        static let small: CGFloat = 24
        /// A switch.
        static let switchTrack: CGFloat = 16
        static let switchWidth: CGFloat = 28
    }

    /// A control's size, for the controls that come in two.
    enum ControlSize: Sendable {
        case regular, small

        var height: CGFloat { self == .regular ? Height.regular : Height.small }
        var radius: CGFloat { self == .regular ? Radius.regular : Radius.small }
        var fontSize: CGFloat { self == .regular ? FontSize.button : FontSize.label }
        var iconSize: CGFloat { self == .regular ? 13 : 11.5 }
        var horizontalPadding: CGFloat { self == .regular ? 12 : 9 }
    }

    // MARK: - Type

    enum FontSize {
        /// A section's heading.
        static let heading: CGFloat = 12
        /// A control's name, a field's text.
        static let label: CGFloat = 12
        /// A button's title in a bar.
        static let button: CGFloat = 12
        /// A slider's readout and other small facts.
        static let value: CGFloat = 11
        /// A note, a tooltip-sized aside.
        static let caption: CGFloat = 11
    }

    // MARK: - Space

    /// The gaps, aligned with the panel's own (`SidebarSpacing`) so a control's insides
    /// and the column it sits in step in the same increments.
    enum Spacing {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 4
        static let compact: CGFloat = 6
        static let regular: CGFloat = 8
        static let withinControl = SidebarSpacing.withinControl
        static let betweenControls = SidebarSpacing.betweenControls
        static let inset = SidebarMetrics.contentInset
    }
}

// MARK: - Shared pieces

extension View {
    /// The kit's focus ring: a two-point accent outline just outside the shape, drawn only
    /// while `isFocused`. The system's ring is a blurred halo tuned for a bezelled control,
    /// and around a squircle it is a rounded rectangle of a different radius.
    func studioFocusRing(_ isFocused: Bool, radius: CGFloat) -> some View {
        overlay {
            StudioTheme.squircle(radius + 2)
                .strokeBorder(StudioTheme.Palette.focusRing, lineWidth: 2)
                .padding(-2)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(StudioMotion.hover, value: isFocused)
    }
}

/// A checkerboard, under anything that can be partly transparent, so a colour at half
/// opacity looks like half a colour rather than a paler one.
struct StudioCheckerboard: View {
    var square: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let columns = Int((size.width / square).rounded(.up))
            let rows = Int((size.height / square).rounded(.up))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square,
                                      width: square, height: square)
                    context.fill(Path(rect), with: .color(Color(white: 0.82)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
