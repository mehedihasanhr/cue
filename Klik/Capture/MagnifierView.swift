import AppKit

/// The pixel loupe that follows the cursor during area selection. Reads from the
/// frozen screenshot, so what it shows is exactly what will be captured.
final class MagnifierView: NSView {
    private static let cells = 15            // odd, so there is a centre pixel
    private static let cellSize: CGFloat = 8
    private static let imageSide = CGFloat(cells) * cellSize
    private static let labelHeight: CGFloat = 36
    private static let cornerRadius: CGFloat = 10

    static let size = CGSize(width: imageSide + 2, height: imageSide + labelHeight + 2)

    private let image: CGImage
    private let scale: CGFloat
    private let pointHeight: CGFloat

    private var cursor: CGPoint = .zero
    private var colorHex = "—"

    init(frozen: CapturedImage) {
        image = frozen.cgImage
        scale = frozen.scale
        pointHeight = frozen.pointSize.height
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Never intercept mouse events; the selection view underneath handles them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `cursor` is in the parent view's coordinate space (points, y up).
    func update(cursor: CGPoint) {
        self.cursor = cursor
        colorHex = pixelColor(at: pixelCoordinates(for: cursor)).map { String(format: "#%02X%02X%02X", $0.r, $0.g, $0.b) } ?? "—"
        needsDisplay = true
    }

    // MARK: - Pixel access

    private func pixelCoordinates(for point: CGPoint) -> (x: Int, y: Int) {
        (Int((point.x * scale).rounded(.down)), Int(((pointHeight - point.y) * scale).rounded(.down)))
    }

    private func pixelColor(at pixel: (x: Int, y: Int)) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < image.width, pixel.y < image.height,
              let one = image.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1))
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? (bytes[0], bytes[1], bytes[2]) : nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let outer = bounds
        let clip = NSBezierPath(roundedRect: outer, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)

        context.saveGState()
        clip.addClip()
        context.setFillColor(NSColor(white: 0.1, alpha: 0.95).cgColor)
        context.fill(outer)

        // Zoomed pixels.
        let imageArea = CGRect(x: 1, y: Self.labelHeight + 1, width: Self.imageSide, height: Self.imageSide)
        let half = Self.cells / 2
        let centre = pixelCoordinates(for: cursor)
        let source = CGRect(x: centre.x - half, y: centre.y - half, width: Self.cells, height: Self.cells)
        let visible = source.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !visible.isEmpty, let cropped = image.cropping(to: visible) {
            let dx = (visible.minX - source.minX) * Self.cellSize
            let dyFromTop = (visible.minY - source.minY) * Self.cellSize
            let dest = CGRect(
                x: imageArea.minX + dx,
                y: imageArea.maxY - dyFromTop - visible.height * Self.cellSize,
                width: visible.width * Self.cellSize,
                height: visible.height * Self.cellSize
            )
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(cropped, in: dest)
            context.restoreGState()
        }

        // Grid.
        context.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor)
        context.setLineWidth(1)
        for i in 1..<Self.cells {
            let offset = CGFloat(i) * Self.cellSize + 0.5
            context.move(to: CGPoint(x: imageArea.minX + offset, y: imageArea.minY))
            context.addLine(to: CGPoint(x: imageArea.minX + offset, y: imageArea.maxY))
            context.move(to: CGPoint(x: imageArea.minX, y: imageArea.minY + offset))
            context.addLine(to: CGPoint(x: imageArea.maxX, y: imageArea.minY + offset))
        }
        context.strokePath()

        // Centre pixel.
        let centreCell = CGRect(
            x: imageArea.minX + CGFloat(half) * Self.cellSize,
            y: imageArea.minY + CGFloat(half) * Self.cellSize,
            width: Self.cellSize,
            height: Self.cellSize
        )
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.stroke(centreCell.insetBy(dx: 0.75, dy: 0.75))

        // Labels.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let coordinates = "\(Int(cursor.x.rounded(.down))), \(Int((pointHeight - cursor.y).rounded(.down)))"
        coordinates.draw(in: CGRect(x: 0, y: 19, width: outer.width, height: 14), withAttributes: attributes)
        colorHex.draw(in: CGRect(x: 0, y: 4, width: outer.width, height: 14), withAttributes: attributes)

        context.restoreGState()

        // Border.
        NSColor(white: 1, alpha: 0.6).setStroke()
        clip.lineWidth = 1
        clip.stroke()
    }
}
