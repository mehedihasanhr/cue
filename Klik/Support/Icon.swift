import AppKit
import SwiftUI

/// An icon named by its SF Symbol. The island draws it from Hugeicons' stroke set
/// (a matching icon for every symbol it shows); a name with no match is the symbol
/// itself, so one name works in every window.
///
/// `size` is the icon's box — a symbol at font size 12 is about a 15-point box —
/// and `weight` the stroke: regular is Hugeicons' own 1.5 on a 24 grid.
struct Icon: View {
    let name: String
    var size: CGFloat = 14
    var weight: Font.Weight = .regular

    init(_ name: String, size: CGFloat = 14, weight: Font.Weight = .regular) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    var body: some View {
        if let image = HugeIcons.image(name, size: size, weight: weight) {
            Image(nsImage: image).renderingMode(.template)
        } else {
            Image(systemName: name)
                .font(.system(size: size * 0.8, weight: weight))
                .frame(width: size, height: size)
        }
    }
}

/// Hugeicons' stroke icons (the free set, MIT) as template images, one per SF Symbol
/// name the app uses, drawn at the size asked for and kept.
enum HugeIcons {
    /// The Hugeicons icon that stands in for each SF Symbol.
    static let names: [String: String] = [
        "square.grid.2x2": "DashboardSquare01",
        "tray.full": "Archive02",
        "tray": "Inbox",
        "tray.and.arrow.down": "ArchiveArrowDown",
        "tray.and.arrow.down.fill": "ArchiveArrowDown",
        "checklist": "CheckList",
        "note.text": "Note01",
        "note.text.badge.plus": "NoteAdd",
        "paperplane": "Sent",
        "paperplane.fill": "Sent",
        "photo.on.rectangle": "Album02",
        "photo": "Image01",
        "camera.viewfinder": "Camera01",
        "paintpalette": "PaintBoard",
        "paintpalette.fill": "PaintBoard",
        "text.badge.plus": "TextCreation",
        "text.badge.checkmark": "TaskDone01",
        "doc.on.clipboard": "Clipboard",
        "arrow.down.doc": "ClipboardPaste",
        "clock": "Clock01",
        "clock.fill": "Clock01",
        "clock.arrow.circlepath": "Clock04",
        "timer": "Timer01",
        "calendar": "Calendar03",
        "pin": "Pin",
        "pin.fill": "Pin",
        "pin.slash.fill": "PinOff",
        "plus": "PlusSign",
        "plus.circle": "PlusSignCircle",
        "folder": "Folder01",
        "folder.fill": "Folder02",
        "folder.badge.plus": "FolderAdd",
        "folder.fill.badge.plus": "FolderAdd",
        "magnifyingglass": "Search01",
        "xmark": "Cancel01",
        "xmark.circle.fill": "CancelCircle",
        "trash": "Delete02",
        "trash.fill": "Delete02",
        "eyedropper": "ColorPicker",
        "display": "Computer",
        "viewfinder": "FullScreen",
        "macwindow": "AppWindowMac",
        "app": "AppWindowMac",
        "rectangle.expand.vertical": "SquareArrowVertical",
        "text.viewfinder": "ScanText",
        "gearshape": "Settings01",
        "chevron.down": "ArrowDown01",
        "chevron.left": "ArrowLeft01",
        "chevron.right": "ArrowRight01",
        "chevron.up": "ArrowUp01",
        "chevron.up.2": "ArrowUpDouble",
        "checkmark": "Tick02",
        "checkmark.circle.fill": "CheckmarkCircle02",
        "pencil": "PencilEdit02",
        "eye": "View",
        "eye.circle.fill": "View",
        "doc.on.doc": "Copy01",
        "doc": "File01",
        "link": "Link01",
        "stop.fill": "Stop",
        "arrow.up": "ArrowUp02",
        "arrow.up.forward": "ArrowUpRight01",
        "arrow.up.forward.app": "LinkSquare02",
        "arrow.up.left.and.arrow.down.right": "ArrowExpand01",
        "arrow.down.fill": "Download04",
        "aspectratio": "AspectRatio",
        "info.circle": "InformationCircle",
        "number": "Hashtag",
        "number.square": "Hashtag",
        "text.alignleft": "TextAlignLeft",
        "character": "TextFont",
        "safari": "Globe02",
        "globe": "Globe02",
        "list.bullet": "LeftToRightListBullet",
        "list.number": "LeftToRightListNumber",
        "text.quote": "LeftToRightBlockQuote",
        "bold": "TextBold",
        "italic": "TextItalic",
        "strikethrough": "TextStrikethrough",
        "textformat.size.larger": "Heading01",
        "textformat.size": "Heading02",
        "textformat.size.smaller": "Heading03",
        "curlybraces": "CodeSquare",
        "chevron.left.forwardslash.chevron.right": "SourceCode",
        "bolt.circle": "Zap",
        "circle": "Circle",
        "circle.lefthalf.filled": "Progress03",
        "flame.fill": "Fire",
        "equal": "EqualSign",
        "sunrise": "Sunrise",
        "sun.horizon": "Sun03",
        "sun.max": "Sun01",
        "sun.min": "Sun02",
        "sunset": "Sunset",
        "moon.stars": "MoonStar",
        "exclamationmark.triangle": "Alert02",
        "exclamationmark.triangle.fill": "Alert02",
        "bell.fill": "Bell",
        "ruler": "Ruler",
        "lock.doc": "Lock",
        "lock.open.doc": "LockOpen",
        "function": "Function",
        "keyboard": "Keyboard",
        "sparkles": "Sparkles",
    ]

