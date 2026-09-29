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
