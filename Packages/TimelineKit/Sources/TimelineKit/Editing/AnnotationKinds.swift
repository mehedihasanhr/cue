import CoreGraphics
import Foundation

extension AnnotationItem {
    /// A kind without its payload: what a menu, a picker or a lane label can name.
    ///
    /// `Kind` carries the words, the ends, the number — which is what makes it the thing
    /// that is drawn, and also what stops a menu offering it directly. This is the choice
    /// before the payload exists.
    public enum KindName: String, CaseIterable, Sendable, Identifiable {
        case text, arrow, rectangle, ellipse, loop, line, highlight, step, callout, image

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .text: "Text"
            case .arrow: "Arrow"
            case .rectangle: "Box"
            case .ellipse: "Ellipse"
            case .loop: "Loop"
            case .line: "Line"
            case .highlight: "Highlight"
            case .step: "Step"
            case .callout: "Callout"
            case .image: "Picture"
            }
        }

        /// What an annotation can be switched to from the inspector. A picture is not on
        /// the list: turning a logo into a box would throw the logo away.
        public static let switchable: [KindName] = [.text, .callout, .arrow, .line, .rectangle, .ellipse,
                                                    .loop, .highlight, .step]
    }

    /// The number a newly added step gets, the arithmetic of which is in
    /// `Timeline.nextStepNumber`.
    public static let stepRange: ClosedRange<Int> = 1...999

    /// Where a new callout's tail points, normalised to its bubble: below it and a little
    /// to the left, which is where the thing being pointed at usually is when the bubble
    /// is put above it.
    public static let defaultTail = CGPoint(x: 0.25, y: 1.8)

    /// The furthest a tail may reach from its bubble, in bubbles. Enough to point across
    /// the frame, not so much that a stray number makes a bitmap the size of a building.
    static let tailReach: ClosedRange<Double> = -3...4

    /// The part of `sanitise()` for kinds added after it was written.
    mutating func sanitiseNewerKinds() {
        switch kind {
        case .line(let from, let to):
            kind = .line(from: AnnotationGeometry.sanitised(from, default: CGPoint(x: 0, y: 1)),
                         to: AnnotationGeometry.sanitised(to, default: CGPoint(x: 1, y: 0)))
        case .step(let number):
            kind = .step(min(Self.stepRange.upperBound, max(Self.stepRange.lowerBound, number)))
        case .callout(let text, let tail):
            var tip = AnnotationGeometry.sanitised(tail, default: Self.defaultTail)
            tip.x = min(Self.tailReach.upperBound, max(Self.tailReach.lowerBound, tip.x))
            tip.y = min(Self.tailReach.upperBound, max(Self.tailReach.lowerBound, tip.y))
            kind = .callout(text, tail: tip)
        default:
            break
        }
    }
}

extension AnnotationItem.Kind {
    public var name: AnnotationItem.KindName {
        switch self {
        case .text: .text
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .image: .image
        case .ellipse: .ellipse
        case .loop: .loop
        case .line: .line
        case .highlight: .highlight
        case .step: .step
        case .callout: .callout
        }
    }

