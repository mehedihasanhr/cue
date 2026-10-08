import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import RenderKit
import TimelineKit

/// A rendered frame, read back as numbers, top-left origin.
struct AnnotationFrame {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func colour(_ x: Int, _ y: Int) -> ColorValue {
        let index = (min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))) * 4
        return ColorValue(r: Double(bytes[index]) / 255, g: Double(bytes[index + 1]) / 255,
                          b: Double(bytes[index + 2]) / 255)
    }

    static func distance(_ a: ColorValue, _ b: ColorValue) -> Double {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    func differs(_ x: Int, _ y: Int, from background: ColorValue, by threshold: Double = 0.1) -> Bool {
        Self.distance(colour(x, y), background) > threshold
    }

    /// Where anything other than `background` is, as a box of whole pixels.
    func ink(against background: ColorValue, threshold: Double = 0.1) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where differs(x, y, from: background, by: threshold) {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// How many pixels differ from the background.
    func inkCount(against background: ColorValue, threshold: Double = 0.1) -> Int {
        var count = 0
        for y in 0..<height { for x in 0..<width where differs(x, y, from: background, by: threshold) { count += 1 } }
        return count
    }

    /// The middle of the ink, weighted by pixel.
    func inkCentre(against background: ColorValue, in area: CGRect? = nil,
                   threshold: Double = 0.1) -> CGPoint? {
        var sx = 0.0, sy = 0.0, n = 0.0
        let area = area ?? CGRect(x: 0, y: 0, width: width, height: height)
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) where differs(x, y, from: background, by: threshold) {
                sx += Double(x); sy += Double(y); n += 1
            }
        }
        return n > 0 ? CGPoint(x: sx / n, y: sy / n) : nil
    }

    /// Every colour inside `area`.
    func colours(in area: CGRect) -> [ColorValue] {
        var found: [ColorValue] = []
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) { found.append(colour(x, y)) }
        }
        return found
    }
}

enum AnnotationRendering {
    static let red = ColorValue(r: 1, g: 0.23, b: 0.19)
    static let yellow = ColorValue(r: 1, g: 0.9, b: 0.2)
    static let navy = ColorValue(r: 0.05, g: 0.1, b: 0.35)

    /// Just the annotations, on a flat colour, at `size` pixels square.
    static func render(_ layers: [AnnotationLayer], on background: ColorValue, size: Int = 400) throws -> AnnotationFrame {
        let output = CGSize(width: size, height: size)
        var scene = SceneDescriptor(outputSize: output,
                                    background: .color(background),
                                    videoFrame: CGRect(origin: .zero, size: output))
        scene.annotations = layers
        let image = try #require(SceneRenderer().cgImage(for: scene, source: nil))
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        return AnnotationFrame(width: size, height: size, bytes: bytes)
    }

    static func layer(_ kind: AnnotationItem.Kind,
                      rect: CGRect = CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.4),
                      colour: ColorValue = red,
                      fontSize: Double = 0.08,
                      style: AnnotationStyle = AnnotationStyle(),
                      opacity: Double = 1,
                      rotation: Double = 0) -> AnnotationLayer {
        AnnotationLayer(kind: kind, rect: rect, color: colour, fontSize: fontSize, opacity: opacity,
                        rotation: rotation, style: style)
    }

    /// A rect normalised to a square frame of `size`, in pixels.
    static func pixels(_ rect: CGRect, size: Int = 400) -> CGRect {
        CGRect(x: rect.minX * Double(size), y: rect.minY * Double(size),
               width: rect.width * Double(size), height: rect.height * Double(size))
    }

    static let everyKind: [AnnotationItem.Kind] = [
        .rectangle, .ellipse, .loop, .highlight, .step(3), .text("Hello"),
        .callout("Hello", tail: CGPoint(x: 0.5, y: 0.5)),
        .line(from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0)),
        .arrow(from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0)),
    ]
}