    private static var cache: [String: NSImage] = [:]

    /// The stroke on Hugeicons' 24-point grid for a font weight.
    static func stroke(for weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight, .thin: 1.0
        case .light: 1.25
        case .medium: 1.75
        case .semibold: 2.0
        case .bold: 2.25
        case .heavy, .black: 2.5
        default: 1.5
        }
    }

    /// The icon for a symbol name (or a Hugeicons name), `size` points square, as a
    /// template image; nil when there is none.
    static func image(_ name: String, size: CGFloat, weight: Font.Weight = .regular) -> NSImage? {
        guard let icon = names[name] ?? (HugeIconGlyphs.all[name] == nil ? nil : name),
              let glyphs = HugeIconGlyphs.all[icon] else { return nil }
        let stroke = stroke(for: weight)
        let key = "\(icon)/\(size)/\(stroke)"
        if let cached = cache[key] { return cached }
        let paths = glyphs.map { (kind: $0.first ?? "S", path: SVGPath.path(String($0.dropFirst()))) }
        // Thin strokes vanish at small sizes; never under a point.
        let lineWidth = max(stroke * size / 24, 1) * 24 / size
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / 24, y: rect.height / 24)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(lineWidth)
            context.setStrokeColor(.black)
            context.setFillColor(.black)
            for glyph in paths {
                context.addPath(glyph.path)
                switch glyph.kind {
                case "F": context.fillPath()
                case "B": context.drawPath(using: .fillStroke)
                default: context.strokePath()
                }
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }
}

