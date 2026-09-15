import Foundation

/// A picked colour as exact sRGB components (not clamped: a Display P3 colour
/// outside sRGB keeps its true value) plus alpha. All conversions follow CSS Color 4
/// so the strings match what browsers and design tools show.
nonisolated struct PickedColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    // MARK: - Spaces

    /// 0…1 components clamped to the sRGB gamut, for display and 8-bit formats.
    var clamped: (r: Double, g: Double, b: Double) {
        (min(max(red, 0), 1), min(max(green, 0), 1), min(max(blue, 0), 1))
    }

    var isInSRGBGamut: Bool {
        [red, green, blue].allSatisfy { $0 >= -0.0005 && $0 <= 1.0005 }
    }

    /// Linear-light sRGB (the sRGB transfer function undone).
    var linear: (r: Double, g: Double, b: Double) {
        (Self.toLinear(red), Self.toLinear(green), Self.toLinear(blue))
    }

    /// CIE XYZ, D65 white, from linear sRGB (matrix from CSS Color 4).
    var xyz: (x: Double, y: Double, z: Double) {
        let (r, g, b) = linear
        return (
            0.41239079926595934 * r + 0.357584339383878 * g + 0.1804807884018343 * b,
            0.21263900587151027 * r + 0.715168678767756 * g + 0.07219231536073371 * b,
            0.01933081871559182 * r + 0.11919477979462598 * g + 0.9505321522496607 * b
        )
    }

    /// OKLab (Björn Ottosson), from linear sRGB.
    var oklab: (l: Double, a: Double, b: Double) {
        let (r, g, b) = linear
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// OKLCH: lightness 0…1, chroma, hue in degrees.
    var oklch: (l: Double, c: Double, h: Double) {
        let (l, a, b) = oklab
        return (l, hypot(a, b), Self.hue(a, b))
    }

    /// CIE Lab with the D50 white CSS uses (XYZ adapted with Bradford).
    var lab: (l: Double, a: Double, b: Double) {
        let (x, y, z) = xyz
        // Bradford D65 → D50.
        let xd = 1.0479298208405488 * x + 0.022946793341019088 * y - 0.05019222954313557 * z
        let yd = 0.029627815688159344 * x + 0.990434484573249 * y - 0.01707382502938514 * z
        let zd = -0.009243058152591178 * x + 0.015055144896577895 * y + 0.7518742899580008 * z
        let white = (0.3457 / 0.3585, 1.0, (1.0 - 0.3457 - 0.3585) / 0.3585)
        func f(_ t: Double) -> Double {
            let epsilon = 216.0 / 24389.0, kappa = 24389.0 / 27.0
            return t > epsilon ? cbrt(t) : (kappa * t + 16) / 116
        }
        let fx = f(xd / white.0), fy = f(yd / white.1), fz = f(zd / white.2)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIE LCH (from `lab`): lightness 0…100, chroma, hue in degrees.
    var lch: (l: Double, c: Double, h: Double) {
        let (l, a, b) = lab
        return (l, hypot(a, b), Self.hue(a, b))
    }

    /// Display P3 components 0…1 (gamma-encoded like sRGB).
    var displayP3: (r: Double, g: Double, b: Double) {
        let (x, y, z) = xyz
        let r = 2.493496911941425 * x - 0.9313836179191239 * y - 0.40271078445071684 * z
        let g = -0.8294889695615747 * x + 1.7626640603183463 * y + 0.023624685841943577 * z
        let b = 0.03584583024378447 * x - 0.07617238926804182 * y + 0.9568845240076872 * z
        return (Self.fromLinear(r), Self.fromLinear(g), Self.fromLinear(b))
    }

    /// Hue 0…360, saturation and lightness 0…1 (CSS hsl()).
    var hsl: (h: Double, s: Double, l: Double) {
        let (r, g, b) = clamped
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        guard d > 1e-9 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        return (Self.hue(r: r, g: g, b: b, max: maxC, delta: d), s, l)
    }

    /// Hue 0…360, saturation and brightness 0…1 (HSB / HSV).
    var hsb: (h: Double, s: Double, b: Double) {
        let (r, g, b) = clamped
        let maxC = max(r, g, b), minC = min(r, g, b)
        let d = maxC - minC
        guard maxC > 1e-9, d > 1e-9 else { return (0, 0, maxC) }
        return (Self.hue(r: r, g: g, b: b, max: maxC, delta: d), d / maxC, maxC)
    }

    /// Naive CMYK 0…1 (no ink profile — what design tools show by default).
    var cmyk: (c: Double, m: Double, y: Double, k: Double) {
        let (r, g, b) = clamped
        let k = 1 - max(r, g, b)
        guard k < 1 - 1e-9 else { return (0, 0, 0, 1) }
        return ((1 - r - k) / (1 - k), (1 - g - k) / (1 - k), (1 - b - k) / (1 - k), k)
    }

    // MARK: - Parsing

    /// `#RGB`, `#RRGGBB`, `#RRGGBBAA` (with or without `#`).
    init?(hex: String) {
        var body = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("#") { body.removeFirst() }
        guard body.allSatisfy(\.isHexDigit) else { return nil }
        if body.count == 3 || body.count == 4 { body = body.map { "\($0)\($0)" }.joined() }
        guard body.count == 6 || body.count == 8, let value = UInt64(body, radix: 16) else { return nil }
        let shift = body.count == 8 ? 8 : 0
        red = Double((value >> (16 + shift)) & 0xFF) / 255
        green = Double((value >> (8 + shift)) & 0xFF) / 255
        blue = Double((value >> shift) & 0xFF) / 255
        alpha = body.count == 8 ? Double(value & 0xFF) / 255 : 1
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    // MARK: - Helpers

    static func toLinear(_ c: Double) -> Double {
        let sign: Double = c < 0 ? -1 : 1
        let a = abs(c)
        return sign * (a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4))
    }

    static func fromLinear(_ c: Double) -> Double {
        let sign: Double = c < 0 ? -1 : 1
        let a = abs(c)
        return sign * (a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055)
    }

    private static func hue(_ a: Double, _ b: Double) -> Double {
        guard abs(a) > 1e-9 || abs(b) > 1e-9 else { return 0 }
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    private static func hue(r: Double, g: Double, b: Double, max: Double, delta: Double) -> Double {
        var h: Double
        if max == r { h = (g - b) / delta + (g < b ? 6 : 0) }
        else if max == g { h = (b - r) / delta + 2 }
        else { h = (r - g) / delta + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }
}

/// The strings a colour can be copied as.
nonisolated enum ColorFormat: String, CaseIterable, Codable {
    case hex, hexAlpha, rgb, rgba, hsl, hsb, oklch, oklab, lch, lab, displayP3, cmyk, swiftUI, nsColor, uiColor

    var title: String {
        switch self {
        case .hex: "HEX"
        case .hexAlpha: "HEX with alpha"
        case .rgb: "RGB"
        case .rgba: "RGBA"
        case .hsl: "HSL"
        case .hsb: "HSB"
        case .oklch: "OKLCH"
        case .oklab: "OKLab"
        case .lch: "LCH"
        case .lab: "Lab"
        case .displayP3: "Display P3"
        case .cmyk: "CMYK"
        case .swiftUI: "SwiftUI"
        case .nsColor: "NSColor"
        case .uiColor: "UIColor"
        }
    }

    func string(for color: PickedColor) -> String {
        let (r, g, b) = color.clamped
        let r8 = Int((r * 255).rounded()), g8 = Int((g * 255).rounded()), b8 = Int((b * 255).rounded())
        let alpha = color.alpha
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", r8, g8, b8)
        case .hexAlpha:
            return String(format: "#%02X%02X%02X%02X", r8, g8, b8, Int((alpha * 255).rounded()))
        case .rgb:
            return "rgb(\(r8), \(g8), \(b8))"
        case .rgba:
            return "rgba(\(r8), \(g8), \(b8), \(Self.number(alpha, 2)))"
        case .hsl:
            let (h, s, l) = color.hsl
            return "hsl(\(Self.number(h, 1)), \(Self.number(s * 100, 1))%, \(Self.number(l * 100, 1))%)"
        case .hsb:
            let (h, s, v) = color.hsb
            return "hsb(\(Self.number(h, 1)), \(Self.number(s * 100, 1))%, \(Self.number(v * 100, 1))%)"
        case .oklch:
            let (l, c, h) = color.oklch
            return "oklch(\(Self.number(l * 100, 2))% \(Self.number(c, 4)) \(Self.number(h, 2)))"
        case .oklab:
            let (l, a, b) = color.oklab
            return "oklab(\(Self.number(l * 100, 2))% \(Self.number(a, 4)) \(Self.number(b, 4)))"
        case .lch:
            let (l, c, h) = color.lch
            return "lch(\(Self.number(l, 2))% \(Self.number(c, 2)) \(Self.number(h, 2)))"
        case .lab:
            let (l, a, b) = color.lab
            return "lab(\(Self.number(l, 2))% \(Self.number(a, 2)) \(Self.number(b, 2)))"
        case .displayP3:
            let (pr, pg, pb) = color.displayP3
            return "color(display-p3 \(Self.number(pr, 4)) \(Self.number(pg, 4)) \(Self.number(pb, 4)))"
        case .cmyk:
            let (c, m, y, k) = color.cmyk
            return "cmyk(\(Self.number(c * 100, 0))%, \(Self.number(m * 100, 0))%, \(Self.number(y * 100, 0))%, \(Self.number(k * 100, 0))%)"
        case .swiftUI:
            return "Color(red: \(Self.number(r, 3)), green: \(Self.number(g, 3)), blue: \(Self.number(b, 3)))"
        case .nsColor:
            return "NSColor(srgbRed: \(Self.number(r, 3)), green: \(Self.number(g, 3)), blue: \(Self.number(b, 3)), alpha: \(Self.number(alpha, 2)))"
        case .uiColor:
            return "UIColor(red: \(Self.number(r, 3)), green: \(Self.number(g, 3)), blue: \(Self.number(b, 3)), alpha: \(Self.number(alpha, 2)))"
        }
    }

    /// Fixed decimals, trailing zeros trimmed ("62.8", "0.2577", "100").
    static func number(_ value: Double, _ decimals: Int) -> String {
        var string = String(format: "%.\(decimals)f", value)
        if string.contains(".") {
            while string.hasSuffix("0") { string.removeLast() }
            if string.hasSuffix(".") { string.removeLast() }
        }
        return string == "-0" ? "0" : string
    }
}
