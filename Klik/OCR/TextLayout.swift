import CoreGraphics

/// Turns Vision's unordered line observations into text a person would expect to
/// paste: top-to-bottom, left-to-right, one line per visual line, and a blank line
/// wherever the vertical gap is clearly larger than the line spacing.
///
/// Deliberately simple — no column or table detection — but enough that a recipe or
/// a settings pane comes out as lines rather than one long sentence.
nonisolated enum TextLayout {
    /// Which way a line reads. Arabic, Hebrew, Persian and Urdu put the first word on
    /// the right, so the fragments of a line have to be joined the other way round —
    /// and leading spaces mean the opposite of what they look like, so indentation is
    /// left off entirely.
    nonisolated enum Direction: Sendable {
        case leftToRight, rightToLeft
    }

    /// Fraction of the shorter box's height two boxes must overlap vertically to be
    /// considered the same line.
    static let sameLineOverlap: CGFloat = 0.5
    /// A vertical gap larger than this many line heights becomes a paragraph break.
    static let paragraphGapRatio: CGFloat = 0.9

    /// `keepIndentation`: lines that start to the right of the leftmost one get the
    /// matching number of leading spaces (a character's width estimated from each
    /// line), so code keeps its shape.
    static func compose(_ items: [RecognizedTextItem], keepIndentation: Bool = false,
                        direction: Direction = .leftToRight) -> String {
        let lines = groupIntoLines(items)
        guard !lines.isEmpty else { return "" }
        let leftmost = lines.map(\.bounds.minX).min() ?? 0

        var output: [String] = []
        var previous: Line?
        for line in lines {
            if let previous {
                // Vision's y axis points up: the gap is from the previous line's bottom to this top.
                let gap = previous.bounds.minY - line.bounds.maxY
                let reference = min(previous.bounds.height, line.bounds.height)
                if reference > 0, gap > reference * paragraphGapRatio {
                    output.append("")
                }
            }
            var text = line.text(direction: direction)
            if keepIndentation, direction == .leftToRight {
                let characterWidth = line.bounds.width / CGFloat(max(text.count, 1))
                let indent = characterWidth > 0 ? Int(((line.bounds.minX - leftmost) / characterWidth).rounded()) : 0
                if indent > 0 { text = String(repeating: " ", count: min(indent, 40)) + text }
            }
            output.append(text)
            previous = line
        }
        return output.joined(separator: "\n")
    }

    // MARK: - Lines

    struct Line {
        var items: [RecognizedTextItem]
        var bounds: CGRect

        var text: String { text(direction: .leftToRight) }

        func text(direction: Direction) -> String {
            let ordered = direction == .rightToLeft
                ? items.sorted { $0.boundingBox.minX > $1.boundingBox.minX }
                : items.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            return ordered.map(\.text).joined(separator: " ")
        }
    }

    /// Items sorted top-to-bottom, merged into lines when they overlap vertically.
    static func groupIntoLines(_ items: [RecognizedTextItem]) -> [Line] {
        let ordered = items.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var lines: [Line] = []
        for item in ordered {
            if var last = lines.last, overlapsVertically(last.bounds, item.boundingBox) {
                last.items.append(item)
                last.bounds = last.bounds.union(item.boundingBox)
                lines[lines.count - 1] = last
            } else {
                lines.append(Line(items: [item], bounds: item.boundingBox))
            }
        }
        return lines
    }

    private static func overlapsVertically(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let reference = min(a.height, b.height)
        guard reference > 0 else { return false }
        return overlap / reference >= sameLineOverlap
    }
}