    /// What the lane calls it: the words, where there are words, since that is what tells
    /// two labels apart.
    public var label: String {
        switch self {
        case .text(let text), .callout(let text, _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? name.title : trimmed
        case .step(let number): return "Step \(number)"
        default: return name.title
        }
    }

    /// The words, for a kind that has any.
    public var text: String? {
        switch self {
        case .text(let text), .callout(let text, _): text
        default: nil
        }
    }

    /// The same kind saying something else. A kind with no words is returned as it was.
    public func withText(_ text: String) -> Self {
        switch self {
        case .text: .text(text)
        case .callout(_, let tail): .callout(text, tail: tail)
        default: self
        }
    }

    /// An arrow's or a line's two ends, normalised to the rect.
    public var ends: (from: CGPoint, to: CGPoint)? {
        switch self {
        case .arrow(let from, let to), .line(let from, let to): (from, to)
        default: nil
        }
    }

    /// The same kind with its ends moved. Anything without ends is returned as it was.
    public func withEnds(from: CGPoint, to: CGPoint) -> Self {
        switch self {
        case .arrow: .arrow(from: from, to: to)
        case .line: .line(from: from, to: to)
        default: self
        }
    }

    /// Drawn as an outline or a stroke, so its thickness can be set.
    public var hasThickness: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse, .loop: true
        default: false
        }
    }

    /// A shape, so it can be drawn on — and rubbed out — a stroke at a time: the Draw
    /// entrance and the Erase exit trace its outline. A highlight is swept on like a marker;
    /// a step's ring and a callout's bubble go round and then fill, their words last. Only a
    /// label and a picture, which have no outline to follow, fade instead.
    public var canBeTraced: Bool {
        switch self {
        case .text, .image: false
        default: true
        }
    }

    /// A closed shape that can be filled.
    public var canBeFilled: Bool {
        switch self {
        case .rectangle, .ellipse: true
        default: false
        }
    }

    /// Made of words, so the type settings apply.
    public var hasWords: Bool { text != nil }

    /// This annotation as another kind, keeping whatever of it still means something.
    ///
    /// Words stay words between a label and a callout, and ends stay ends between an arrow
    /// and a line. Anything that has nothing to carry over gets something that draws —
    /// never an empty label, which draws no pixels and would look like the switch had
    /// deleted it.
    public func converted(to name: AnnotationItem.KindName, nextStep: Int) -> Self {
        guard name != self.name else { return self }
        let words = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let diagonal = (from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0))
        switch name {
        case .text: return .text(words ?? "Text")
        case .callout: return .callout(words ?? "Callout", tail: AnnotationItem.defaultTail)
        case .arrow:
            let ends = ends ?? diagonal
            return .arrow(from: ends.from, to: ends.to)
        case .line:
            let ends = ends ?? diagonal
            return .line(from: ends.from, to: ends.to)
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .loop: return .loop
        case .highlight: return .highlight
        case .step:
            if case .step = self { return self }
            return .step(nextStep)
        case .image: return self
        }
    }
}

extension Timeline {
    /// The number the next step gets: one more than the highest already on the timeline.
    ///
    /// The highest rather than a count, so deleting step 2 of three does not make the next
    /// one a second "3"; and read from the timeline itself rather than kept in a counter,
    /// so an undo that brings a step back, or one that takes it away, is reflected with no
    /// book-keeping at all.
    public var nextStepNumber: Int {
        let highest = annotations.reduce(0) { highest, item in
            if case .step(let number) = item.kind { max(highest, number) } else { highest }
        }
        return min(AnnotationItem.stepRange.upperBound, highest + 1)
    }
}

// MARK: - Ends and tails

extension AnnotationGeometry {
    /// A point normalised to `rect` — 0…1 inside it, and anywhere outside — as a point on
    /// the picture, with the rect turned by `rotation` degrees about its centre.
    public static func point(_ local: CGPoint, in rect: CGRect, rotation: Double) -> CGPoint {
        let offset = CGVector(dx: (local.x - 0.5) * rect.width, dy: (local.y - 0.5) * rect.height)
        let turned = rotated(offset, by: rotation)
        return CGPoint(x: rect.midX + turned.dx, y: rect.midY + turned.dy)
    }

    /// The other way: a point on the picture, normalised to the turned `rect`.
    public static func local(_ point: CGPoint, in rect: CGRect, rotation: Double) -> CGPoint {
        let offset = rotated(CGVector(dx: point.x - rect.midX, dy: point.y - rect.midY), by: -rotation)
        return CGPoint(x: 0.5 + offset.dx / max(rect.width, .ulpOfOne),
                       y: 0.5 + offset.dy / max(rect.height, .ulpOfOne))
    }

    /// The rect and the two ends of a line whose ends are at `from` and `to` on the picture.
    ///
    /// Moving one end of an arrow rebuilds its box around the two ends, unturned: a line is
    /// the same line whichever box it is described in, and a box that always fits its ends
    /// is one whose outline and handles sit on the drawing. A line that is flat or upright
    /// would have a box of no height or width, so the box is at least `minimumSide` across
    /// both ways, centred on the line.
    ///
    /// In a square space — view points or output pixels — like everything else here.
    public static func ends(from: CGPoint, to: CGPoint, minimumSide: Double) -> (rect: CGRect, from: CGPoint, to: CGPoint) {
        var rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y))
        if rect.width < minimumSide { rect = rect.insetBy(dx: (rect.width - minimumSide) / 2, dy: 0) }
        if rect.height < minimumSide { rect = rect.insetBy(dx: 0, dy: (rect.height - minimumSide) / 2) }
        return (rect, local(from, in: rect, rotation: 0), local(to, in: rect, rotation: 0))
    }
}
