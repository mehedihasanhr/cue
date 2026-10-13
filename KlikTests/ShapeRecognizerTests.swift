import CoreGraphics
import XCTest

/// Smart shapes: which freehand pencil strokes become a line, an ellipse, a rectangle or
/// an arrow, and which are left alone.
final class ShapeRecognizerTests: XCTestCase {
    // MARK: Stroke builders

    /// Points every `step` along straight runs between the given corners, with a small
    /// hand tremor so nothing is perfectly clean.
    private func stroke(_ corners: [CGPoint], step: CGFloat = 3, tremor: CGFloat = 1.5) -> [CGPoint] {
        var points: [CGPoint] = []
        var n = 0
        for (a, b) in zip(corners, corners.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y)
            let count = max(1, Int(length / step))
            for i in 0..<count {
                let t = CGFloat(i) / CGFloat(count)
                n += 1
                points.append(CGPoint(x: a.x + (b.x - a.x) * t + tremor * sin(CGFloat(n) * 0.7),
                                      y: a.y + (b.y - a.y) * t + tremor * cos(CGFloat(n) * 1.3)))
            }
        }
        points.append(corners.last!)
        return points
    }

    private func oval(center: CGPoint, rx: CGFloat, ry: CGFloat, turns: CGFloat = 1.05, wobble: CGFloat = 0.04) -> [CGPoint] {
        let count = 90
        return (0...count).map { i in
            let angle = CGFloat(i) / CGFloat(count) * turns * 2 * .pi
            let r = 1 + wobble * sin(angle * 5)
            return CGPoint(x: center.x + rx * r * cos(angle), y: center.y + ry * r * sin(angle))
        }
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: Lines

    func testStraightStrokeBecomesLine() {
        guard case .line(let start, let end) = ShapeRecognizer.recognize(stroke([p(10, 10), p(210, 90)])) else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(start.x, 10, accuracy: 3)
        XCTAssertEqual(end.x, 210, accuracy: 3)
    }

    func testCurveStaysAScribble() {
        let arc = (0...40).map { i -> CGPoint in
            let angle = CGFloat(i) / 40 * .pi
            return p(100 + 80 * cos(angle), 100 - 80 * sin(angle))
        }
        XCTAssertNil(ShapeRecognizer.recognize(arc))
    }

    // MARK: Ellipses

    func testRoundStrokeBecomesEllipse() {
        guard case .ellipse(let rect) = ShapeRecognizer.recognize(oval(center: p(150, 150), rx: 60, ry: 60)) else {
            return XCTFail("expected an ellipse")
        }
        XCTAssertEqual(rect.midX, 150, accuracy: 6)
        XCTAssertEqual(rect.width, 120, accuracy: 14)
    }

    func testFlatOvalBecomesEllipse() {
        guard case .ellipse = ShapeRecognizer.recognize(oval(center: p(200, 100), rx: 120, ry: 45)) else {
            return XCTFail("expected an ellipse")
        }
    }

    func testOvalThatStopsShortIsAlsoAnEllipse() {
        guard case .ellipse = ShapeRecognizer.recognize(oval(center: p(100, 100), rx: 50, ry: 40, turns: 0.93)) else {
            return XCTFail("expected an ellipse")
        }
    }

    // MARK: Rectangles

    func testBoxBecomesRectangle() {
        let box = stroke([p(20, 20), p(220, 22), p(218, 140), p(22, 138), p(21, 24)])
        guard case .rectangle(let rect) = ShapeRecognizer.recognize(box) else {
            return XCTFail("expected a rectangle")
        }
        XCTAssertEqual(rect.minX, 20, accuracy: 4)
        XCTAssertEqual(rect.maxY, 140, accuracy: 4)
    }

    func testBoxIsNotMistakenForEllipse() {
        let square = stroke([p(0, 0), p(100, 0), p(100, 100), p(0, 100), p(0, 4)])
        guard case .rectangle = ShapeRecognizer.recognize(square) else { return XCTFail("expected a rectangle") }
    }

    func testCircleIsNotMistakenForRectangle() {
        guard case .ellipse = ShapeRecognizer.recognize(oval(center: p(100, 100), rx: 70, ry: 70, wobble: 0.02)) else {
            return XCTFail("expected an ellipse")
        }
    }

    // MARK: Arrows

    func testShaftWithOneBarbBecomesArrow() {
        let drawn = stroke([p(20, 100), p(220, 100), p(195, 82)])
        guard case .arrow(let start, let end) = ShapeRecognizer.recognize(drawn) else {
            return XCTFail("expected an arrow")
        }
        XCTAssertEqual(start.x, 20, accuracy: 4)
        XCTAssertEqual(end.x, 220, accuracy: 6)
    }

    func testShaftWithBothBarbsBecomesArrow() {
        let drawn = stroke([p(40, 200), p(200, 40), p(170, 45), p(200, 40), p(195, 70)])
        guard case .arrow(let start, let end) = ShapeRecognizer.recognize(drawn) else {
            return XCTFail("expected an arrow")
        }
        XCTAssertEqual(start.y, 200, accuracy: 4)
        XCTAssertEqual(end.x, 200, accuracy: 8)
    }

    // MARK: Left alone

    func testZigzagStaysAScribble() {
        XCTAssertNil(ShapeRecognizer.recognize(stroke([p(0, 0), p(40, 60), p(80, 0), p(120, 60), p(160, 0)])))
    }

    func testVeeStaysAScribble() {
        XCTAssertNil(ShapeRecognizer.recognize(stroke([p(0, 0), p(60, 100), p(120, 0)])))
    }

    func testTinyStrokeIsIgnored() {
        XCTAssertNil(ShapeRecognizer.recognize(stroke([p(0, 0), p(8, 3)], step: 1, tremor: 0)))
    }

    func testHandwritingStaysAScribble() {
        // A loopy "e"-like squiggle that runs off to the side.
        let squiggle = (0...80).map { i -> CGPoint in
            let t = CGFloat(i) / 80 * 4 * .pi
            return p(20 * cos(t) + CGFloat(i) * 2.5, 20 * sin(t))
        }
        XCTAssertNil(ShapeRecognizer.recognize(squiggle))
    }
}
