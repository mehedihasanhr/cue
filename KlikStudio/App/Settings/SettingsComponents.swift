import AppKit
import SwiftUI

// The building blocks of the Settings window, copied from Klik's own (`SettingsRoot.swift`
// and `SettingsView.swift` in the Klik target) so the two apps' settings read as one
// product. Copied rather than shared because Klik Studio is its own target and links none
// of Klik — and the add-on must keep working with whichever Klik is installed beside it.
// Where the two differ it is only in what Studio has instead: its own brand colour, its
// own app icon.

// MARK: - Colours and type

/// The window's colours, measured off Klik's settings: a near-black page, a card a shade
/// lighter with the desktop's tint, fills as fractions of the primary colour — so each has
/// a light counterpart without a second table.
enum SettingsPalette {
    /// Over the glass: almost opaque, so the desktop only just shows.
    static let page = Color(nsColor: dynamic(dark: NSColor(red: 0x10 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 0.94),
                                             light: NSColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255, alpha: 0.9)))
    /// Over the sidebar card's glass, which is left to show more of the desktop.
    static let card = Color(nsColor: dynamic(dark: NSColor(red: 0x0F / 255, green: 0x12 / 255, blue: 0x13 / 255, alpha: 0.79),
                                             light: NSColor(white: 1, alpha: 0.6)))
    static let field = Color.primary.opacity(0.11)
    static let selectedRow = Color.primary.opacity(0.12)
    static let hoveredRow = Color.primary.opacity(0.06)
    static let pill = Color.primary.opacity(0.08)
    static let edge = Color.primary.opacity(0.07)
    /// The cards on a page and the lines between their rows.
    static let cardFill = Color.primary.opacity(0.03)
    static let hairline = Color.primary.opacity(0.05)

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

/// The type hierarchy of a page: a group's title, a row's title, what it does, and a
/// note under a card.
enum SettingsFont {
    static let title = Font.system(size: 14)
    static let item = Font.system(size: 13)
    static let sub = Font.system(size: 11)
    static let note = Font.system(size: 9)
}

// MARK: - Glass

/// The desktop behind the window, blurred — the base of every glass surface.
struct GlassMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// A rounded pane of glass: blurred desktop, a light tint, a grain of noise, and an edge
/// that catches the light at the top-left.
struct GlassCard: View {
    var radius: CGFloat

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    private var edge: LinearGradient {
        LinearGradient(colors: [Color.primary.opacity(0.11), Color.primary.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            GlassMaterial()
            SettingsPalette.card
            NoiseTexture.image
                .resizable(resizingMode: .tile)
                .opacity(0.008)
                .blendMode(.plusLighter)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(edge, lineWidth: 1))
    }
}

/// A small tile of random grey, made once; tiled over glass it reads as grain.
enum NoiseTexture {
    static let image: Image = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side)
        var state: UInt32 = 0x9E37_79B9
        for i in pixels.indices {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            pixels[i] = UInt8(truncatingIfNeeded: state)
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            return Image(systemName: "square")
        }
        return Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: side, height: side)))
    }()
}

// MARK: - Tiles

/// A white SF Symbol on a tinted rounded square — a page in the sidebar, or a row that is
/// about a thing.
struct SymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size / 2, weight: size >= 48 ? .semibold : .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }
}

/// The app's own icon, the size of a `SymbolTile`, for About.
///
/// The icon the running app has rather than a drawing of it, so it is always the one in
/// the Finder — a development build's included.
struct AppIconTile: View {
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            // The icon has its own rounded shape inside a margin; a little larger so it
            // lines up with the symbol tiles' edges.
            .frame(width: size, height: size)
            .scaleEffect(1.12)
            .accessibilityHidden(true)
    }
}

// MARK: - Page chrome

/// A settings page: groups of rows, top to bottom, starting under the history pill. Every
/// pane builds on this so the pages all look alike. A row's subtitle is for what its
/// title cannot say alone.
struct SettingsPane<Content: View>: View {
    let section: StudioSettingsSection
    @ViewBuilder let content: Content

    init(_ section: StudioSettingsSection, @ViewBuilder content: () -> Content) {
        self.section = section
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 64)
            .padding(.bottom, 24)
        }
        .accessibilityLabel("\(section.title) settings")
    }
}

