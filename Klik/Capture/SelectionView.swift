import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
protocol SelectionViewDelegate: AnyObject {
    /// The user clicked in this view; other screens should drop their state.
    func selectionViewDidBeginInteraction(_ view: SelectionView)
    /// The cursor moved into this view. Returns whether it may become the active one.
    func selectionViewWantsFocus(_ view: SelectionView) -> Bool
    func selectionViewDidCancel(_ view: SelectionView)
    /// `rect` is in the view's coordinate space (screen-local points, y up).
    func selectionView(_ view: SelectionView, didConfirm rect: CGRect)
}

/// Drag-to-select surface drawn over a frozen screenshot: dimming, live dimensions,
/// resize handles, window hover/snapping, keyboard control.
final class SelectionView: NSView {
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Phase {
        case idle
        case dragging(anchor: CGPoint)
        case selected
        case moving(grab: CGPoint, origin: CGRect)
        case resizing(Handle, origin: CGRect)
    }

    let frozen: CapturedImage
    let mode: CaptureMode
    weak var delegate: SelectionViewDelegate?
    /// Other apps' windows, in this view's coordinate space.
    var windows: [WindowInfo] = []

    private(set) var selection: CGRect? {
        didSet { needsDisplay = true }
    }
    var hasSelection: Bool { selection != nil }

    private var phase: Phase = .idle
    private var cursor: CGPoint?
    /// The cursor AppKit should show over this view. Going through cursor rects (rather
    /// than `NSCursor.set()` on every mouse move) stops the arrow flickering back in
    /// between our updates.
    private var desiredCursor: NSCursor = .crosshair {
        didSet {
            guard desiredCursor !== oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if isDragging { desiredCursor.set() } // cursor rects don't update mid-drag
        }
    }
    private var isDragging: Bool {
        switch phase {
        case .dragging, .moving, .resizing: true
        default: false
        }
    }
    private var hoveredWindow: WindowInfo? {
        didSet { if hoveredWindow != oldValue { needsDisplay = true } }
    }
    /// Another screen owns the interaction; this view only dims.
    private var isPassive = false {
        didSet { if isPassive != oldValue { needsDisplay = true } }
    }

    private var toolbar: NSHostingView<SelectionToolbar>?
    private var trackingArea: NSTrackingArea?

    private static let handleRadius: CGFloat = 4.5
    private static let handleHitRadius: CGFloat = 8
    private static let snapTolerance: CGFloat = 8
    private static let clickSlop: CGFloat = 3
    private static let minimumSize: CGFloat = 2

    init(frame: CGRect, frozen: CapturedImage, mode: CaptureMode) {
        self.frozen = frozen
        self.mode = mode
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    /// The first click starts a selection even if the window was not key yet.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: desiredCursor)
    }

    // MARK: - External control

    func becomePassive() {
        isPassive = true
        phase = .idle
        selection = nil
        hoveredWindow = nil
        hideToolbar()
    }