/// SVG path data ("M12 2C…Z") as a CGPath.
nonisolated enum SVGPath {
    static func path(_ data: String) -> CGPath {
        var parser = Parser(data)
        return parser.run()
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        /// The last cubic/quadratic control point, for S/T smooth curves.
        var control: CGPoint?
        var quadControl: CGPoint?
        var command: Character = "M"

        init(_ data: String) { chars = Array(data) }

        mutating func run() -> CGPath {
            while let next = peek() {
                if next.isLetter {
                    command = next
                    index += 1
                } else if next == "," || next.isWhitespace {
                    index += 1
                    continue
                }
                // After M/m, further pairs are implicit L/l.
                apply(command)
                if command == "M" { command = "L" } else if command == "m" { command = "l" }
            }
            return path
        }

        private func peek() -> Character? { index < chars.count ? chars[index] : nil }

        private mutating func skipSeparators() {
            while let next = peek(), next == "," || next.isWhitespace { index += 1 }
        }

        /// The next number, or nil at a command letter or the end.
        private mutating func number() -> CGFloat? {
            skipSeparators()
            var text = ""
            var sawDot = false
            var sawExponent = false
            while let next = peek() {
                if next == "-" || next == "+" {
                    // A sign starts a new number unless it follows an exponent.
                    if !text.isEmpty, !(text.last == "e" || text.last == "E") { break }
                } else if next == "." {
                    if sawDot || sawExponent { break }
                    sawDot = true
                } else if next == "e" || next == "E" {
                    if sawExponent { break }
                    sawExponent = true
                } else if !next.isNumber {
                    break
                }
                text.append(next)
                index += 1
            }
            return text.isEmpty ? nil : CGFloat(Double(text) ?? 0)
        }

        /// An arc flag is a single 0 or 1, which may run into the next number.
        private mutating func flag() -> Bool? {
            skipSeparators()
            guard let next = peek(), next == "0" || next == "1" else { return nil }
            index += 1
            return next == "1"
        }

        private func point(_ x: CGFloat, _ y: CGFloat, relative: Bool) -> CGPoint {
            relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        private mutating func apply(_ command: Character) {
            let relative = command.isLowercase
            switch command.uppercased() {
            case "M":
                guard let x = number(), let y = number() else { index = chars.count; return }
                current = point(x, y, relative: relative)
                start = current
                path.move(to: current)
                control = nil; quadControl = nil
            case "L":
                guard let x = number(), let y = number() else { index = chars.count; return }
                current = point(x, y, relative: relative)
                path.addLine(to: current)
                control = nil; quadControl = nil
            case "H":
                guard let x = number() else { index = chars.count; return }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                control = nil; quadControl = nil
            case "V":
                guard let y = number() else { index = chars.count; return }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                control = nil; quadControl = nil
            case "C":
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(), let x = number(), let y = number() else { index = chars.count; return }
                let c1 = point(x1, y1, relative: relative), c2 = point(x2, y2, relative: relative)
                current = point(x, y, relative: relative)
                path.addCurve(to: current, control1: c1, control2: c2)
                control = c2; quadControl = nil
            case "S":
                guard let x2 = number(), let y2 = number(), let x = number(), let y = number() else { index = chars.count; return }
                let c1 = control.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(x2, y2, relative: relative)
                current = point(x, y, relative: relative)
                path.addCurve(to: current, control1: c1, control2: c2)
                control = c2; quadControl = nil
            case "Q":
                guard let x1 = number(), let y1 = number(), let x = number(), let y = number() else { index = chars.count; return }
                let c = point(x1, y1, relative: relative)
                current = point(x, y, relative: relative)
                path.addQuadCurve(to: current, control: c)
                quadControl = c; control = nil
            case "T":
                guard let x = number(), let y = number() else { index = chars.count; return }
                let c = quadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                current = point(x, y, relative: relative)
                path.addQuadCurve(to: current, control: c)
                quadControl = c; control = nil
            case "A":
                guard let rx = number(), let ry = number(), let rotation = number(), let large = flag(), let sweep = flag(),
                      let x = number(), let y = number() else { index = chars.count; return }
                let end = point(x, y, relative: relative)
                arc(to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
                control = nil; quadControl = nil
            case "Z":
                path.closeSubpath()
                current = start
                control = nil; quadControl = nil
            default:
                index = chars.count
            }
        }

        /// An elliptical arc as cubic curves (SVG implementation notes, F.6.5).
        private mutating func arc(to end: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
            if current == end { return }
            var rx = abs(rx), ry = abs(ry)
            if rx == 0 || ry == 0 { path.addLine(to: end); return }
            let phi = rotation * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx = (current.x - end.x) / 2, dy = (current.y - end.y) / 2
            let x1 = cosPhi * dx + sinPhi * dy
            let y1 = -sinPhi * dx + cosPhi * dy
            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
            let sign: CGFloat = large == sweep ? -1 : 1
            let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
            let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
            let coefficient = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
            let cx1 = coefficient * rx * y1 / ry
            let cy1 = coefficient * -ry * x1 / rx
            let cx = cosPhi * cx1 - sinPhi * cy1 + (current.x + end.x) / 2
            let cy = sinPhi * cx1 + cosPhi * cy1 + (current.y + end.y) / 2
            func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                let dot = ux * vx + uy * vy
                let length = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
                var value = acos(max(-1, min(1, dot / length)))
                if ux * vy - uy * vx < 0 { value = -value }
                return value
            }
            let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
            var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
            if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }
            let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
            let step = delta / CGFloat(segments)
            let t = 4 / 3 * tan(step / 4)
            var a = theta
            for _ in 0..<segments {
                let b = a + step
                let cosA = cos(a), sinA = sin(a), cosB = cos(b), sinB = sin(b)
                func map(_ ex: CGFloat, _ ey: CGFloat) -> CGPoint {
                    CGPoint(x: cosPhi * rx * ex - sinPhi * ry * ey + cx, y: sinPhi * rx * ex + cosPhi * ry * ey + cy)
                }
                let c1 = map(cosA - t * sinA, sinA + t * cosA)
                let c2 = map(cosB + t * sinB, sinB - t * cosB)
                let p = map(cosB, sinB)
                path.addCurve(to: p, control1: c1, control2: c2)
                a = b
            }
        }
    }
}
