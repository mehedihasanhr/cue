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
/// - **One accent.** The app's accent (Cue blue, from the asset catalog) marks what is
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
                                  dark: NSColor(white: 0x1A / 255, alpha: 1))
        /// The same control under the pointer.
        static let fillHover = dynamic(light: .black.withAlphaComponent(0.08),
                                       dark: NSColor(white: 0x2A / 255, alpha: 1))
        /// The same control with the mouse down on it.
        static let fillPressed = dynamic(light: .black.withAlphaComponent(0.12),
                                         dark: NSColor(white: 0x30 / 255, alpha: 1))
        /// A ghost control under the pointer: lighter than `fillHover`, because there was
        /// nothing there a moment ago and a full fill appearing reads as a flash.
        static let ghostHover = dynamic(light: .black.withAlphaComponent(0.06),
                                        dark: .white.withAlphaComponent(0.08))
        /// The chosen segment, lifted out of its trough: white on light, a lighter grey on
        /// dark — the way a system segmented control draws it, without the bevel.
        static let raised = dynamic(light: .white,
                                    dark: NSColor(white: 0x25 / 255, alpha: 1))
        /// A slider's trough and a switch that is off.
        static let track = dynamic(light: .black.withAlphaComponent(0.10),
                                   dark: .white.withAlphaComponent(0.13))

        /// The one-point edge around a control. Strong enough to find a field on the
        /// panel, faint enough that a column of them is not a grid of boxes.
        static let stroke = dynamic(light: .black.withAlphaComponent(0.09),
                                    dark: .white.withAlphaComponent(0.025))
        /// The edge of something that has to be seen against anything: a colour swatch,
        /// which may be the exact colour of the panel behind it.
        static let strokeStrong = dynamic(light: .black.withAlphaComponent(0.16),
                                          dark: .white.withAlphaComponent(0.18))

        /// A knob: always white, in both appearances, because it is a physical thing on
        /// a track rather than part of the panel.
        static let knob = Color.white
        /// A slider's knob: the accent; `SliderKnob` lifts it a step lighter so it stands
        /// off the filled track.
        static let knobFill = Color.accentColor
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

    // MARK: - The editor's surfaces

    /// The editor window's own colours: flat neutral greys, darkest at the seams.
    ///
    /// The window is a frame of seams round a few panels one step off them, and every
    /// field on a panel one step off again. In the light appearance the panels are white
    /// on grey seams, the canvas a lighter grey well between them, and a field a soft
    /// grey on its white panel. Three steps, nothing between them, so a row,
    /// a panel and a gap are never confused. Each is a pair, one for each appearance:
    /// the editor follows the theme chosen in Settings like every other window.
    enum Surface {
        private static func pair(light: Int, dark: Int) -> Color {
            pair(light: NSColor(white: CGFloat(light) / 255, alpha: 1), dark: dark)
        }

        /// A light value with a breath of blue in it, so the greys sit with Cue blue
        /// rather than beside it; the dark one stays neutral.
        private static func pair(light: NSColor, dark: Int) -> Color {
            Palette.dynamic(light: light, dark: NSColor(white: CGFloat(dark) / 255, alpha: 1))
        }

        private static func cool(_ value: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(value - 3) / 255, green: CGFloat(value - 1) / 255, blue: CGFloat(value + 2) / 255, alpha: 1)
        }

        /// Cue blue (#0E4FEC), the editor's one accent.
        private static let brand = NSColor(srgbRed: 0x0E / 255, green: 0x4F / 255, blue: 0xEC / 255, alpha: 1)

        // The light appearance, back to front: one grey ground the picture stands on and
        // the panels sit in, white panels, and soft grey fields on them.

        /// The seams: the gaps round the canvas and between the columns.
        static let seam = pair(light: cool(0xEC), dark: 0x08)
        /// The title bar: the seam in the dark, white like a panel in the light.
        static let titleBar = pair(light: 0xFF, dark: 0x08)
        /// The panels: the rail, the inspector, the transport and the timeline.
        static let panel = pair(light: 0xFF, dark: 0x13)
        /// A field on a panel: a row, a slider's trough, a button at rest.
        static let field = pair(light: cool(0xF3), dark: 0x1A)
        /// The same field under the pointer.
        static let fieldHover = pair(light: cool(0xEB), dark: 0x22)
        /// A field pressed or lit: a step beyond the hover.
        static let fieldPressed = pair(light: cool(0xE2), dark: 0x33)
        /// A bar button at rest — a shade under a field, because it sits on the transport
        /// rather than in a row.
        static let control = pair(light: cool(0xF3), dark: 0x20)
        /// The part of a scrub slider that is set: grey in the dark, a wash of Cue blue
        /// in the light, where a grey on grey said nothing.
        static let scrubFill = Palette.dynamic(light: brand.withAlphaComponent(0.13),
                                               dark: NSColor(white: 0x45 / 255, alpha: 1))
        /// The bar a scrub slider's value ends at.
        static let scrubMark = Palette.dynamic(light: brand, dark: NSColor(white: 0xF5 / 255, alpha: 1))
        /// The part of the timeline past the end of the edit.
        static let beyondEnd = pair(light: cool(0xF7), dark: 0x1F)
        /// Behind the picture: the canvas the frame sits in. In the light the same grey as
        /// the seams, so the frame stands on the window's own ground rather than in a well
        /// inside it — one step fewer between the picture and the panels.
        static let canvas = pair(light: cool(0xEC), dark: 0x08)
        /// A small floating bar over the canvas.
        static let floating = pair(light: 0xFF, dark: 0x1D)
        /// The playhead and the timeline scale's fill.
        static let playhead = Color(red: 0x0C / 255, green: 0x7C / 255, blue: 0xDD / 255)
        /// The footage on the timeline: a warm amber, the reference's, so the recording is
        /// the one warm thing in a window of cool greys and Cue blue.
        static let clip = Color(red: 0xBC / 255, green: 0x84 / 255, blue: 0x30 / 255)
        /// The one strong button in the window: Export.
        static let primaryButton = pair(light: 0x1D, dark: 0xF3)
        /// The words on it.
        static let onPrimary = pair(light: 0xFA, dark: 0x12)

        /// Ink on the panels, strongest first: a title or a chosen icon, a control's
        /// glyph, a label in a row, a row's value, a scale's marks.
        static let ink = pair(light: 0x1D, dark: 0xF5)
        static let inkSoft = pair(light: 0x3C, dark: 0xD6)
        static let label = pair(light: 0x4A, dark: 0xB3)
        static let value = pair(light: 0x76, dark: 0x8A)
        static let inkFaint = pair(light: 0x9A, dark: 0x66)
        /// The one-point edge round a field or a floating bar.
        static let hairline = Palette.dynamic(light: .black.withAlphaComponent(0.09),
                                              dark: .white.withAlphaComponent(0.07))
        /// A faint wash on a panel: a well, an unlit chip.
        static let wash = Palette.dynamic(light: .black.withAlphaComponent(0.05),
                                          dark: .white.withAlphaComponent(0.06))
    }

    // MARK: - The recorder

    /// The recorder's colours and metrics: the bar, the target overlay and the island.
    ///
    /// Studio is its own target and cannot reach the host app's `Glass.swift`, so the
    /// pieces the bar and the target overlay both need are spelled out here, with the
    /// editor's, rather than inlined twice.
    enum Recorder {
        /// Cue blue (#0E4FEC), the fill of the app icon and the app's one accent.
        static let brand = Color(red: 0x0E / 255, green: 0x4F / 255, blue: 0xEC / 255)

        /// The bar's glass: #292929, translucent enough that the page behind shows through.
        static let barGlass = Color(red: 0x29 / 255, green: 0x29 / 255, blue: 0x29 / 255).opacity(0.64)

        static let barRadius: CGFloat = 18
        static let barHeight: CGFloat = 64

        /// Three weights of white: what is chosen, what is on offer, what cannot be had.
        static let chosen = Color.white
        static let offered = Color.white.opacity(0.58)
        static let unavailable = Color.white.opacity(0.3)
    }

    // MARK: - The timeline

    /// The timeline's own colours, for the lanes that are chips rather than waveforms.
    ///
    /// Picked rather than taken from the system palette: `.orange` and `.purple` are tuned
    /// to be tints, and filled solid across a whole lane they read as a warning and as a
    /// toy. An amber for the footage and Cue blue for zooms, as the reference pairs them,
    /// are two ideas at a strength a chip can carry edge to edge, with white on top of it.
    enum Lane {
        static let clip = Surface.clip
        /// Cue blue, as the reference colours its zooms in its own accent: a zoom is the
        /// thing the editor adds, and it wears the editor's colour.
        static let zoom = Recorder.brand
        /// The pointer's lane: a quiet slate, for the same reason.
        static let pointer = Color(red: 0.56, green: 0.6, blue: 0.68)
    }

    // MARK: - The editor's columns

    /// How wide the editor's columns are.
    ///
    /// The tool tabs and the settings sit together at the right of the window, tabs on the
    /// inside edge next to the picture, so choosing a tool and seeing what it opened happen
    /// in one place rather than at opposite ends of the window.
    enum Columns {
        /// The column of tool tabs beside the settings.
        static let tabs: CGFloat = SidebarMetrics.railWidth
        /// The settings column: a slider's track and its name need about three hundred
        /// points.
        static let inspector: CGFloat = 340
    }

    // MARK: - Shape

    enum Radius {
        /// A regular control.
        static let regular: CGFloat = 8
        /// A small control: the same height as a regular one, so the same corner.
        static let small: CGFloat = 8
        /// A segment inside a trough, or a row inside a menu: the trough's radius less the
        /// inset, so the inner and outer corners run parallel.
        static let inner: CGFloat = 5
        /// A tool tab on the rail.
        static let tab: CGFloat = 9
        /// A popover's content and a large swatch.
        static let panel: CGFloat = 10
        /// The settings column, a card floating on the window's ground.
        static let card: CGFloat = 14
        /// A colour chip in a grid.
        static let swatch: CGFloat = 6
    }

    /// A squircle: the continuous-corner rounded rectangle every control is cut from.
    static func squircle(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    // MARK: - Size

    enum Height {
        /// Every control that holds a value or does something — a button, a text field, a
        /// pop-up, a stepper's buttons, a segmented trough — whether it sits in a bar or a
        /// panel row. One height, so a field and the button beside or below it line up.
        static let control: CGFloat = 28
        /// A button in a bar, the Export button, a tool tab's hit area.
        static let regular: CGFloat = control
        /// Anything in a panel row: a pop-up field, a small button, a stepper.
        static let small: CGFloat = control
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
