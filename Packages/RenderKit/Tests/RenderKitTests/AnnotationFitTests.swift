import Foundation
import CoreGraphics
import Testing
import TimelineKit
@testable import RenderKit

/// A label's box is the label: as big as its words, and every word inside it.
struct AnnotationFitTests {
    private typealias R = AnnotationRendering
    private let frame = CGSize(width: 400, height: 400)
    private let plain = AnnotationStyle()
    private let plated = AnnotationStyle(backdrop: .solid)
    private let white = ColorValue(r: 1, g: 1, b: 1)

    private func size(_ text: String, style: AnnotationStyle? = nil, font: Double = 0.06, max: Double = 0.9) -> CGSize {
        AnnotationFit.labelSize(text, style: style ?? plain, color: white, fontSize: font, maxWidth: max, frame: frame)
    }

    @Test func moreWordsMakeAWiderBoxUntilItWraps() {
        let short = size("Hi")
        let long = size("Hello there, world")
        #expect(long.width > short.width)
        #expect(abs(long.height - short.height) < 0.001, "one line each")
        let wrapped = size("Hello there, world", max: 0.3)
        #expect(wrapped.width <= 0.3 + 0.001)
        #expect(wrapped.height > long.height * 1.5, "wraps onto more lines")
    }

    @Test func biggerTypeMakesABiggerBox() {
        let small = size("Label", font: 0.04), big = size("Label", font: 0.08)
        #expect(big.width > small.width * 1.6 && big.height > small.height * 1.6)
    }

    @Test func aPlateAddsItsPadding() {
        let bare = size("Label"), plate = size("Label", style: plated)
        #expect(plate.width > bare.width && plate.height > bare.height)
    }

    @Test func anEmptyLabelIsStillALineTall() {
        #expect(size("").height > 0.04)
    }

    /// Drawn in exactly the box it asked for, a label loses nothing: its ink is the same
    /// as in a box with plenty of room.
    @Test(arguments: ["Click here", "Save your changes before you go", "Step 2: open the menu"])
    func nothingIsCutOffInAFittedBox(_ text: String) throws {
        for style in [plain, plated] {
            let fitted = size(text, style: style, max: 0.5)
            let tight = CGRect(x: 0.1, y: 0.1, width: fitted.width, height: fitted.height)
            let roomy = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.6)
            let inTight = try R.render([R.layer(.text(text), rect: tight, colour: white, fontSize: 0.06, style: style)],
                                       on: ColorValue(r: 0, g: 0, b: 0))
            let inRoomy = try R.render([R.layer(.text(text), rect: roomy, colour: white, fontSize: 0.06, style: style)],
                                       on: ColorValue(r: 0, g: 0, b: 0))
            let a = try #require(inTight.ink(against: ColorValue(r: 0, g: 0, b: 0)))
            let b = try #require(inRoomy.ink(against: ColorValue(r: 0, g: 0, b: 0)))
            if style == plain {
                #expect(abs(a.height - b.height) <= 1 && abs(a.width - b.width) <= 2, "\(text): \(a) vs \(b)")
            } else {
                // The plate hugs the words in both, so it is the same plate.
                #expect(abs(a.height - b.height) <= 2, "\(text) on a plate: \(a) vs \(b)")
            }
        }
    }
}

/// The rules the editor applies to a label's box.
struct LabelFittingRuleTests {
    private let frame = CGSize(width: 1_920, height: 1_080)
    private func label(_ text: String, rect: CGRect, alignment: AnnotationStyle.Alignment = .left) -> AnnotationItem {
        var style = AnnotationStyle()
        style.alignment = alignment
        return AnnotationItem(start: .zero, duration: .zero, kind: .text(text), rect: rect, fontSize: 0.05, style: style)
    }

    @Test func typingGrowsTheBoxToTheRightThenWraps() {
        let small = CGRect(x: 0.1, y: 0.2, width: 0.05, height: 0.05)
        let short = AnnotationFit.fitted(label("Hi", rect: small), frame: frame, setByCaller: false)
        #expect(short.minX == 0.1 && short.minY == 0.2)
        let long = AnnotationFit.fitted(label(String(repeating: "word ", count: 30), rect: small), frame: frame, setByCaller: false)
        #expect(long.minX == 0.1)
        #expect(long.width <= AnnotationFit.growth + 0.001, "grows no wider than the growth limit")
        #expect(long.height > short.height * 2, "and then wraps")
    }

    @Test func aBoxSetByTheCallerWrapsAtItsWidth() {
        let narrow = CGRect(x: 0.1, y: 0.2, width: 0.15, height: 0.05)
        let fitted = AnnotationFit.fitted(label("Save your changes before you go", rect: narrow), frame: frame, setByCaller: true)
        #expect(fitted.width <= 0.15 + 0.001)
        #expect(fitted.height > 0.08)
    }