/// A card of rows, with a plain title above.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(SettingsFont.title)
                    .padding(.leading, 12)
                    .dimmedWhenDisabled()
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                content
            }
            // Each row ends in a hairline; the last one falls outside the card.
            .padding(.bottom, -1)
            .background(SettingsPalette.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// Faded while disabled, the way a disabled control is — for the words beside one.
struct DimmedWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.4)
    }
}

extension View {
    func dimmedWhenDisabled() -> some View { modifier(DimmedWhenDisabled()) }
}

/// One row of a card: anything, padded, with a hairline under it.
struct SettingsCell<Content: View>: View {
    var vertical: CGFloat = 12
    @ViewBuilder let content: Content

    init(vertical: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.vertical = vertical
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, vertical)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(SettingsPalette.hairline).frame(height: 1).padding(.horizontal, 12)
        }
    }
}

/// A labelled row: the title and what it does on the left, the control on the right — and
/// a tile before the title when the row is about a thing.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color = .blue
    @ViewBuilder let control: Control

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color = .blue, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.control = control()
    }

    var body: some View {
        SettingsCell(vertical: subtitle == nil ? 12 : 10) {
            HStack(spacing: 14) {
                if let symbol {
                    SymbolTile(symbol: symbol, tint: tint).dimmedWhenDisabled()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SettingsFont.item)
                    if let subtitle {
                        Text(subtitle)
                            .font(SettingsFont.sub)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .dimmedWhenDisabled()
                Spacer(minLength: 16)
                control
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension SettingsRow where Control == EmptyView {
    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color = .blue) {
        self.init(title, subtitle: subtitle, symbol: symbol, tint: tint) { EmptyView() }
    }
}

// MARK: - Common rows

/// A row with a switch on the right — the most common row there is, so it gets a name.
///
/// The switch carries the row's title as its label (hidden on screen), so VoiceOver and
/// anything driving the window by accessibility find it by the words beside it.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color = .blue
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color = .blue, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle, symbol: symbol, tint: tint) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch)
        }
    }
}

/// A slider with its value written beside it — as a percentage, a multiple, seconds,
/// whatever `format` says.
struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let format: (Double) -> String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
         format: @escaping (Double) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        HStack(spacing: 10) {
            // Never the system's stepped slider, which draws a row of tick marks under the
            // track — one per step, a dotted line under every stepped setting. The value is
            // snapped to the step here instead, so it lands where it always did.
            Slider(value: snapped, in: range) { Text(title) }
                .frame(width: 160)
            Text(format(value))
                .font(SettingsFont.sub)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    /// `value`, held to the step when there is one.
    private var snapped: Binding<Double> {
        Binding {
            value
        } set: { proposed in
            guard let step, step > 0 else { value = proposed; return }
            let steps = ((proposed - range.lowerBound) / step).rounded()
            value = min(range.upperBound, max(range.lowerBound, range.lowerBound + steps * step))
        }
    }

    /// "40%", for anything that runs from none to all.
    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// "1.8×", for a zoom or a size.
    static func multiple(_ value: Double) -> String {
        String(format: "%.1f×", value)
    }

    /// "1.2 s".
    static func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value)
    }
}

/// A line of state inside a card — granted, missing, how much space — with an optional
/// button to do something about it.
struct SettingsStatusRow<Action: View>: View {
    let title: String
    var subtitle: String?
    let isGood: Bool
    @ViewBuilder let action: Action

    init(_ title: String, subtitle: String? = nil, isGood: Bool, @ViewBuilder action: () -> Action) {
        self.title = title
        self.subtitle = subtitle
        self.isGood = isGood
        self.action = action()
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle,
                    symbol: isGood ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                    tint: isGood ? .green : .orange) {
            action
        }
    }
}

// MARK: - Buttons in rows

/// The small "arrow out of a box" that reveals something in the Finder or System Settings.
struct RevealButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        // A push button like the Choose… beside it, so the two stand the same height and
        // read as a pair; a bare glyph next to a button looked dropped in from elsewhere.
        Button(action: action) {
            Image(systemName: "arrow.up.forward.app")
                .imageScale(.medium)
        }
        .help(help)
        .accessibilityLabel(help)
    }
}
