import AppKit
import SwiftUI

extension Color {
    /// Klik blue (#0E4FEC), the fill of the app icon; also the asset-catalog AccentColor.
    static let brand = Color(red: 0x0E / 255, green: 0x4F / 255, blue: 0xEC / 255)
}

/// Klik's floating-panel look: frosted Liquid Glass with a fine grain on macOS 26,
/// a material panel on earlier systems.
struct KlikGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    /// Darkening tint — keeps white text legible over bright content.
    var tint: Color = .black.opacity(0.28)

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .background { GrainOverlay(opacity: 0.16).clipShape(shape) }
                .glassEffect(.regular.tint(tint), in: shape)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        } else {
            content
                .background { GrainOverlay(opacity: 0.12).clipShape(shape) }
                .background(.regularMaterial, in: shape)
                .background(tint, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.14)))
                .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
        }
    }
}

extension View {
    func klikGlass(cornerRadius: CGFloat = 14, tint: Color = .black.opacity(0.28)) -> some View {
        modifier(KlikGlassModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

/// Tiled monochrome noise, generated once. Blended over the glass it gives the
/// frosted, slightly grainy texture rather than a flat translucent sheet.
struct GrainOverlay: View {
    var opacity: Double
    /// A fine, low-contrast grain (soft light) that reads as texture rather than
    /// static — for glass over light backgrounds.
    var smooth = false

    var body: some View {
        Image(nsImage: smooth ? Self.smoothTile : Self.tile)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(smooth ? .softLight : .overlay)
            .allowsHitTesting(false)
    }

    private static let tile = makeTile(range: 0...255)
    private static let smoothTile = makeTile(range: 108...148)

    private static func makeTile(range: ClosedRange<UInt8>) -> NSImage {
        let size = 128
        var bytes = [UInt8](repeating: 0, count: size * size)
        var generator = SystemRandomNumberGenerator()
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: range, using: &generator)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cgImage = CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}

/// A keyboard-key badge for shortcut hints ("↩", "esc").
struct KeyCap: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold).monospaced())
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.primary.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.primary.opacity(0.16)))
    }
}

/// Buttons inside the floating pills. Drawn by hand so they stay vivid in the
/// non-activating capture panels — the system styles render as "inactive window"
/// (dimmed) there, which reads as disabled.
struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, prominent: prominent, isEnabled: isEnabled)
    }

    private struct PillButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            let shape = Capsule(style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if prominent {
                        shape.fill(.tint)
                            .overlay(shape.fill(.white.opacity(hovering ? 0.12 : 0)))
                    } else {
                        shape.fill(.white.opacity(hovering ? 0.22 : 0.14))
                    }
                }
                .overlay(shape.strokeBorder(.white.opacity(prominent ? 0.25 : 0.18)))
                .shadow(color: .black.opacity(prominent ? 0.25 : 0), radius: 4, y: 2)
                .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.45))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(shape)
        }
    }
}

extension View {
    func glassButton(prominent: Bool = false) -> some View {
        buttonStyle(PillButtonStyle(prominent: prominent))
    }

    /// A capsule of glass behind a label — a menu's or a badge's.
    func glassPill(tint: Color? = nil) -> some View {
        modifier(GlassShape(shape: Capsule(), tint: tint))
    }

    /// A round glass button face.
    func glassCircle(tint: Color? = nil) -> some View {
        modifier(GlassShape(shape: Circle(), tint: tint))
    }
}

/// Liquid Glass in a shape (a fill with a hairline edge before macOS 26), tinted or
/// clear. Siblings in one `GlassEffectContainer` blend as they move.
struct GlassShape<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                content.glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            content
                .background(tint ?? .primary.opacity(0.1), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(tint == nil ? 0.12 : 0.2)))
        }
    }
}

/// A strip that drags the window it is in — the handle at the top of a floating pane.
struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {}

    final class Handle: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

extension NSCursor {
    /// A turn-arrow cursor for the rotation knob (AppKit has no public one).
    static let rotate: NSCursor = {
        let size = CGSize(width: 22, height: 22)
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Rotate")?
            .withSymbolConfiguration(configuration)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let symbol else { return false }
            let frame = CGRect(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2,
                               width: symbol.size.width, height: symbol.size.height)
            // White halo so it reads on any background, black glyph on top.
            for dx in [-1.0, 0, 1] { for dy in [-1.0, 0, 1] where dx != 0 || dy != 0 {
                symbol.draw(in: frame.offsetBy(dx: dx, dy: dy), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                            hints: [.ctm: AffineTransform.identity])
            } }
            NSColor.white.set()
            frame.offsetBy(dx: 0, dy: 0).fill(using: .sourceAtop)
            symbol.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 11, y: 11))
    }()
}

/// Real Liquid Glass (macOS 26): a lightly tinted, refractive `glassEffect` that
/// bends what is behind the panel, with a faint grain so text keeps its contrast.
/// Follows the appearance (light tint in light mode, dark in dark). Older systems
/// get a material.
struct LiquidGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    /// Dark glass whatever the appearance (for content drawn in white).
    var alwaysDark = false
    /// How see-through: 0 is the frosted default, 1 nearly clear (the tint and
    /// grain fade out, the material thins) — for a note pinned over other apps.
    var clarity: Double = 0
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = alwaysDark || scheme == .dark
        let clarity = min(max(clarity, 0), 1)
        let tint: Color = dark ? .black.opacity((alwaysDark && scheme == .light ? 0.5 : 0.22) * (1 - clarity)) : .white.opacity(0.28 * (1 - clarity))
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content
                    .background { GrainOverlay(opacity: (dark ? 0.5 : 0.35) * (1 - clarity), smooth: true).clipShape(shape) }
                    .glassEffect(clarity >= 0.5 ? .clear.tint(tint).interactive() : .regular.tint(tint).interactive(), in: shape)
            }
        } else {
            content
                .background { GrainOverlay(opacity: 0.4 * (1 - clarity), smooth: true).clipShape(shape) }
                .background(clarity >= 0.67 ? Material.ultraThinMaterial : clarity >= 0.34 ? Material.thinMaterial : Material.regularMaterial, in: shape)
                .background(tint, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        }
    }
}

extension View {
    /// Tinted Liquid Glass that follows the appearance (or stays dark); `clarity`
    /// from 0 (frosted) to 1 (nearly clear).
    func liquidGlass(cornerRadius: CGFloat, alwaysDark: Bool = false, clarity: Double = 0) -> some View {
        modifier(LiquidGlassModifier(cornerRadius: cornerRadius, alwaysDark: alwaysDark, clarity: clarity))
    }
}