    @Test func aCentredLabelStaysCentred() {
        let box = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.05)
        let fitted = AnnotationFit.fitted(label("Hi", rect: box, alignment: .center), frame: frame, setByCaller: true)
        #expect(abs(fitted.midX - box.midX) < 0.001)
    }

    @Test func theBoxStaysInsideTheFrame() {
        let edge = CGRect(x: 0.95, y: 0.97, width: 0.2, height: 0.1)
        let fitted = AnnotationFit.fitted(label("Near the corner", rect: edge), frame: frame, setByCaller: false)
        #expect(fitted.maxX <= 1.0001 && fitted.maxY <= 1.0001)
    }

    @Test func onlyWhatALabelIsMadeOfRefitsIt() {
        let item = label("Hi", rect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.05))
        var moved = item; moved.opacity = 0.5
        #expect(!AnnotationFit.needsFitting(item, moved))
        var retyped = item; retyped.kind = .text("Hello")
        #expect(AnnotationFit.needsFitting(item, retyped))
        var bigger = item; bigger.fontSize = 0.08
        #expect(AnnotationFit.needsFitting(item, bigger))
        var box = item; box.kind = .rectangle
        #expect(!AnnotationFit.needsFitting(item, box), "a box is drawn to the size it is given")
    }
}

/// A label given a size by hand: the box follows the handle, and the words fit inside.
struct LabelBoxSizingTests {
    private let frame = CGSize(width: 400, height: 400)
    private let white = ColorValue(r: 1, g: 1, b: 1)

    // MARK: - A box sized by hand

    private func label(_ text: String, rect: CGRect, fixedWidth: Bool = false, fixedHeight: Bool = false,
                       font: Double = 0.06) -> AnnotationItem {
        var item = AnnotationItem(start: .zero, duration: .zero, kind: .text(text), rect: rect,
                                  color: white, fontSize: font,
                                  fixedWidth: fixedWidth, fixedHeight: fixedHeight)
        item.rect = rect
        return item
    }

    /// Dragging a side out past the words: the box follows the handle exactly, every
    /// step, instead of snapping back to the longest line.
    @Test func aPulledSideIsFollowedExactly() {
        for width in stride(from: 0.30, through: 0.80, by: 0.05) {
            let item = label("Short", rect: CGRect(x: 0.1, y: 0.1, width: width, height: 0.1), fixedWidth: true)
            let fitted = AnnotationFit.fitted(item, frame: frame, setByCaller: true)
            #expect(abs(fitted.width - width) < 1e-9, "width \(width) became \(fitted.width)")
            #expect(fitted.minX == 0.1)
        }
    }

    /// Dragging a side in: the words wrap, the box is the dragged width, and it grows only
    /// downwards — never jumping between word widths.
    @Test func aNarrowedBoxWrapsWithoutJumping() {
        var last: Double = 0
        for width in stride(from: 0.60, through: 0.20, by: -0.02) {
            let item = label("Save your changes before you go", rect: CGRect(x: 0.1, y: 0.1, width: width, height: 0.1),
                             fixedWidth: true)
            let fitted = AnnotationFit.fitted(item, frame: frame, setByCaller: true)
            #expect(abs(fitted.width - width) < 1e-9)
            #expect(fitted.height >= last - 1e-9, "narrower is never shorter")
            last = fitted.height
        }
    }

    /// Pulling the bottom: the box takes the height asked for, and never less than its lines.
    @Test func aPulledHeightIsKeptButNeverCutsTheWords() {
        let lines = AnnotationFit.fitted(label("One\nTwo\nThree", rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05)),
                                         frame: frame, setByCaller: false).height
        let tall = AnnotationFit.fitted(label("One\nTwo\nThree", rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.7),
                                              fixedHeight: true), frame: frame, setByCaller: true)
        #expect(abs(tall.height - 0.7) < 1e-9)
        let short = AnnotationFit.fitted(label("One\nTwo\nThree", rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05),
                                               fixedHeight: true), frame: frame, setByCaller: true)
        #expect(abs(short.height - lines) < 1e-9, "the lines win over a box too short for them")
    }

    /// A new line typed into a label makes it taller.
    @Test func anotherLineMakesALabelTaller() {
        let one = AnnotationFit.fitted(label("Line", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)),
                                       frame: frame, setByCaller: false)
        let two = AnnotationFit.fitted(label("Line\nLine", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)),
                                       frame: frame, setByCaller: false)
        #expect(two.height > one.height * 1.6)
    }

    /// Scaling from a corner: a one-line label stays on one line all the way through.
    @Test func scalingFromACornerNeverBreaksALine() {
        let start = AnnotationFit.fitted(label("Click Save to keep it", rect: CGRect(x: 0.05, y: 0.1, width: 0.1, height: 0.05),
                                               font: 0.05), frame: frame, setByCaller: false)
        let oneLine = start.height
        for scale in stride(from: 0.6, through: 1.6, by: 0.05) {
            let rect = CGRect(x: start.minX, y: start.minY, width: start.width * scale, height: start.height * scale)
            let fitted = AnnotationFit.fitted(label("Click Save to keep it", rect: rect, font: 0.05 * scale),
                                              frame: frame, setByCaller: true)
            #expect(fitted.height < oneLine * scale * 1.3, "scale \(scale) broke onto another line")
        }
    }

    @Test func oldProjectsOpenWithLabelsSizedToTheirWords() throws {
        let item = label("Hi", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        json.removeValue(forKey: "fixedWidth")
        json.removeValue(forKey: "fixedHeight")
        let decoded = try JSONDecoder().decode(AnnotationItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.fixedWidth && !decoded.fixedHeight)
    }
}

