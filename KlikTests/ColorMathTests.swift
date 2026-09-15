import XCTest

/// Color conversions checked against the CSS Color 4 reference values (what
/// browsers, Figma and Digital Color Meter report).
final class ColorMathTests: XCTestCase {
    private let red = PickedColor(hex: "#FF0000")!
    private let pink = PickedColor(hex: "#D6688B")!

    func testHexParsing() {
        XCTAssertEqual(PickedColor(hex: "d6688b"), pink)
        XCTAssertEqual(PickedColor(hex: "#F0A")?.clamped.r, 1)
        XCTAssertEqual(PickedColor(hex: "#F0A")?.clamped.g, 0)
        XCTAssertEqual(PickedColor(hex: "#F0A")?.clamped.b ?? 0, 170 / 255, accuracy: 1e-9)
        XCTAssertEqual(PickedColor(hex: "#FF000080")?.alpha ?? 0, 128 / 255, accuracy: 1e-9)
        XCTAssertNil(PickedColor(hex: "#12345"))
        XCTAssertNil(PickedColor(hex: "zzzzzz"))
    }

    func testEightBitFormats() {
        XCTAssertEqual(ColorFormat.hex.string(for: pink), "#D6688B")
        XCTAssertEqual(ColorFormat.rgb.string(for: pink), "rgb(214, 104, 139)")
        XCTAssertEqual(ColorFormat.rgba.string(for: PickedColor(red: 1, green: 0, blue: 0, alpha: 0.5)), "rgba(255, 0, 0, 0.5)")
        XCTAssertEqual(ColorFormat.hexAlpha.string(for: PickedColor(red: 1, green: 0, blue: 0, alpha: 0.5)), "#FF000080")
    }

    func testHSLAndHSB() {
        let (h, s, l) = pink.hsl
        XCTAssertEqual(h, 340.9, accuracy: 0.1)
        XCTAssertEqual(s, 0.573, accuracy: 0.001)
        XCTAssertEqual(l, 0.624, accuracy: 0.001)
        XCTAssertEqual(ColorFormat.hsl.string(for: red), "hsl(0, 100%, 50%)")
        XCTAssertEqual(ColorFormat.hsb.string(for: red), "hsb(0, 100%, 100%)")
        XCTAssertEqual(ColorFormat.hsl.string(for: PickedColor(hex: "#808080")!), "hsl(0, 0%, 50.2%)")
    }

    func testOKLCHMatchesTheSpec() {
        // CSS Color 4: red is oklch(62.8% 0.2577 29.23), white oklch(100% 0 0).
        let (l, c, h) = red.oklch
        XCTAssertEqual(l, 0.628, accuracy: 0.001)
        XCTAssertEqual(c, 0.2577, accuracy: 0.0005)
        XCTAssertEqual(h, 29.23, accuracy: 0.05)
        XCTAssertEqual(ColorFormat.oklch.string(for: red), "oklch(62.8% 0.2577 29.23)")
        let white = PickedColor(hex: "#FFFFFF")!.oklch
        XCTAssertEqual(white.l, 1, accuracy: 1e-6)
        XCTAssertEqual(white.c, 0, accuracy: 1e-6)
    }

    func testLabAndLCHUseD50LikeCSS() {
        // CSS Color 4: red is lab(54.29% 80.8 69.89) / lch(54.29% 106.84 40.85).
        let (l, a, b) = red.lab
        XCTAssertEqual(l, 54.29, accuracy: 0.02)
        XCTAssertEqual(a, 80.8, accuracy: 0.05)
        XCTAssertEqual(b, 69.89, accuracy: 0.05)
        let lch = red.lch
        XCTAssertEqual(lch.c, 106.84, accuracy: 0.05)
        XCTAssertEqual(lch.h, 40.85, accuracy: 0.05)
        let grey = PickedColor(hex: "#808080")!.lab
        XCTAssertEqual(grey.l, 53.59, accuracy: 0.02)
        XCTAssertEqual(grey.a, 0, accuracy: 0.01)
        XCTAssertEqual(grey.b, 0, accuracy: 0.01)
    }

    func testDisplayP3() {
        // sRGB red inside P3 is color(display-p3 0.9175 0.2003 0.1386).
        let (r, g, b) = red.displayP3
        XCTAssertEqual(r, 0.9175, accuracy: 0.001)
        XCTAssertEqual(g, 0.2003, accuracy: 0.001)
        XCTAssertEqual(b, 0.1386, accuracy: 0.001)
        // White and grey are unchanged between the two spaces.
        let grey = PickedColor(hex: "#808080")!.displayP3
        XCTAssertEqual(grey.r, 128 / 255, accuracy: 0.001)
        XCTAssertEqual(grey.g, grey.b, accuracy: 1e-9)
        // A P3 color outside sRGB keeps its value (no clamping) and says so.
        let vivid = PickedColor(red: 1.09, green: -0.23, blue: -0.15)
        XCTAssertFalse(vivid.isInSRGBGamut)
        XCTAssertEqual(ColorFormat.hex.string(for: vivid), "#FF0000")
        XCTAssertTrue(red.isInSRGBGamut)
    }

    func testCMYKAndCode() {
        XCTAssertEqual(ColorFormat.cmyk.string(for: red), "cmyk(0%, 100%, 100%, 0%)")
        XCTAssertEqual(ColorFormat.cmyk.string(for: PickedColor(hex: "#000000")!), "cmyk(0%, 0%, 0%, 100%)")
        XCTAssertEqual(ColorFormat.swiftUI.string(for: red), "Color(red: 1, green: 0, blue: 0)")
        XCTAssertEqual(ColorFormat.nsColor.string(for: pink), "NSColor(srgbRed: 0.839, green: 0.408, blue: 0.545, alpha: 1)")
    }

    func testNumberFormatting() {
        XCTAssertEqual(ColorFormat.number(62.8, 2), "62.8")
        XCTAssertEqual(ColorFormat.number(100, 2), "100")
        XCTAssertEqual(ColorFormat.number(0.25768, 4), "0.2577")
        XCTAssertEqual(ColorFormat.number(-0.00001, 2), "0")
    }
}
