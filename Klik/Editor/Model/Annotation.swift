import AppKit

/// A color as plain data so the model stays a value type.
struct RGBA: Hashable, Codable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { nsColor.cgColor }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent; a = c.alphaComponent
    }

    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    static let red = RGBA(r: 1, g: 0.23, b: 0.19)
    static let orange = RGBA(r: 1, g: 0.58, b: 0)
    static let yellow = RGBA(r: 1, g: 0.84, b: 0.04)
    static let green = RGBA(r: 0.2, g: 0.78, b: 0.35)
    static let blue = RGBA(r: 0.04, g: 0.52, b: 1)
    static let purple = RGBA(r: 0.69, g: 0.32, b: 0.87)
    static let pink = RGBA(r: 1, g: 0.18, b: 0.33)
    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let gray = RGBA(r: 0.56, g: 0.56, b: 0.58)

    static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .white, .black, .gray]
}

struct StrokeStyle: Hashable, Codable {
    var color: RGBA
    var width: CGFloat
}

enum FillMode: String, Hashable, Codable, CaseIterable {
    case none
    case solid
    case translucent
}

struct ShapeStyle: Hashable, Codable {
    var stroke: StrokeStyle
    var fill: FillMode
}

enum ArrowStyle: String, Hashable, Codable, CaseIterable {
    case single
    case double
}

enum TextBackground: String, Hashable, Codable, CaseIterable {
    case none
    case solid
    case translucent
}

struct TextStyle: Hashable, Codable {
    var color: RGBA
    var fontSize: CGFloat
    var background: TextBackground
    /// `NSFont.Weight` raw value: −0.4 light … 0 regular … 0.4 bold … 0.62 black.
    var weight: CGFloat = TextStyle.defaultWeight

    static let defaultSize: CGFloat = 15
    static let defaultWeight: CGFloat = 0.3 // semibold
    static let weightRange: ClosedRange<CGFloat> = -0.4...0.62

    var weightName: String {
        switch weight {
        case ..<(-0.3): "Light"
        case ..<0.12: "Regular"
        case ..<0.27: "Medium"
        case ..<0.35: "Semibold"
        case ..<0.5: "Bold"
        case ..<0.6: "Heavy"
        default: "Black"
        }
    }
}

enum BlurKind: String, Hashable, Codable, CaseIterable {
    case blur
    case pixelate
}

/// Everything the user can draw. Coordinates are image points (origin top-left, y down).
enum AnnotationKind: Hashable, Codable {
    case rectangle(rect: CGRect, style: ShapeStyle)
    case ellipse(rect: CGRect, style: ShapeStyle)
    case line(start: CGPoint, end: CGPoint, style: StrokeStyle)
    /// `bend` offsets the curve's control point from the midpoint; `.zero` is a straight arrow.
    case arrow(start: CGPoint, end: CGPoint, bend: CGPoint, style: StrokeStyle, arrowStyle: ArrowStyle)
    case pencil(points: [CGPoint], style: StrokeStyle)
    case highlighter(points: [CGPoint], style: StrokeStyle)
    /// Marker-style box behind text: translucent multiply fill, rounded corners.
    case highlight(rect: CGRect, color: RGBA)
    case text(origin: CGPoint, text: String, style: TextStyle)
    case counter(center: CGPoint, number: Int, color: RGBA, size: CGFloat)
    case blur(rect: CGRect, kind: BlurKind, intensity: CGFloat)
}

struct Annotation: Identifiable, Hashable, Codable {
    let id: UUID
    var kind: AnnotationKind
    /// Radians, clockwise on screen, about the centre of `bounds`. Only `canRotate` kinds use it.
    var rotation: CGFloat = 0

    init(id: UUID = UUID(), kind: AnnotationKind, rotation: CGFloat = 0) {
        self.id = id
        self.kind = kind
        self.rotation = rotation
    }

    private enum CodingKeys: String, CodingKey { case id, kind, rotation }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(AnnotationKind.self, forKey: .kind)
        rotation = try container.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
    }
}

// MARK: - Rotation