    func becomeActive() {
        isPassive = false
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        cursor = nil
        if case .idle = phase {
            hoveredWindow = nil
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        if isPassive {
            guard delegate?.selectionViewWantsFocus(self) == true else { return }
            becomeActive()
        }
        if window?.isKeyWindow == false {
            window?.makeKey()
            window?.makeFirstResponder(self)
        }

        if case .idle = phase {
            hoveredWindow = WindowDetector.window(at: point, in: windows)
        }
        updateCursor(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        delegate?.selectionViewDidBeginInteraction(self)
        isPassive = false
        hideToolbar()

        if case .selected = phase, let current = selection {
            if let handle = handle(at: point, in: current) {
                phase = .resizing(handle, origin: current)
                updateCursor(at: point)
                return
            }
            if current.contains(point) {
                if event.clickCount == 2 {
                    confirm()
                } else {
                    phase = .moving(grab: point, origin: current)
                    updateCursor(at: point)
                }
                return
            }
        }

        selection = nil
        hoveredWindow = WindowDetector.window(at: point, in: windows)
        phase = .dragging(anchor: point)
    }

    override func mouseDragged(with event: NSEvent) {
        var point = convert(event.locationInWindow, from: nil)
        cursor = point
        let flags = event.modifierFlags

        switch phase {
        case .dragging(let anchor):
            // ⌘ disables edge snapping; ⇧ constrains to a square.
            if !flags.contains(.command) {
                point = WindowDetector.snap(point, to: windows, tolerance: Self.snapTolerance)
            }
            if flags.contains(.shift) {
                let side = max(abs(point.x - anchor.x), abs(point.y - anchor.y))
                point = CGPoint(
                    x: anchor.x + side * (point.x >= anchor.x ? 1 : -1),
                    y: anchor.y + side * (point.y >= anchor.y ? 1 : -1)
                )
            }
            selection = Self.rect(from: anchor, to: point).intersection(bounds).rounded()
            hoveredWindow = nil

        case .moving(let grab, let origin):
            var moved = origin.offsetBy(dx: point.x - grab.x, dy: point.y - grab.y)
            moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
            selection = moved.rounded()

        case .resizing(let handle, let origin):
            if !flags.contains(.command) {
                point = WindowDetector.snap(point, to: windows, tolerance: Self.snapTolerance)
            }
            selection = Self.resize(origin, handle: handle, to: point).intersection(bounds).rounded()

        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch phase {
        case .dragging(let anchor):
            let isClick = hypot(point.x - anchor.x, point.y - anchor.y) < Self.clickSlop
            if isClick {
                if let window = hoveredWindow {
                    selection = window.frame.intersection(bounds).rounded()
                    phase = .selected
                } else {
                    selection = nil
                    phase = .idle
                }
            } else if let rect = selection, rect.width >= Self.minimumSize, rect.height >= Self.minimumSize {
                phase = .selected
            } else {
                selection = nil
                phase = .idle
            }

        case .moving, .resizing:
            phase = .selected

        default:
            break
        }

        if case .selected = phase {
            hoveredWindow = nil
            // Area capture fires straight away; scrolling capture waits for "Start Capture"
            // so the frame can still be adjusted.
            if mode.confirmsOnRelease { confirm(); return }
            showToolbar()
        } else {
            hoveredWindow = WindowDetector.window(at: point, in: windows)
        }
        updateCursor(at: point)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case kVK_Escape:
            delegate?.selectionViewDidCancel(self)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            confirm()
        case kVK_ANSI_A where flags == .command:
            selection = bounds
            phase = .selected
            if mode.confirmsOnRelease { confirm() } else { showToolbar() }
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            nudge(keyCode: Int(event.keyCode), amount: flags.contains(.shift) ? 10 : 1, resize: flags.contains(.option))
        default:
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Re-evaluate the cursor when modifiers change while hovering a handle.
        if let cursor { updateCursor(at: cursor) }
    }

    private func nudge(keyCode: Int, amount: CGFloat, resize: Bool) {
        guard case .selected = phase, var rect = selection else { return }
        let dx: CGFloat = keyCode == kVK_LeftArrow ? -amount : (keyCode == kVK_RightArrow ? amount : 0)
        let dy: CGFloat = keyCode == kVK_DownArrow ? -amount : (keyCode == kVK_UpArrow ? amount : 0)
        if resize {
            rect.size.width = max(Self.minimumSize, rect.width + dx)
            rect.size.height = max(Self.minimumSize, rect.height + dy)
        } else {
            rect = rect.offsetBy(dx: dx, dy: dy)
        }
        selection = rect.intersection(bounds).rounded()
        showToolbar()
    }

    private func confirm() {
        guard let rect = selection, rect.width >= Self.minimumSize, rect.height >= Self.minimumSize else { return }
        delegate?.selectionView(self, didConfirm: rect)
    }

    // MARK: - Geometry helpers

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private static func resize(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomLeft: minX = point.x; minY = point.y
        case .left: minX = point.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func handlePoint(_ handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .top: CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { handle in
            let p = handlePoint(handle, in: rect)
            return hypot(p.x - point.x, p.y - point.y) <= Self.handleHitRadius
        }
    }

    // MARK: - Cursor, toolbar

    private func updateCursor(at point: CGPoint) {
        switch phase {
        case .moving:
            desiredCursor = .closedHand
        case .resizing(let handle, _):
            desiredCursor = cursor(for: handle)
        case .selected:
            if let rect = selection {
                if let handle = handle(at: point, in: rect) {
                    desiredCursor = cursor(for: handle)
                } else if rect.contains(point) {
                    desiredCursor = .openHand
                } else {
                    desiredCursor = .crosshair
                }
            }
        default:
            desiredCursor = .crosshair
        }
    }

    private func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        default: .crosshair
        }
    }

    private func showToolbar() {
        guard let rect = selection else { return }
        let host: NSHostingView<SelectionToolbar>
        if let toolbar {
            host = toolbar
        } else {
            host = NSHostingView(rootView: SelectionToolbar(
                mode: mode,
                onConfirm: { [weak self] in self?.confirm() },
                onCancel: { [weak self] in
                    guard let self else { return }
                    delegate?.selectionViewDidCancel(self)
                }
            ))
            addSubview(host)
            toolbar = host
        }
        let size = host.fittingSize
        let gap: CGFloat = -8 // the hosting view carries 20pt of padding for its shadow; net gap 12pt
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - gap - size.height)
        if origin.y < bounds.minY {
            origin.y = rect.maxY + gap
        }
        if origin.y + size.height > bounds.maxY {
            origin.y = rect.minY + 8
        }
        origin.x = min(max(origin.x, 0), bounds.maxX - size.width)
        host.frame = CGRect(origin: origin, size: size)
        host.isHidden = false
    }

    private func hideToolbar() {
        toolbar?.isHidden = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let dimAlpha: CGFloat = selection == nil ? 0.3 : 0.45
        context.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        context.fill(bounds)

        if let rect = selection {
            context.clear(rect)
            drawSelectionFrame(rect, in: context)
            if case .selected = phase {
                drawHandles(rect, in: context)
            } else if case .moving = phase {
                drawHandles(rect, in: context)
            } else if case .resizing = phase {
                drawHandles(rect, in: context)
            }
            drawDimensionLabel(for: rect, in: context)
        } else if !isPassive, case .idle = phase, let window = hoveredWindow {
            let rect = window.frame.intersection(bounds)
            context.clear(rect)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2)
            context.stroke(rect.insetBy(dx: 1, dy: 1))
            drawLabel(window.ownerName + (window.title.isEmpty ? "" : " — \(window.title)"), anchoredTo: rect, in: context)
        }
    }