/// Every kind, drawn: where it lands, what shape it is, and nothing spilling out of it.
struct AnnotationKindRenderTests {
    private typealias R = AnnotationRendering
    private let box = CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.4)

    @Test func aBlankFrameIsTheBackground() throws {
        let frame = try R.render([], on: .white)
        #expect(frame.ink(against: .white) == nil)
    }

    @Test func everyKindDrawsInsideItsBox() throws {
        let area = R.pixels(box)
        for kind in R.everyKind {
            for background in [ColorValue.white, ColorValue.black] {
                let frame = try R.render([R.layer(kind)], on: background)
                let ink = try #require(frame.ink(against: background), "\(kind) drew nothing")
                // Two pixels of slack for a rounded line end and anti-aliasing.
                #expect(area.insetBy(dx: -2, dy: -2).contains(ink), "\(kind) spilled out: \(ink) is not inside \(area)")
            }
        }
    }

    @Test func anEllipseIsARingNotABox() throws {
        let frame = try R.render([R.layer(.ellipse)], on: .black)
        let area = R.pixels(box)
        #expect(!frame.differs(Int(area.minX) + 4, Int(area.minY) + 4, from: .black), "corners are empty")
        #expect(!frame.differs(Int(area.maxX) - 4, Int(area.maxY) - 4, from: .black))
        #expect(!frame.differs(Int(area.midX), Int(area.midY), from: .black), "and so is the middle")
        #expect(frame.differs(Int(area.midX), Int(area.minY) + 1, from: .black), "the top of the ring")
        #expect(frame.differs(Int(area.minX) + 1, Int(area.midY), from: .black), "and its side")
    }

    /// A step is round in any box, and its number sits in the middle of the circle — on the
    /// ink of the figures, not the line they stand on.
    @Test func aStepIsRoundWithItsNumberInTheMiddle() throws {
        let wide = CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2)
        for number in [1, 7, 12, 123] {
            let frame = try R.render([R.layer(.step(number), rect: wide)], on: .black)
            let ink = try #require(frame.ink(against: .black))
            #expect(abs(ink.width - ink.height) <= 2, "round, not stretched to the box: \(ink)")
            #expect(abs(ink.midX - 200) <= 1.5 && abs(ink.midY - 200) <= 1.5)
            // The figures are white on red; find them by their blue, which the red lacks.
            var minX = 400, maxX = 0, minY = 400, maxY = 0
            for y in 0..<400 { for x in 0..<400 where frame.colour(x, y).b > 0.6 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            #expect(maxX > minX, "the number \(number) is drawn")
            #expect(abs(Double(minX + maxX + 1) / 2 - 200) <= 1.5, "\(number) centred across")
            #expect(abs(Double(minY + maxY + 1) / 2 - 200) <= 1.5, "\(number) centred down")
        }
    }

    @Test func aStepsNumberReadsOnAnyColour() throws {
        for colour in [R.yellow, R.navy, ColorValue.white, ColorValue.black, R.red] {
            let frame = try R.render([R.layer(.step(4), colour: colour)], on: .black)
            let disc = frame.colour(200, 200 - 60)
            let figures = frame.colours(in: CGRect(x: 180, y: 180, width: 40, height: 40))
            let best = figures.map { $0.contrastRatio(with: disc) }.max() ?? 0
            #expect(best >= 3, "the number on \(colour) contrasts \(best):1")
        }
    }

    @Test func fillsFillBoxesAndEllipses() throws {
        for kind in [AnnotationItem.Kind.rectangle, .ellipse] {
            let empty = try R.render([R.layer(kind)], on: .white).colour(200, 200)
            let solid = try R.render([R.layer(kind, style: AnnotationStyle(fill: .solid))], on: .white).colour(200, 200)
            let tint = try R.render([R.layer(kind, style: AnnotationStyle(fill: .translucent))], on: .white).colour(200, 200)
            #expect(AnnotationFrame.distance(empty, .white) < 0.02, "\(kind) with no fill is empty inside")
            // Loosely: the renderer works in a wider space than sRGB, which moves a strong
            // red by a few percent on the way out.
            #expect(AnnotationFrame.distance(solid, R.red) < 0.15, "\(kind) solid is its colour: \(solid)")
            #expect(tint.g > 0.6 && tint.g < 0.9 && tint.r > 0.95, "\(kind) translucent is a tint: \(tint)")
        }
    }

    /// A marker pen: seen on white and on black, and the words under it still read.
    @Test func aHighlightIsSeeThroughOnLightAndDark() throws {
        let marker = R.layer(.highlight, colour: R.yellow)
        let onWhite = try R.render([marker], on: .white).colour(200, 200)
        let onBlack = try R.render([marker], on: .black).colour(200, 200)
        #expect(onWhite.b < 0.85 && onWhite.b > 0.6, "a visible tint over white: \(onWhite)")
        #expect(onBlack.r > 0.25 && onBlack.r < 0.6, "visible over black, and still see-through: \(onBlack)")
        let edge = try R.render([marker], on: .white).colour(Int(R.pixels(box).minX) + 3, 200)
        #expect(AnnotationFrame.distance(edge, onWhite) < 0.03, "no outline, just the tint")

        let words = R.layer(.text("HHHH"), rect: box, colour: .black, fontSize: 0.1,
                            style: AnnotationStyle(weight: .bold))
        let frame = try R.render([words, marker], on: .white)
        let darkest = frame.colours(in: R.pixels(box)).min { $0.relativeLuminance < $1.relativeLuminance }
        // Tinted by it, as ink under a marker is, and still well clear of the bar for body text.
        #expect((darkest?.contrastRatio(with: onWhite) ?? 0) > 4.5, "black words under a highlight still read")
    }

    @Test func thicknessThickensEveryLine() throws {
        func band(_ kind: AnnotationItem.Kind, _ thickness: Double, down: Bool) throws -> Int {
            let frame = try R.render([R.layer(kind, style: AnnotationStyle(thickness: thickness))], on: .black)
            var count = 0
            if down {
                for y in 0..<400 where frame.differs(200, y, from: .black) { count += 1 }
            } else {
                for x in 0..<200 where frame.differs(x, 200, from: .black) { count += 1 }
            }
            return count
        }
        for kind in [AnnotationItem.Kind.rectangle, .ellipse] {
            let thin = try band(kind, 1, down: false), thick = try band(kind, 4, down: false)
            #expect(thick >= thin * 2 && thick >= thin + 5, "\(kind): \(thin) → \(thick)")
            let frame = try R.render([R.layer(kind, style: AnnotationStyle(thickness: 4))], on: .black)
            #expect(R.pixels(box).insetBy(dx: -1, dy: -1).contains(try #require(frame.ink(against: .black))),
                    "a thick outline is still inside the box")
        }
        let flat = AnnotationItem.Kind.line(from: CGPoint(x: 0, y: 0.5), to: CGPoint(x: 1, y: 0.5))
        let thinLine = try band(flat, 1, down: true), thickLine = try band(flat, 4, down: true)
        #expect(thickLine >= thinLine * 2 && thickLine >= thinLine + 5, "line: \(thinLine) → \(thickLine)")
    }

    @Test func anArrowHasAHeadAndALineDoesNot() throws {
        let from = CGPoint(x: 0, y: 0.5), to = CGPoint(x: 1, y: 0.5)
        func height(_ kind: AnnotationItem.Kind, at x: Int) throws -> Int {
            let frame = try R.render([R.layer(kind)], on: .black)
            return (0..<400).filter { frame.differs(x, $0, from: .black) }.count
        }
        let tipX = Int(R.pixels(box).maxX) - 6
        #expect(try height(.arrow(from: from, to: to), at: tipX) >= height(.line(from: from, to: to), at: tipX) + 2)
        #expect(try height(.arrow(from: from, to: to), at: 200) == height(.line(from: from, to: to), at: 200),
                "the same shaft")
    }

    /// The tail reaches out of the box to its tip; the bubble stays in it.
    @Test func aCalloutsTailReachesOutAndNothingElseDoes() throws {
        let bubble = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.3)
        let callout = R.layer(.callout("Look", tail: CGPoint(x: 0.25, y: 1.8)), rect: bubble, fontSize: 0.05,
                              style: AnnotationStyle(backdrop: .solid))
        let frame = try R.render([callout], on: .white)
        let area = R.pixels(bubble)
        let tip = CGPoint(x: area.minX + 0.25 * area.width, y: area.minY + 1.8 * area.height)
        #expect(frame.differs(Int(tip.x), Int(tip.y) - 4, from: .white), "ink just short of the tip")
        let ink = try #require(frame.ink(against: .white))
        #expect(ink.maxY <= tip.y + 2 && ink.maxY >= tip.y - 3, "down to the tip and no further")
        #expect(ink.minX >= area.minX - 1 && ink.maxX <= area.maxX + 1 && ink.minY >= area.minY - 1)
        #expect(!frame.differs(Int(area.maxX) - 10, Int(area.maxY) + 20, from: .white),
                "below the bubble, away from the tail, is empty")
    }

    @Test func aCalloutWithNoBackdropIsAnOutlinedBubble() throws {
        let callout = R.layer(.callout("Hi", tail: CGPoint(x: 0.5, y: 1.5)), fontSize: 0.05)
        let frame = try R.render([callout], on: .black)
        let area = R.pixels(box)
        #expect(frame.differs(Int(area.midX), Int(area.minY) + 1, from: .black), "the outline")
        #expect(!frame.differs(Int(area.maxX) - 12, Int(area.midY), from: .black), "hollow")
    }

    /// Words that wrap stay inside the bubble.
    @Test func aCalloutsWordsWrapInsideIt() throws {
        let bubble = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)
        let words = "Click the blue button at the top"
        let callout = R.layer(.callout(words, tail: CGPoint(x: 0.5, y: 0.5)), rect: bubble, colour: .white,
                              fontSize: 0.04, style: AnnotationStyle(backdrop: .solid))
        let frame = try R.render([callout], on: .black)
        // The words are dark on the white bubble.
        var rows = Set<Int>()
        for y in 0..<400 { for x in 0..<400 where frame.colour(x, y).r < 0.4 && frame.differs(x, y, from: .black, by: 0.02)
            && R.pixels(bubble).contains(CGPoint(x: x, y: y)) { rows.insert(y / 10) } }
        #expect(rows.count >= 3, "more than one line")
        let ink = try #require(frame.ink(against: .black))
        #expect(R.pixels(bubble).insetBy(dx: -1, dy: -1).contains(ink))
    }
}
