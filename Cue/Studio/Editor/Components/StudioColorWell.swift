import AppKit
import SwiftUI
import TimelineKit

/// A colour well: a squircle swatch that opens the kit's own colour popover.
///
/// The system well is a bezelled button that opens the system colour panel — a floating
/// window with five modes, most of which nobody making a video needs, and which stays open
/// over the work after the choice is made. Here the swatch opens a popover with what is
/// actually asked for nearly every time: a grid of good colours, an opacity slider when the
/// setting has one, and a hex field for the colour somebody copied out of a brand guide.
/// "More Colours…" still opens the system panel, for the rare colour none of those reach —
/// the one place the kit hands over to a system control, because a full colour picker is
/// not worth rebuilding.
///
/// The binding is written on every change, as `ColorPicker`'s is. Callers that coalesce
/// the writes into one undo entry (`InteractionCoalescer`) go on working unchanged.
struct StudioColorWell: View {
    let title: String
    @Binding var selection: Color
    var supportsOpacity = false
    var size: CGFloat = StudioTheme.Height.control

    @State private var isPresented = false
    @State private var isHovering = false
    /// Who the shared colour panel is writing for, when it was opened from here.
    @State private var owner = UUID()
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, selection: Binding<Color>, supportsOpacity: Bool = false, size: CGFloat = StudioTheme.Height.control) {
        self.title = title
        _selection = selection
        self.supportsOpacity = supportsOpacity
        self.size = size
    }

    var body: some View {
        let shape = StudioTheme.squircle(StudioTheme.Radius.swatch)

        Button { isPresented.toggle() } label: {
            ZStack {
                StudioCheckerboard(square: 4)
                selection
            }
            .frame(width: size + 8, height: size)
            .clipShape(shape)
            .overlay { shape.strokeBorder(StudioTheme.Palette.strokeStrong) }
            .overlay {
                // A ring a step outside the swatch on hover and while open, rather than a
                // fill change: the swatch's fill is the colour, and it is not ours to tint.
                StudioTheme.squircle(StudioTheme.Radius.swatch + 2)
                    .strokeBorder(StudioTheme.Palette.strokeStrong, lineWidth: 1.5)
                    .padding(-3)
                    .opacity(isHovering || isPresented ? 1 : 0)
            }
            .contentShape(shape)
        }
        .buttonStyle(StudioPressStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 && isEnabled }
        .animation(StudioMotion.hover, value: isHovering)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            StudioColorPopover(title: title, selection: $selection, supportsOpacity: supportsOpacity,
                               owner: owner) {
                isPresented = false
            }
        }
        // Gone, so the panel stops writing to it: otherwise the next thing selected was styled
        // in this well's panel and the colour landed on the thing that had been selected.
        .onDisappear { ColorPanelBridge.shared.detach(owner) }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(Text(StudioColorPopover.hex(for: selection, includeAlpha: supportsOpacity)))
        .accessibilityHint("Shows colours to choose from")
    }
}

/// What the colour well opens.
struct StudioColorPopover: View {
    let title: String
    @Binding var selection: Color
    let supportsOpacity: Bool
    var owner: UUID?
    let close: () -> Void

    @State private var hexText = ""
    @State private var isHexInvalid = false

    /// Twenty colours that cover what a recording asks for: neutrals for text and frames,
    /// the system hues for highlights, and Cue blue. Ordered as two rows a reader can scan
    /// — light to dark, then round the wheel.
    static let presets: [Color] = [
        .white,
        Color(white: 0.86),
        Color(white: 0.62),
        Color(white: 0.38),
        Color(white: 0.18),
        .black,
        Color(red: 0x0E / 255, green: 0x4F / 255, blue: 0xEC / 255),
        Color(red: 0.98, green: 0.96, blue: 0.90),
        Color(nsColor: .systemRed),
        Color(nsColor: .systemOrange),
        Color(nsColor: .systemYellow),
        Color(nsColor: .systemGreen),
        Color(nsColor: .systemMint),
        Color(nsColor: .systemTeal),
        Color(nsColor: .systemCyan),
        Color(nsColor: .systemBlue),
        Color(nsColor: .systemIndigo),
        Color(nsColor: .systemPurple),
        Color(nsColor: .systemPink),
        Color(nsColor: .systemBrown),
    ]

    private let columns = Array(repeating: GridItem(.fixed(22), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: StudioTheme.FontSize.label, weight: .semibold))
                .foregroundStyle(StudioTheme.Palette.textPrimary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(Self.presets.indices, id: \.self) { index in
                    preset(Self.presets[index])
                }
            }

            if supportsOpacity {
                StudioLabeledSlider("Opacity",
                                    value: opacity,
                                    in: 0...1,
                                    defaultValue: 1,
                                    format: { "\(Int(($0 * 100).rounded()))%" })
            }

