import AppKit

/// A color as plain data so the model stays a value type.
public struct RGBA: Hashable, Codable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double = 1

    public var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var cgColor: CGColor { nsColor.cgColor }

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent; a = c.alphaComponent
    }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    public static let red = RGBA(r: 1, g: 0.23, b: 0.19)
    public static let orange = RGBA(r: 1, g: 0.58, b: 0)
    public static let yellow = RGBA(r: 1, g: 0.84, b: 0.04)
    public static let green = RGBA(r: 0.2, g: 0.78, b: 0.35)
    public static let blue = RGBA(r: 0.04, g: 0.52, b: 1)
    public static let purple = RGBA(r: 0.69, g: 0.32, b: 0.87)
    public static let pink = RGBA(r: 1, g: 0.18, b: 0.33)
    public static let white = RGBA(r: 1, g: 1, b: 1)
    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let gray = RGBA(r: 0.56, g: 0.56, b: 0.58)

    public static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .white, .black, .gray]
}
