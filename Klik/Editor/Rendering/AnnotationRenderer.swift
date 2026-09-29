import AppKit
import BackgroundKit

/// Draws a document into the *current* `NSGraphicsContext`, which must be flipped
/// (origin top-left, y down) with (0, 0) at the output's top-left corner. The canvas
/// (a flipped view) and the exporter (a flipped bitmap context) both call this, so
/// what is shown is exactly what is exported.
struct AnnotationRenderer {
    let effects: EffectsCache

    func draw(_ document: EditorDocument, draft: Annotation? = nil) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawBackdrop(document, context: context)
        drawContent(document, context: context)
        drawAnnotations(document, draft: draft, context: context)
    }

    /// The background fill and the card's shadow: the expensive, low-frequency part of a
    /// frame. The canvas caches it as a bitmap and redraws only the rest while dragging.
    func drawBackdrop(_ document: EditorDocument, context: CGContext) {
        guard let background = document.background else { return }
        let layout = document.layout
        drawBackground(background, in: CGRect(origin: .zero, size: layout.size), card: layout.card, context: context)
    }

    /// The inset border and the captured image, clipped to the rounded content frame.
    func drawContent(_ document: EditorDocument, context: CGContext) {
        let layout = document.layout
        let contentFrame = layout.image

        if let background = document.background, background.inset > 0 {
            // The inset border takes the image's own edge color so it reads as part of it.
            context.saveGState()
            context.addPath(CGPath(roundedRect: layout.card, cornerWidth: background.cornerRadius,
                                   cornerHeight: background.cornerRadius, transform: nil))
            context.setFillColor(effects.edgeColor(of: document.base))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        if let background = document.background, background.cornerRadius > 0 {
            let radius = max(0, background.cornerRadius - background.inset)
            context.addPath(CGPath(roundedRect: contentFrame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
        } else {
            context.clip(to: contentFrame)
        }
        context.translateBy(x: document.contentOffset.x, y: document.contentOffset.y)
        drawImage(document.base, in: document.imageRect, context: context)
        context.restoreGState()
    }

    /// Annotations may spill over the padding, so they are clipped to the whole output.
    func drawAnnotations(_ document: EditorDocument, draft: Annotation?, context: CGContext) {
        let output = CGRect(origin: .zero, size: document.layout.size)
        context.saveGState()
        context.clip(to: output)
        context.translateBy(x: document.contentOffset.x, y: document.contentOffset.y)
        for annotation in document.annotations {
            draw(annotation, document: document, context: context)
        }
        if let draft {
            draw(draft, document: document, context: context)
        }
        context.restoreGState()
    }

    // MARK: - Background

    private func drawBackground(_ style: BackgroundStyle, in rect: CGRect, card: CGRect, context: CGContext) {
        switch style.fill {
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(rect)
        case .gradient(let preset):
            let stops = preset.colors
            let colors = stops.map(\.cgColor) as CFArray
            let locations = stops.indices.map { CGFloat($0) / CGFloat(max(1, stops.count - 1)) }
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                // Direction from the angle: 0° is top→bottom in this flipped (y-down) space.
                let radians = style.gradientAngle * .pi / 180
                let direction = CGPoint(x: sin(radians), y: cos(radians))
                let half = CGPoint(x: direction.x * rect.width / 2, y: direction.y * rect.height / 2)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                context.saveGState()
                context.clip(to: rect)
                context.drawLinearGradient(gradient,
                                           start: CGPoint(x: center.x - half.x, y: center.y - half.y),
                                           end: CGPoint(x: center.x + half.x, y: center.y + half.y),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            }
        case .image(let wallpaper):
            context.setFillColor(NSColor.black.cgColor)
            context.fill(rect)
            if let image = effects.wallpaper(wallpaper, blur: style.imageBlur) {
                // Aspect-fill, centred.
                let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                let frame = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
                context.saveGState()
                context.clip(to: rect)
                // The context is flipped (y down); CGImage draws y-up, so flip around the frame.
                context.translateBy(x: 0, y: frame.maxY + frame.minY)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: frame)
                context.restoreGState()
            }
        }
        if style.shadowStrength > 0.01 {
            // Soft and wide rather than dark: a diffuse ambient shadow that scales with the slider.
            // Core Graphics takes shadow geometry in device space, so it is scaled by the
            // current transform to keep it in points: the same look at any zoom, in the
            // canvas's backdrop bitmap and in the export.
            let strength = min(1, max(0, style.shadowStrength))
            let ctm = context.ctm
            let device = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: (2 + 7 * strength) * device), blur: (10 + 30 * strength) * device,
                              color: NSColor.black.withAlphaComponent(0.08 + 0.32 * strength).cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(CGPath(roundedRect: card, cornerWidth: style.cornerRadius,
                                   cornerHeight: style.cornerRadius, transform: nil))
            context.fillPath()
            context.restoreGState()
        }
    }

    // MARK: - Annotations

    private func draw(_ annotation: Annotation, document: EditorDocument, context: CGContext) {
        if annotation.rotation != 0, annotation.canRotate {
            let center = annotation.center
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: annotation.rotation)
            context.translateBy(x: -center.x, y: -center.y)
            drawUnrotated(annotation, document: document, context: context)
            return
        }
        drawUnrotated(annotation, document: document, context: context)
    }

    private func drawUnrotated(_ annotation: Annotation, document: EditorDocument, context: CGContext) {
        switch annotation.kind {
        case .rectangle(let rect, let style):
            let path = CGPath(rect: rect, transform: nil)
            fillAndStroke(path, style: style, context: context)

        case .ellipse(let rect, let style):
            let path = CGPath(ellipseIn: rect, transform: nil)
            fillAndStroke(path, style: style, context: context)

        case .line(let start, let end, let style):
            context.saveGState()
            applyStroke(style, context: context)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            context.restoreGState()

        case .arrow(let start, let end, let bend, let style, let arrowStyle):
            drawArrow(from: start, to: end, bend: bend, style: style, arrowStyle: arrowStyle, context: context)

        case .pencil(let points, let style):
            context.saveGState()
            applyStroke(style, context: context)
            context.addPath(Self.smoothPath(points))
            context.strokePath()
            context.restoreGState()

        case .highlighter(let points, let style):
            context.saveGState()
            context.setBlendMode(.multiply)
            applyStroke(StrokeStyle(color: style.color.withAlpha(0.45), width: style.width), context: context)
            context.setLineCap(.square)
            context.addPath(Self.polyline(points))
            context.strokePath()
            context.restoreGState()

        case .highlight(let rect, let color):
            context.saveGState()
            context.setBlendMode(.multiply)
            context.setFillColor(color.withAlpha(0.45).cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
            context.restoreGState()

        case .text(let origin, let text, let style):
            drawText(text, at: origin, style: style, context: context)

        case .counter(let center, let number, let color, let size):
            drawCounter(number, at: center, color: color, size: size, context: context)

        case .blur(let rect, let kind, let intensity):
            // Effects re-sample the image, so they never extend past it.
            context.saveGState()
            defer { context.restoreGState() }
            context.clip(to: document.contentRect)
            if let image = effects.image(for: rect, kind: kind, intensity: intensity, base: document.base, scale: document.scale) {
                let pixelRect = CGRect(x: rect.minX * document.scale, y: rect.minY * document.scale,
                                       width: rect.width * document.scale, height: rect.height * document.scale).integral
                let drawRect = CGRect(x: pixelRect.minX / document.scale, y: pixelRect.minY / document.scale,
                                      width: pixelRect.width / document.scale, height: pixelRect.height / document.scale)
                drawImage(image, in: drawRect, context: context)
            }
        }
    }

    private func applyStroke(_ style: StrokeStyle, context: CGContext) {
        context.setStrokeColor(style.color.cgColor)
        context.setLineWidth(style.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
    }

    private func fillAndStroke(_ path: CGPath, style: ShapeStyle, context: CGContext) {
        context.saveGState()
        switch style.fill {
        case .none:
            break
        case .solid:
            context.setFillColor(style.stroke.color.cgColor)
            context.addPath(path)
            context.fillPath()
        case .translucent:
            context.setFillColor(style.stroke.color.withAlpha(0.3).cgColor)
            context.addPath(path)
            context.fillPath()
        }
        if style.stroke.width > 0 {
            applyStroke(style.stroke, context: context)
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, bend: CGPoint, style: StrokeStyle, arrowStyle: ArrowStyle, context: CGContext) {
        guard start.distance(to: end) > 0.5 else { return }
        let headLength = max(12, style.width * 4)
        let headWidth = headLength * 0.9
        // Heads follow the curve's tangent at each end so a bent arrow still points the way it travels.
        let endDirection = ArrowGeometry.tangent(at: 1, start: start, end: end, bend: bend)
        let startDirection = ArrowGeometry.tangent(at: 0, start: start, end: end, bend: bend)

        func head(at tip: CGPoint, pointing dir: CGPoint) -> CGPath {
            let normal = CGPoint(x: -dir.y, y: dir.x)
            let base = CGPoint(x: tip.x - dir.x * headLength, y: tip.y - dir.y * headLength)
            let path = CGMutablePath()
            path.move(to: tip)
            path.addLine(to: CGPoint(x: base.x + normal.x * headWidth / 2, y: base.y + normal.y * headWidth / 2))
            path.addLine(to: CGPoint(x: base.x - normal.x * headWidth / 2, y: base.y - normal.y * headWidth / 2))
            path.closeSubpath()
            return path
        }

        context.saveGState()
        applyStroke(style, context: context)
        context.setFillColor(style.color.cgColor)

        // Stop the shaft short of each tip so the stroke's round cap doesn't poke out of the head.
        let shaftEnd = CGPoint(x: end.x - endDirection.x * headLength * 0.8, y: end.y - endDirection.y * headLength * 0.8)
        let shaftStart = arrowStyle == .double
            ? CGPoint(x: start.x + startDirection.x * headLength * 0.8, y: start.y + startDirection.y * headLength * 0.8)
            : start
        context.move(to: shaftStart)
        if bend == .zero {
            context.addLine(to: shaftEnd)
        } else {
            context.addQuadCurve(to: shaftEnd, control: ArrowGeometry.control(start: start, end: end, bend: bend))
        }
        context.strokePath()

        context.addPath(head(at: end, pointing: endDirection))
        context.fillPath()
        if arrowStyle == .double {
            context.addPath(head(at: start, pointing: CGPoint(x: -startDirection.x, y: -startDirection.y)))
            context.fillPath()
        }
        context.restoreGState()
    }

    private func drawText(_ text: String, at origin: CGPoint, style: TextStyle, context: CGContext) {
        let display = text.isEmpty ? " " : text
        let size = TextMetrics.size(of: display, style: style)
        let box = CGRect(origin: origin, size: size)
        var attributes = TextMetrics.attributes(for: style)

        context.saveGState()
        switch style.background {
        case .none:
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = CGSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            attributes[.shadow] = shadow
        case .solid:
            context.setFillColor(style.color.cgColor)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
            attributes[.foregroundColor] = style.color.isLight ? NSColor.black : NSColor.white
        case .translucent:
            context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
        }
        display.draw(at: CGPoint(x: box.minX + TextMetrics.padding.width, y: box.minY + TextMetrics.padding.height),
                     withAttributes: attributes)
        context.restoreGState()
    }

    private func drawCounter(_ number: Int, at center: CGPoint, color: RGBA, size: CGFloat, context: CGContext) {
        let circle = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circle)
        context.restoreGState()
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(max(1.5, size * 0.06))
        context.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
        context.restoreGState()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.52, weight: .bold),
            .foregroundColor: color.isLight ? NSColor.black : NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let label = "\(number)"
        let textSize = label.size(withAttributes: attributes)
        label.draw(in: CGRect(x: circle.minX, y: circle.midY - textSize.height / 2, width: circle.width, height: textSize.height),
                   withAttributes: attributes)
    }

    // MARK: - Helpers

    /// Draws an image upright inside a flipped context.
    func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    static func polyline(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
        }
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    /// Catmull-Rom spline through the points, as cubic Béziers — the "auto-smoothing" pencil.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        guard points.count > 2 else { return polyline(points) }
        let path = CGMutablePath()
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}

extension RGBA {
    var isLight: Bool { (0.299 * r + 0.587 * g + 0.114 * b) > 0.6 }
}

/// Flattens a document into pixels at its native scale.
enum DocumentExporter {
    static func render(_ document: EditorDocument, effects: EffectsCache) -> CGImage? {
        let size = document.outputSize
        let scale = document.scale
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        // Flip so the renderer's top-left origin maps to the bitmap correctly.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        AnnotationRenderer(effects: effects).draw(document)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        ImageEncoding.png(image)
    }
}
