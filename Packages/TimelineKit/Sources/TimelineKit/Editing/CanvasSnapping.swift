import CoreGraphics
import Foundation

/// Where a box being dragged on the picture wants to stop: lined up with the frame or with
/// another box, as every layout tool lines things up.
///
/// A label nudged by eye to the middle of the frame is a few points off it, and nobody can
/// see by how many until the export is on a big screen. So a box's edges and centre are
/// drawn to the frame's edges and centre lines, and to the edges and centres of the other
/// boxes showing at the moment, when they come within `threshold` — and a guide line says
/// what it has lined up with. Worked in the canvas's own points, so the pull feels the same
/// at any zoom of the editor.
public enum CanvasSnapping {
    public struct Guide: Equatable, Sendable {
        public enum Axis: Sendable { case vertical, horizontal }
        public let axis: Axis
        /// The x of a vertical guide, the y of a horizontal one.
        public let position: Double
        /// How far the line runs along its own direction.
        public let from: Double
        public let to: Double
    }

    /// `rect` moved to line up, and the guides to show. Unchanged, with no guides, when
    /// nothing is within `threshold`.
    public static func snap(_ rect: CGRect, to others: [CGRect], stage: CGRect,
                            threshold: Double = 6) -> (rect: CGRect, guides: [Guide]) {
        var snapped = rect
        var guides: [Guide] = []

        // Each axis on its own: lining up across and lining up down are separate wishes.
        let targets = [stage] + others
        if let x = best(of: [rect.minX, rect.midX, rect.maxX],
                        against: targets.flatMap { [$0.minX, $0.midX, $0.maxX] }, threshold: threshold) {
            snapped.origin.x += x.shift
            let spans = targets.filter { abs($0.minX - x.line) < 0.5 || abs($0.midX - x.line) < 0.5 || abs($0.maxX - x.line) < 0.5 }
            let top = (spans + [snapped]).map(\.minY).min() ?? snapped.minY
            let bottom = (spans + [snapped]).map(\.maxY).max() ?? snapped.maxY
            guides.append(Guide(axis: .vertical, position: x.line, from: top, to: bottom))
        }
        if let y = best(of: [rect.minY, rect.midY, rect.maxY],
                        against: targets.flatMap { [$0.minY, $0.midY, $0.maxY] }, threshold: threshold) {
            snapped.origin.y += y.shift
            let spans = targets.filter { abs($0.minY - y.line) < 0.5 || abs($0.midY - y.line) < 0.5 || abs($0.maxY - y.line) < 0.5 }
            let left = (spans + [snapped]).map(\.minX).min() ?? snapped.minX
            let right = (spans + [snapped]).map(\.maxX).max() ?? snapped.maxX
            guides.append(Guide(axis: .horizontal, position: y.line, from: left, to: right))
        }
        return (snapped, guides)
    }

    /// The smallest move that puts one of `mine` on one of `lines`, if it is small enough.
    private static func best(of mine: [Double], against lines: [Double],
                             threshold: Double) -> (shift: Double, line: Double)? {
        var found: (shift: Double, line: Double)?
        for value in mine {
            for line in lines {
                let shift = line - value
                guard abs(shift) <= threshold else { continue }
                if found == nil || abs(shift) < abs(found!.shift) { found = (shift, line) }
            }
        }
        return found
    }
}