extension Annotation {
    /// Boxes and text turn about their centre; strokes, arrows and counters don't rotate.
    var canRotate: Bool {
        switch kind {
        case .rectangle, .ellipse, .highlight, .text: true
        default: false
        }
    }

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// `point` (image space) expressed in the annotation's own, unrotated frame.
    func localPoint(_ point: CGPoint) -> CGPoint {
        rotation == 0 ? point : Self.rotate(point, by: -rotation, around: center)
    }

    /// A point of the unrotated frame placed where it appears on screen.
    func worldPoint(_ point: CGPoint) -> CGPoint {
        rotation == 0 ? point : Self.rotate(point, by: rotation, around: center)
    }

    func withRotation(_ angle: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = canRotate ? angle : 0
        return copy
    }

    static func rotate(_ point: CGPoint, by angle: CGFloat, around center: CGPoint) -> CGPoint {
        let dx = point.x - center.x, dy = point.y - center.y
        let c = cos(angle), s = sin(angle)
        return CGPoint(x: center.x + dx * c - dy * s, y: center.y + dx * s + dy * c)
    }
}

// MARK: - Geometry helpers

extension Annotation {
    /// Axis-aligned bounds in image points (stroke width not included).
    var bounds: CGRect {
        switch kind {
        case .rectangle(let rect, _), .ellipse(let rect, _), .blur(let rect, _, _), .highlight(let rect, _):
            return rect
        case .line(let a, let b, _):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        case .arrow(let a, let b, let bend, _, _):
            return Self.bounds(of: ArrowGeometry.points(start: a, end: b, bend: bend))
        case .pencil(let points, _), .highlighter(let points, _):
            return Self.bounds(of: points)
        case .text(let origin, let text, let style):
            let size = TextMetrics.size(of: text, style: style)
            return CGRect(origin: origin, size: size)
        case .counter(let center, _, _, let size):
            return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        }
    }

    /// Whether the bounds can be resized with handles (as opposed to moved only).
    var isResizable: Bool {
        switch kind {
        case .rectangle, .ellipse, .blur, .highlight: true
        default: false
        }
    }

    var hasEndpoints: Bool {
        switch kind {
        case .line, .arrow: true
        default: false
        }
    }

    func moved(by delta: CGPoint) -> Annotation {
        var copy = self
        switch kind {
        case .rectangle(let rect, let style):
            copy.kind = .rectangle(rect: rect.offsetBy(dx: delta.x, dy: delta.y), style: style)
        case .ellipse(let rect, let style):
            copy.kind = .ellipse(rect: rect.offsetBy(dx: delta.x, dy: delta.y), style: style)
        case .blur(let rect, let k, let i):
            copy.kind = .blur(rect: rect.offsetBy(dx: delta.x, dy: delta.y), kind: k, intensity: i)
        case .highlight(let rect, let color):
            copy.kind = .highlight(rect: rect.offsetBy(dx: delta.x, dy: delta.y), color: color)
        case .line(let a, let b, let style):
            copy.kind = .line(start: a + delta, end: b + delta, style: style)
        case .arrow(let a, let b, let bend, let style, let arrowStyle):
            copy.kind = .arrow(start: a + delta, end: b + delta, bend: bend, style: style, arrowStyle: arrowStyle)
        case .pencil(let points, let style):
            copy.kind = .pencil(points: points.map { $0 + delta }, style: style)
        case .highlighter(let points, let style):
            copy.kind = .highlighter(points: points.map { $0 + delta }, style: style)
        case .text(let origin, let text, let style):
            copy.kind = .text(origin: origin + delta, text: text, style: style)
        case .counter(let center, let n, let color, let size):
            copy.kind = .counter(center: center + delta, number: n, color: color, size: size)
        }
        return copy
    }

    func withRect(_ rect: CGRect) -> Annotation {
        var copy = self
        switch kind {
        case .rectangle(_, let style): copy.kind = .rectangle(rect: rect, style: style)
        case .ellipse(_, let style): copy.kind = .ellipse(rect: rect, style: style)
        case .blur(_, let k, let i): copy.kind = .blur(rect: rect, kind: k, intensity: i)
        case .highlight(_, let color): copy.kind = .highlight(rect: rect, color: color)
        default: break
        }
        return copy
    }