            HStack(spacing: 8) {
                StudioTextField("Hex", text: $hexText, isInvalid: isHexInvalid, monospaced: true) {
                    commitHex()
                }
                .frame(width: 104)
                .accessibilityLabel("Hex colour")

                Spacer(minLength: 0)

                Button("More Colours…") { openColorPanel() }
                    .buttonStyle(.studio(.text, size: .small))
                    .help("Open the system colour panel")
            }
        }
        .padding(14)
        .frame(width: 7 * 22 + 6 * 6 + 28)
        .onAppear { hexText = Self.hex(for: selection, includeAlpha: false) }
        .onChange(of: Self.hex(for: selection, includeAlpha: false)) { _, hex in
            // Kept in step with the colour when it changes some other way — a preset, the
            // system panel — but never while somebody is mid-word in the field.
            if HexColor.parse(hexText).map({ HexColor.format($0) }) != hex {
                hexText = hex
                isHexInvalid = false
            }
        }
    }

    private func preset(_ colour: Color) -> some View {
        let isCurrent = Self.hex(for: colour, includeAlpha: false) == Self.hex(for: selection, includeAlpha: false)
        let shape = StudioTheme.squircle(StudioTheme.Radius.swatch)

        return Button {
            // A preset keeps the opacity already set: choosing "red" for a half-clear
            // highlight should give a half-clear red.
            selection = colour.opacity(currentAlpha)
        } label: {
            colour
                .frame(width: 22, height: 22)
                .clipShape(shape)
                .overlay { shape.strokeBorder(StudioTheme.Palette.strokeStrong) }
                .overlay {
                    StudioTheme.squircle(StudioTheme.Radius.swatch + 2)
                        .strokeBorder(StudioTheme.Palette.accent, lineWidth: 2)
                        .padding(-3)
                        .opacity(isCurrent ? 1 : 0)
                }
                .contentShape(shape)
        }
        .buttonStyle(StudioPressStyle())
        .help(Self.hex(for: colour, includeAlpha: false))
        .accessibilityLabel(Self.hex(for: colour, includeAlpha: false))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    // MARK: - Opacity and hex

    private var currentAlpha: Double { Self.components(of: selection).alpha }

    private var opacity: Binding<Double> {
        Binding {
            currentAlpha
        } set: { alpha in
            var rgba = Self.components(of: selection)
            rgba.alpha = alpha
            selection = Self.color(rgba)
        }
    }

    private func commitHex() {
        guard var rgba = HexColor.parse(hexText) else {
            isHexInvalid = true
            return
        }
        isHexInvalid = false
        if !supportsOpacity || hexText.trimmingCharacters(in: .whitespaces).count <= 7 {
            // Six digits say nothing about opacity, so the opacity already set stands.
            rgba.alpha = supportsOpacity ? currentAlpha : 1
        }
        selection = Self.color(rgba)
        hexText = HexColor.format(rgba)
    }

    private func openColorPanel() {
        ColorPanelBridge.shared.attach(to: $selection, supportsOpacity: supportsOpacity, owner: owner)
        close()
    }

    // MARK: - Conversions

    static func components(of colour: Color) -> HexColor.RGBA {
        let ns = NSColor(colour).usingColorSpace(.sRGB) ?? NSColor(colour)
        guard ns.type == .componentBased, ns.numberOfComponents >= 3 else {
            return HexColor.RGBA(red: 0, green: 0, blue: 0)
        }
        return HexColor.RGBA(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                             blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }

    static func color(_ rgba: HexColor.RGBA) -> Color {
        Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }

    static func hex(for colour: Color, includeAlpha: Bool) -> String {
        HexColor.format(components(of: colour), includeAlpha: includeAlpha)
    }
}

/// Connects the system colour panel to one well at a time.
///
/// The panel is a single window shared by the whole app and reports through
/// target–action, which a SwiftUI binding cannot be. This is the target. Whichever well
/// last asked for "More Colours…" is the one the panel writes to, until another asks.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()

    private var write: ((Color) -> Void)?
    private var owner: UUID?

    func attach(to binding: Binding<Color>, supportsOpacity: Bool, owner: UUID? = nil) {
        write = { binding.wrappedValue = $0 }
        self.owner = owner
        let panel = NSColorPanel.shared
        panel.showsAlpha = supportsOpacity
        panel.setTarget(nil)
        panel.color = NSColor(binding.wrappedValue)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    /// Lets go of a well that has gone, and puts the panel away with it: left open, it would
    /// be a colour panel that changes nothing.
    func detach(_ owner: UUID) {
        guard self.owner == owner else { return }
        write = nil
        self.owner = nil
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.orderOut(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        write?(Color(nsColor: sender.color))
    }
}