/// Labels of more than one line, and in boxes sized by hand, drawn the way they were fitted.
struct MultilineLabelRenderTests {
    private typealias R = AnnotationRendering
    private let frame = CGSize(width: 400, height: 400)
    private let black = ColorValue(r: 0, g: 0, b: 0)
    private let white = ColorValue(r: 1, g: 1, b: 1)

    private func fitted(_ text: String, rect: CGRect, fixedWidth: Bool = false, fixedHeight: Bool = false,
                        style: AnnotationStyle = AnnotationStyle()) -> CGRect {
        let item = AnnotationItem(start: .zero, duration: .zero, kind: .text(text), rect: rect,
                                  color: white, fontSize: 0.06, style: style,
                                  fixedWidth: fixedWidth, fixedHeight: fixedHeight)
        return AnnotationFit.fitted(item, frame: frame, setByCaller: fixedWidth || fixedHeight)
    }

    /// Three lines typed with Return: all three drawn, none cut off by the fitted box.
    @Test func everyLineIsDrawnInsideTheFittedBox() throws {
        let rect = fitted("One\nTwo\nThree", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05))
        let inBox = try R.render([R.layer(.text("One\nTwo\nThree"), rect: rect, colour: white, fontSize: 0.06)], on: black)
        let roomy = try R.render([R.layer(.text("One\nTwo\nThree"), rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                                          colour: white, fontSize: 0.06)], on: black)
        let a = try #require(inBox.ink(against: black)), b = try #require(roomy.ink(against: black))
        #expect(abs(a.height - b.height) <= 1, "\(a) vs \(b)")
        #expect(a.height > 0.06 * 400 * 2.2, "three lines tall")
    }

    /// A box pulled taller than its words keeps its words at the top, the same as before.
    @Test func aTallBoxKeepsItsWordsAtTheTop() throws {
        let auto = fitted("Hello", rect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.05))
        let tall = fitted("Hello", rect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.6), fixedWidth: true, fixedHeight: true)
        #expect(tall.height > auto.height * 3)
        let a = try #require(try R.render([R.layer(.text("Hello"), rect: auto, colour: white, fontSize: 0.06)], on: black)
            .ink(against: black))
        let b = try #require(try R.render([R.layer(.text("Hello"), rect: tall, colour: white, fontSize: 0.06)], on: black)
            .ink(against: black))
        #expect(abs(a.minY - b.minY) <= 1 && abs(a.height - b.height) <= 1, "\(a) vs \(b)")
    }

    /// A fixed width wraps the words inside it, and nothing is drawn past its edges.
    @Test func aFixedWidthWrapsInsideIt() throws {
        let rect = fitted("Save your changes before you go", rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05),
                          fixedWidth: true)
        let ink = try #require(try R.render([R.layer(.text("Save your changes before you go"), rect: rect,
                                                     colour: white, fontSize: 0.06)], on: black).ink(against: black))
        let box = R.pixels(rect)
        #expect(ink.minX >= box.minX - 1 && ink.maxX <= box.maxX + 1, "\(ink) inside \(box)")
        #expect(ink.height > 0.06 * 400 * 1.5, "wrapped onto more than one line")
    }
}

/// A whole drag of a label's handle, replayed a mouse step at a time through the canvas's own
/// arithmetic — `AnnotationGeometry.resize`, then the fitting the model applies — so a box
/// that jumps or lags behind the pointer fails here rather than in somebody's hand.
struct LabelDragTests {
    /// The canvas, in points, standing in for the frame: 1:1, so a normalised rect is the
    /// canvas rect over 400.
    private let frame = CGSize(width: 400, height: 400)
    private let white = ColorValue(r: 1, g: 1, b: 1)

