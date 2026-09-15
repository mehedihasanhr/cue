import os
import AppKit

/// A pixel-exact color picker: every display is frozen, covered by an overlay, and a
/// square loupe *is* the pointer — centred on it, the cursor hidden — showing the
/// surrounding pixels magnified as a grid. Click picks the centre pixel, arrow keys
/// nudge it by one device pixel, scrolling zooms, ⎋ cancels. Colors are read from the capture in the display's
/// own color space and converted to extended sRGB, so a P3 color keeps its value.
final class ColorPickerSession {
    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<PickedColor?, Never>?
    private var previousApp: NSRunningApplication?

    func run(using service: ScreenCaptureService) async throws(CaptureError) -> PickedColor? {
        let frozen = try await service.captureAllDisplays()
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID, let image = frozen[displayID],
                  let pixels = PixelSource(image: image) else { continue }
            let window = OverlayWindow(screen: screen)
            let view = PixelPickerView(frame: CGRect(origin: .zero, size: screen.frame.size), pixels: pixels, screen: screen)
            view.onPick = { [weak self] color in self?.finish(with: color) }
            view.onCancel = { [weak self] in self?.finish(with: nil) }
            window.contentView = view
            windows.append(window)
        }
        guard !windows.isEmpty else { throw .noDisplay }
        let mouse = NSEvent.mouseLocation
        let initial = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows[0]
        NSApp.activate()
        for window in windows {
            window.orderFrontRegardless()
        }
        initial.makeKeyAndOrderFront(nil)
        initial.makeFirstResponder(initial.contentView)
        NSCursor.hide()
        Log.app.info("Color picker shown on \(self.windows.count) screen(s)")
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func finish(with color: PickedColor?) {
        guard let continuation else { return }
        self.continuation = nil
        for window in windows { window.close() }
        windows.removeAll()
        NSCursor.unhide()
        previousApp?.activate(from: .current, options: [])
        continuation.resume(returning: color)
    }
}

/// The frozen display as 8-bit RGBA in its own color space, for exact pixel reads.
final class PixelSource {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let data: Data
    private let colorSpace: CGColorSpace

    init?(image: CapturedImage) {
        width = image.cgImage.width
        height = image.cgImage.height
        scale = image.scale
        let space = image.cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        colorSpace = space
        let w = image.cgImage.width, h = image.cgImage.height
        var bytes = Data(count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        data = bytes
    }

    /// The color at a device pixel (origin top-left), nil outside the image.
    func color(x: Int, y: Int) -> PickedColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let offset = (y * width + x) * 4
        let r = CGFloat(data[offset]) / 255, g = CGFloat(data[offset + 1]) / 255, b = CGFloat(data[offset + 2]) / 255
        guard let cgColor = CGColor(colorSpace: colorSpace, components: [r, g, b, 1]),
              let converted = NSColor(cgColor: cgColor)?.usingColorSpace(.extendedSRGB)
        else { return PickedColor(red: r, green: g, blue: b) }
        return PickedColor(red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent)
    }

    /// For drawing the loupe cells quickly (no color management needed on screen).
    func displayColor(x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let offset = (y * width + x) * 4
        return NSColor(cgColor: CGColor(colorSpace: colorSpace, components: [CGFloat(data[offset]) / 255, CGFloat(data[offset + 1]) / 255, CGFloat(data[offset + 2]) / 255, 1])!)
    }
}

/// The overlay's content: transparent (the live screen stays visible) with the
/// square loupe centred on the pointer, reading from the frozen capture.
final class PixelPickerView: NSView {
    var onPick: ((PickedColor) -> Void)?
    var onCancel: (() -> Void)?

    private let pixels: PixelSource
    private let screen: NSScreen
    /// The device pixel under the pointer (top-left origin), nudged by the arrow keys.
    private var target = CGPoint.zero
    private var nudge = CGPoint.zero
    /// Pixels per side of the loupe grid (odd, so there is a centre).
    private var gridSize = 11
    private static let cellPoints: CGFloat = 12
    private var trackingArea: NSTrackingArea?

