import CoreGraphics
import Foundation

/// Turns a freehand pencil stroke into the shape it was meant to be: a straight line, an
/// ellipse, a rectangle or an arrow. Anything it isn't sure about stays a scribble.
///
/// Pure geometry on the stroke's points, so it is tested without a window. The checks run
/// from the most particular shape to the least, and every one has to pass outright: a
/// wrong guess is worse than none, since it rewrites what was drawn.
enum ShapeRecognizer {
    enum Shape: Equatable {
        case line(start: CGPoint, end: CGPoint)
        case ellipse(CGRect)
        case rectangle(CGRect)
        case arrow(start: CGPoint, end: CGPoint)
    }

    static func recognize(_ raw: [CGPoint]) -> Shape? {
        let points = dedupe(raw)
        guard points.count >= 3 else { return nil }
        let length = pathLength(points)
        let bounds = boundingBox(points)
        let diagonal = hypot(bounds.width, bounds.height)
        // Too small to be anything on purpose: a tick, a dot.
        guard length >= 24, diagonal >= 16 else { return nil }

        let gap = gapBetween(points.first!, points.last!)
        // A circle runs about 2.2 times its box's diagonal, a square 2.8, a line 1.
        let closed = gap < 0.25 * diagonal && length > 1.8 * diagonal

        if closed {
            if let rectangle = rectangle(points, bounds: bounds, diagonal: diagonal) { return rectangle }
            if let ellipse = ellipse(points, bounds: bounds) { return ellipse }
            return nil
        }
        if let line = line(points, length: length) { return line }
        if let arrow = arrow(points, length: length, diagonal: diagonal) { return arrow }
        return nil
    }

    // MARK: - Line

    /// Nearly as long end to end as along the way, and never far off the chord.
    private static func line(_ points: [CGPoint], length: CGFloat) -> Shape? {
        let start = points.first!, end = points.last!
        let chord = gapBetween(start, end)
        guard chord / length > 0.9 else { return nil }
        let deviation = points.map { distance(from: $0, toSegment: start, end) }.max() ?? 0
        guard deviation < max(5, 0.08 * chord) else { return nil }
        return .line(start: start, end: end)
    }

    // MARK: - Ellipse

    /// Every point close to the ellipse inscribed in the stroke's box, and the stroke goes
    /// most of the way round it.
    private static func ellipse(_ points: [CGPoint], bounds: CGRect) -> Shape? {
        let rx = bounds.width / 2, ry = bounds.height / 2
        guard rx > 4, ry > 4 else { return nil }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var errors: [CGFloat] = []
        var angles: [CGFloat] = []
        for p in points {
            let nx = (p.x - center.x) / rx, ny = (p.y - center.y) / ry
            errors.append(abs(hypot(nx, ny) - 1))
            angles.append(atan2(ny, nx))
        }
        let mean = errors.reduce(0, +) / CGFloat(errors.count)
        guard mean < 0.11, (errors.max() ?? 1) < 0.35 else { return nil }
        guard sweep(angles) > 1.75 * .pi else { return nil }
        return .ellipse(bounds)
    }

    /// How far round the centre the stroke travels, in radians.
    private static func sweep(_ angles: [CGFloat]) -> CGFloat {
        var total: CGFloat = 0
        for (a, b) in zip(angles, angles.dropFirst()) {
            var step = b - a
            if step > .pi { step -= 2 * .pi }
            if step < -.pi { step += 2 * .pi }
            total += step
        }
        return abs(total)
    }

    // MARK: - Rectangle

    /// Four sharp corners, close to the corners of the stroke's box, with every point
    /// hugging one of the box's edges.
    private static func rectangle(_ points: [CGPoint], bounds: CGRect, diagonal: CGFloat) -> Shape? {
        guard bounds.width > 8, bounds.height > 8 else { return nil }
        let edgeTolerance = max(6, 0.09 * min(bounds.width, bounds.height) + 0.03 * diagonal)
        var offEdge = 0
        var total: CGFloat = 0
        for p in points {
            let d = min(abs(p.x - bounds.minX), abs(p.x - bounds.maxX), abs(p.y - bounds.minY), abs(p.y - bounds.maxY))
            total += d
            if d > edgeTolerance { offEdge += 1 }
        }
        guard CGFloat(offEdge) / CGFloat(points.count) < 0.06, total / CGFloat(points.count) < edgeTolerance * 0.5 else { return nil }

        // An ellipse hugs its box only at four points; a rectangle reaches every corner.
        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                       CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)]
        let reach = max(8, 0.16 * min(bounds.width, bounds.height))
        for corner in corners {
            let nearest = points.map { gapBetween($0, corner) }.min() ?? .infinity
            guard nearest < reach else { return nil }
        }
        return .rectangle(bounds)
    }

    // MARK: - Arrow

    /// One stroke: a long shaft, then a short head drawn back from its tip. Simplified to
    /// its corners, the shaft is the first long run and everything after it stays near
    /// the tip, turning back at an arrowhead's angle.
    private static func arrow(_ points: [CGPoint], length: CGFloat, diagonal: CGFloat) -> Shape? {
        let corners = simplify(points, tolerance: max(4, 0.05 * diagonal))
        guard corners.count >= 3 else { return nil }

        // The shaft ends at the corner where the stroke first turns back on itself.
        for tipIndex in 1..<(corners.count - 1) {
            let start = corners[0], tip = corners[tipIndex]
            let shaft = gapBetween(start, tip)
            guard shaft > 0.45 * length else { continue }
            // The shaft itself must be straight.
            let tipInPoints = points.firstIndex(of: tip) ?? 0
            let deviation = points[...tipInPoints].map { distance(from: $0, toSegment: start, tip) }.max() ?? 0
            guard deviation < max(6, 0.1 * shaft) else { continue }

            let head = Array(corners[(tipIndex + 1)...])
            // The head stays near the tip.
            guard head.allSatisfy({ gapBetween($0, tip) < 0.5 * shaft }) else { continue }
            // At least one barb points back along the shaft, splayed to the side.
            let back = CGVector(dx: start.x - tip.x, dy: start.y - tip.y)
            let barbs = head.filter { corner in
                let barb = CGVector(dx: corner.x - tip.x, dy: corner.y - tip.y)
                let size = hypot(barb.dx, barb.dy)
                guard size > max(5, 0.08 * shaft) else { return false }
                let angle = angleBetween(back, barb)
                return angle > .pi / 14 && angle < .pi * 0.45
            }
            guard !barbs.isEmpty else { continue }
            return .arrow(start: start, end: tip)
        }
        return nil
    }

    // MARK: - Geometry

    private static func dedupe(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in points where out.last.map({ gapBetween($0, p) > 0.5 }) ?? true { out.append(p) }
        return out
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) { total += gapBetween(a, b) }
        return total
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Own helper rather than the app's `CGPoint.distance(to:)`, so the tests build this
    /// file alone.
    private static func gapBetween(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return gapBetween(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return gapBetween(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private static func angleBetween(_ a: CGVector, _ b: CGVector) -> CGFloat {
        let dot = a.dx * b.dx + a.dy * b.dy
        let sizes = hypot(a.dx, a.dy) * hypot(b.dx, b.dy)
        guard sizes > 0 else { return .pi }
        return acos(max(-1, min(1, dot / sizes)))
    }

    /// Ramer–Douglas–Peucker: the stroke reduced to the corners that matter.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first, farthestDistance: CGFloat = 0
            for i in (first + 1)..<last {
                let d = distance(from: points[i], toSegment: points[first], points[last])
                if d > farthestDistance { farthest = i; farthestDistance = d }
            }
            if farthestDistance > tolerance {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}