    func withEndpoints(start: CGPoint, end: CGPoint) -> Annotation {
        var copy = self
        switch kind {
        case .line(_, _, let style): copy.kind = .line(start: start, end: end, style: style)
        case .arrow(_, _, let bend, let style, let arrowStyle): copy.kind = .arrow(start: start, end: end, bend: bend, style: style, arrowStyle: arrowStyle)
        default: break
        }
        return copy
    }

    /// Arrows only: the curve's control offset. Anything else is returned unchanged.
    func withBend(_ bend: CGPoint) -> Annotation {
        var copy = self
        if case .arrow(let a, let b, _, let style, let arrowStyle) = kind {
            copy.kind = .arrow(start: a, end: b, bend: bend, style: style, arrowStyle: arrowStyle)
        }
        return copy
    }

    var arrowBend: CGPoint? {
        if case .arrow(_, _, let bend, _, _) = kind { return bend }
        return nil
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

extension CGRect {
    static func spanning(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

/// Text measurement shared by the model, renderer and inline editor.
enum TextMetrics {
    static let padding = CGSize(width: 8, height: 4)

    static func font(for style: TextStyle) -> NSFont {
        .systemFont(ofSize: style.fontSize, weight: NSFont.Weight(rawValue: style.weight))
    }

    static func attributes(for style: TextStyle) -> [NSAttributedString.Key: Any] {
        [.font: font(for: style), .foregroundColor: style.color.nsColor]
    }

    static func size(of text: String, style: TextStyle) -> CGSize {
        let measured = (text.isEmpty ? "Text" : text).size(withAttributes: attributes(for: style))
        return CGSize(width: ceil(measured.width) + padding.width * 2, height: ceil(measured.height) + padding.height * 2)
    }
}

/// Quadratic-curve helpers shared by the renderer, hit testing and the canvas handles.
/// The control point is `midpoint + bend`; the curve passes through `midpoint + bend / 2`.
nonisolated enum ArrowGeometry {
    static func control(start: CGPoint, end: CGPoint, bend: CGPoint) -> CGPoint {
        CGPoint(x: (start.x + end.x) / 2 + bend.x, y: (start.y + end.y) / 2 + bend.y)
    }

    /// Where the middle (bend) handle sits: on the curve at t = 0.5.
    static func handlePoint(start: CGPoint, end: CGPoint, bend: CGPoint) -> CGPoint {
        CGPoint(x: (start.x + end.x) / 2 + bend.x / 2, y: (start.y + end.y) / 2 + bend.y / 2)
    }

    /// The bend that puts the middle handle at `point`.
    static func bend(forHandleAt point: CGPoint, start: CGPoint, end: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - (start.x + end.x) / 2) * 2, y: (point.y - (start.y + end.y) / 2) * 2)
    }

    static func point(at t: CGFloat, start: CGPoint, end: CGPoint, bend: CGPoint) -> CGPoint {
        let c = control(start: start, end: end, bend: bend)
        let u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * c.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * c.y + t * t * end.y)
    }

    /// Unit tangent at `t` (direction of travel), or the chord direction for a degenerate curve.
    static func tangent(at t: CGFloat, start: CGPoint, end: CGPoint, bend: CGPoint) -> CGPoint {
        let c = control(start: start, end: end, bend: bend)
        var d = CGPoint(x: 2 * (1 - t) * (c.x - start.x) + 2 * t * (end.x - c.x),
                        y: 2 * (1 - t) * (c.y - start.y) + 2 * t * (end.y - c.y))
        var length = hypot(d.x, d.y)
        if length < 0.001 {
            d = CGPoint(x: end.x - start.x, y: end.y - start.y)
            length = max(hypot(d.x, d.y), 0.001)
        }
        return CGPoint(x: d.x / length, y: d.y / length)
    }

    /// The curve flattened into a polyline (straight arrows give the two endpoints).
    static func points(start: CGPoint, end: CGPoint, bend: CGPoint, samples: Int = 24) -> [CGPoint] {
        guard bend != .zero else { return [start, end] }
        return (0...samples).map { point(at: CGFloat($0) / CGFloat(samples), start: start, end: end, bend: bend) }
    }
}