    init(frame: CGRect, pixels: PixelSource, screen: NSScreen) {
        self.pixels = pixels
        self.screen = screen
        super.init(frame: frame)
        updateTarget(from: NSEvent.mouseLocation)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    // MARK: - Input

    override func mouseMoved(with event: NSEvent) {
        nudge = .zero
        updateTarget(from: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if let color = pixels.color(x: Int(target.x), y: Int(target.y)) { onPick?(color) }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()                                   // ⎋
        case 36, 76, 49: mouseDown(with: event)                // ↩, keypad ↩, space
        case 123: nudge.x -= 1; refresh()                      // ←
        case 124: nudge.x += 1; refresh()                      // →
        case 126: nudge.y -= 1; refresh()                      // ↑
        case 125: nudge.y += 1; refresh()                      // ↓
        default: super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.scrollingDeltaY > 0 ? 2 : (event.scrollingDeltaY < 0 ? -2 : 0)
        gridSize = min(31, max(5, gridSize + step))
        needsDisplay = true
    }

    private func updateTarget(from mouse: CGPoint) {
        // Global AppKit points → this screen's device pixels, top-left origin.
        let local = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
        target = CGPoint(x: (local.x * pixels.scale).rounded(.down), y: (local.y * pixels.scale).rounded(.down))
        refresh()
    }

    private func refresh() {
        needsDisplay = true
    }

    private var pixelUnderPointer: CGPoint {
        CGPoint(x: target.x + nudge.x, y: target.y + nudge.y)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let center = pixelUnderPointer
        let half = gridSize / 2
        let cell = Self.cellPoints
        let side = cell * CGFloat(gridSize)

        // The grid sits centred on the pointer (the pointer itself is hidden), so the
        // outlined middle cell is exactly the pixel that will be picked.
        let pointer = CGPoint(x: center.x / pixels.scale, y: bounds.height - center.y / pixels.scale)
        let loupe = CGRect(x: (pointer.x - side / 2).rounded(), y: (pointer.y - side / 2).rounded(), width: side, height: side)
        let shape = NSBezierPath(roundedRect: loupe, xRadius: 10, yRadius: 10)

        // Shadow under the square.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        // The magnified pixels, clipped to the rounded square. Rows are drawn top-down.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        for row in 0..<gridSize {
            for column in 0..<gridSize {
                let x = Int(center.x) + column - half
                let y = Int(center.y) + row - half
                let rect = CGRect(x: loupe.minX + CGFloat(column) * cell, y: loupe.maxY - CGFloat(row + 1) * cell, width: cell, height: cell)
                (pixels.displayColor(x: x, y: y) ?? .black).setFill()
                rect.fill()
            }
        }
        NSColor.black.withAlphaComponent(0.22).setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = 0.5
        for i in 1..<gridSize {
            let x = loupe.minX + CGFloat(i) * cell
            lines.move(to: CGPoint(x: x, y: loupe.minY)); lines.line(to: CGPoint(x: x, y: loupe.maxY))
            let y = loupe.minY + CGFloat(i) * cell
            lines.move(to: CGPoint(x: loupe.minX, y: y)); lines.line(to: CGPoint(x: loupe.maxX, y: y))
        }
        lines.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Centre pixel: a white ring with a dark outline so it reads on any color.
        let centerRect = CGRect(x: loupe.minX + CGFloat(half) * cell, y: loupe.maxY - CGFloat(half + 1) * cell, width: cell, height: cell)
        NSColor.black.withAlphaComponent(0.8).setStroke()
        let outer = NSBezierPath(rect: centerRect.insetBy(dx: -1.5, dy: -1.5)); outer.lineWidth = 3; outer.stroke()
        NSColor.white.setStroke()
        let inner = NSBezierPath(rect: centerRect.insetBy(dx: -0.5, dy: -0.5)); inner.lineWidth = 1.5; inner.stroke()

        // Rim: a white hairline inside a dark one, like the system loupe.
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let rimOuter = NSBezierPath(roundedRect: loupe.insetBy(dx: -1.5, dy: -1.5), xRadius: 11.5, yRadius: 11.5)
        rimOuter.lineWidth = 1
        rimOuter.stroke()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let rimInner = NSBezierPath(roundedRect: loupe.insetBy(dx: -0.5, dy: -0.5), xRadius: 10.5, yRadius: 10.5)
        rimInner.lineWidth = 1
        rimInner.stroke()

        // Label pill under the square (above it near the bottom edge): swatch + hex.
        let picked = pixels.color(x: Int(center.x), y: Int(center.y))
        let hex = picked.map { ColorFormat.hex.string(for: $0) } ?? "—"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (hex as NSString).size(withAttributes: attributes)
        let pillHeight: CGFloat = 24
        let swatchSide = pillHeight - 10
        let pillWidth = textSize.width + swatchSide + 22
        var pillY = loupe.minY - 10 - pillHeight
        if pillY < bounds.minY + 6 { pillY = loupe.maxY + 10 }
        let pill = CGRect(x: (loupe.midX - pillWidth / 2).rounded(), y: pillY.rounded(), width: pillWidth, height: pillHeight)
        NSGraphicsContext.saveGraphicsState()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor(white: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        if let picked {
            picked.nsColor.setFill()
            NSBezierPath(roundedRect: CGRect(x: pill.minX + 6, y: pill.minY + 5, width: swatchSide, height: swatchSide), xRadius: 4, yRadius: 4).fill()
        }
        (hex as NSString).draw(at: CGPoint(x: pill.minX + 6 + swatchSide + 6, y: pill.minY + (pillHeight - textSize.height) / 2), withAttributes: attributes)
    }
}

extension PickedColor {
    var nsColor: NSColor {
        let (r, g, b) = clamped
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