    private func step(_ item: AnnotationItem, from start: CGRect, handle: AnnotationGeometry.Handle,
                      to point: CGPoint) -> AnnotationItem {
        let view = CGRect(x: start.minX * 400, y: start.minY * 400, width: start.width * 400, height: start.height * 400)
        let moved = AnnotationGeometry.resize(view, rotation: 0, dragging: handle, to: point,
                                              minimumSide: 8, keepingAspect: handle.isCorner)
        var next = item
        next.rect = CGRect(x: moved.minX / 400, y: moved.minY / 400, width: moved.width / 400, height: moved.height / 400)
        if !handle.isCorner, handle.direction.x != 0 { next.fixedWidth = true }
        if !handle.isCorner, handle.direction.y != 0 { next.fixedHeight = true }
        if handle.isCorner { next.fontSize = item.fontSize * moved.height / view.height }
        next.rect = AnnotationFit.fitted(next, frame: frame, setByCaller: true)
        return next
    }

    private func label(_ text: String) -> AnnotationItem {
        var item = AnnotationItem(start: .zero, duration: .zero, kind: .text(text),
                                  rect: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.05), color: white, fontSize: 0.05)
        item.rect = AnnotationFit.fitted(item, frame: frame, setByCaller: false)
        return item
    }

    @Test func theRightEdgeStaysUnderThePointer() {
        let start = label("Click Save to keep your work")
        for x in stride(from: 380.0, through: 120.0, by: -6) {
            let item = step(start, from: start.rect, handle: .right, to: CGPoint(x: x, y: 0))
            #expect(abs(item.rect.maxX * 400 - x) < 0.01, "pointer at \(x), edge at \(item.rect.maxX * 400)")
        }
    }

    @Test func theLeftEdgeStaysUnderThePointerAndTheRightStaysPut() {
        let start = label("Click Save")
        for x in stride(from: 10.0, through: 30.0, by: 2) {
            let item = step(start, from: start.rect, handle: .left, to: CGPoint(x: x, y: 0))
            #expect(abs(item.rect.minX * 400 - x) < 0.01)
            #expect(abs(item.rect.maxX - start.rect.maxX) < 1e-9)
        }
    }

    @Test func theBottomEdgeStaysUnderThePointerOnceTheLinesFit() {
        let start = label("Two\nlines")
        let lines = start.rect.maxY * 400
        for y in stride(from: lines + 4, through: 360, by: 8) {
            let item = step(start, from: start.rect, handle: .bottom, to: CGPoint(x: 0, y: y))
            #expect(abs(item.rect.maxY * 400 - y) < 0.01, "pointer at \(y), edge at \(item.rect.maxY * 400)")
        }
        // Above the last line, the lines win: never cut off.
        let squeezed = step(start, from: start.rect, handle: .bottom, to: CGPoint(x: 0, y: start.rect.minY * 400 + 4))
        #expect(abs(squeezed.rect.height - start.rect.height) < 1e-9)
    }

    @Test func aCornerScalesWithoutTheBoxJumping() {
        let start = label("Scale me")
        var lastWidth = 0.0
        for x in stride(from: start.rect.maxX * 400, through: 330, by: 5) {
            // Along the box's own diagonal, as a hand scaling it does.
            let y = start.rect.minY * 400 + (x - start.rect.minX * 400) * start.rect.height / start.rect.width
            let item = step(start, from: start.rect, handle: .bottomRight, to: CGPoint(x: x, y: y))
            #expect(item.rect.width >= lastWidth - 1e-6, "grows smoothly")
            #expect(item.rect.height < start.rect.height * (item.rect.width / start.rect.width) * 1.25,
                    "still one line: start \(start.rect) font \(start.fontSize) → \(item.rect) font \(item.fontSize)")
            lastWidth = item.rect.width
        }
    }
}

/// A callout's bubble, grown to its words when they get bigger.
struct CalloutFitTests {
    @Test(arguments: [0.02, 0.04, 0.08, 0.15])
    func theWordsFitOnOneLineInTheBubbleTheyAsk(fontSize: Double) throws {
        let frame = CGSize(width: 3_024, height: 1_898)
        let style = AnnotationStyle()
        let colour = ColorValue(r: 1, g: 0.2, b: 0.2)
        let bubble = AnnotationFit.calloutSize("Callout here", style: style, color: colour,
                                               fontSize: fontSize, frame: frame)
        // As the renderer lays the words out inside it.
        let size = max(8, frame.height * fontSize)
        let stroke = AnnotationArtwork.lineWidth(.callout("", tail: .zero), outputHeight: frame.height, thickness: 1)
        let inner = bubble.width * frame.width - stroke - size
        let text = AnnotationArtwork.words("Callout here",
                                           font: AnnotationArtwork.font(size: size, weight: style.weight),
                                           colour: colour, alignment: style.alignment)
        let one = AnnotationArtwork.measured(text, width: .greatestFiniteMagnitude)
        #expect(AnnotationArtwork.measured(text, width: inner).height <= one.height + 1)
        #expect(bubble.height * frame.height >= one.height + size * 0.5)
    }
}