    private func drawSelectionFrame(_ rect: CGRect, in context: CGContext) {
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1)
        context.stroke(rect.insetBy(dx: -1.5, dy: -1.5))
        context.setStrokeColor(NSColor.white.cgColor)
        context.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
    }

    private func drawHandles(_ rect: CGRect, in context: CGContext) {
        for handle in Handle.allCases {
            let p = handlePoint(handle, in: rect)
            let circle = CGRect(
                x: p.x - Self.handleRadius, y: p.y - Self.handleRadius,
                width: Self.handleRadius * 2, height: Self.handleRadius * 2
            )
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: circle)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func drawDimensionLabel(for rect: CGRect, in context: CGContext) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        drawLabel(text, anchoredTo: rect, in: context)
    }

    /// Draws a pill label centred below `rect` (above it when there is no room).
    private func drawLabel(_ text: String, anchoredTo rect: CGRect, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = CGSize(width: 8, height: 4)
        let size = CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - 8 - size.height)
        if origin.y < bounds.minY { origin.y = rect.maxY + 8 }
        if origin.y + size.height > bounds.maxY { origin.y = rect.minY + 8 }
        origin.x = min(max(origin.x, 4), bounds.maxX - size.width - 4)
        let pill = CGRect(origin: origin, size: size)

        context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        context.addPath(CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.fillPath()
        text.draw(at: CGPoint(x: pill.minX + padding.width, y: pill.minY + padding.height), withAttributes: attributes)
    }
}

private extension CGRect {
    /// Snaps origin and size to whole points so 1px strokes stay crisp.
    func rounded() -> CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}
