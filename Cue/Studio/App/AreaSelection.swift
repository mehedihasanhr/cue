import AppKit
import CoreGraphics
import Foundation
import QuartzCore

/// Dragging out the part of the screen to record, and keeping it there until the take.
///
/// A borderless window per display, lightly dimmed, with the chosen rectangle punched
/// clear. The rectangle stays on screen after the drag — it can be moved, resized or drawn
/// again — so what will be recorded is the thing on the screen, not a card describing it.
/// The bar's record button (or Return) starts the take; Escape clears the area and closes
/// the overlay; choosing another mode closes it too.
///
/// AppKit rather than SwiftUI because the whole interaction is mouse tracking over a
/// transparent overlay that has to sit above everything including full-screen apps —
/// exactly the case where a plain `NSView` is less code than the alternative.
@MainActor
final class AreaSelectionController {
    struct Selection: Equatable {
        /// Which display the rectangle is on.
        let displayID: CGDirectDisplayID
        /// The rectangle in that display's points, origin at its top left, which is what
        /// `SCStreamConfiguration.sourceRect` wants.
        let rect: CGRect
    }

    /// A rectangle was drawn, moved or resized — told once the mouse is let go.
    var onChange: (Selection) -> Void = { _ in }
    /// Escape: the area is cleared and the overlay is gone.
    var onCancel: () -> Void = {}
    /// Return, or a double-click inside the area: record it.
    var onConfirm: () -> Void = {}

    private var views: [AreaSelectionView] = []
    private var windows: [NSWindow] = []
    /// Watches for Escape and Return while the overlay is up.
    ///
    /// A monitor as well as `cancelOperation`: the overlay is a non-activating panel, and
    /// the moment something else takes the key window — a menu on the bar, say — the
    /// responder chain stops hearing the keyboard, and an overlay that covers the screen
    /// without answering Escape is a trap.
    private var keys: Any?

    var isActive: Bool { !windows.isEmpty }

    /// Puts the overlay on every screen, showing `initial` if there is one already.
    func begin(initial: Selection?) {
        end()

        for screen in NSScreen.screens {
            // A non-activating panel that can take the keyboard, like the target overlay.
            // It relies on nothing becoming active: macOS no longer grants that on request,
            // and the press that should start the drag went on activating the window.
            let window = AreaSelectionWindow(contentRect: screen.frame,
                                             styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered,
                                             defer: false,
                                             screen: screen)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.acceptsMouseMovedEvents = true
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = false
            window.isExcludedFromWindowsMenu = true
            window.animationBehavior = .none
            window.onCancel = { [weak self] in self?.cancel() }

            let view = AreaSelectionView(screen: screen)
            view.onBegin = { [weak self, weak view] in
                // One area, on one screen: drawing on this one clears the others.
                for other in self?.views ?? [] where other !== view { other.clear() }
            }
            view.onCommit = { [weak self] rect in self?.commit(rect, on: screen) }
            view.onConfirm = { [weak self] in self?.onConfirm() }
            view.hasSelectionElsewhere = { [weak self, weak view] in
                self?.views.contains { $0 !== view && $0.hasSelection } ?? false
            }
            if let initial, Self.displayID(of: screen) == initial.displayID {
                // Display points, origin top left, back into this view's own.
                view.show(CGRect(x: initial.rect.minX,
                                 y: screen.frame.height - initial.rect.maxY,
                                 width: initial.rect.width,
                                 height: initial.rect.height))
            }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
        for view in views { view.refreshHint() }

        // Key on the screen the pointer is on, not whichever came last out of the loop: on
        // two displays Escape was being typed into an overlay nobody was looking at.
        let front = windows.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? windows.first
        front?.makeKeyAndOrderFront(nil)
        front?.makeFirstResponder(front?.contentView)

        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive else { return event }
            switch event.keyCode {
            case 53:                                          // escape
                self.cancel()
                return nil
            case 36, 76:                                      // return, enter
                guard self.views.contains(where: \.hasSelection) else {
                    self.nudge()
                    return nil
                }
                self.onConfirm()
                return nil
            default:
                return event
            }
        }
    }

    /// Record was asked for with nothing drawn yet: the hint says so, in the accent, and
    /// shakes once — rather than a dialog over a screen that is already saying what to do.
    func nudge() {
        for view in views { view.nudge() }
    }

    /// Takes the overlay down without saying anything — the take is starting, or another
    /// mode was chosen.
    func end() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }

    private func cancel() {
        end()
        onCancel()
    }

    private func commit(_ rect: CGRect, on screen: NSScreen) {
        guard let displayID = Self.displayID(of: screen) else { return }
        // View points, origin bottom-left, into display points, origin top left — the flip
        // every capture API expects and every overlay forgets.
        let local = CGRect(x: rect.minX,
                           y: screen.frame.height - rect.maxY,
                           width: rect.width,
                           height: rect.height).integral
        for view in views { view.refreshHint() }
        onChange(Selection(displayID: displayID, rect: local))
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// Borderless, but able to take the keyboard, so Escape closes it.
private final class AreaSelectionWindow: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// The dimmed overlay on one screen, and the area on it if it is on this one.
private final class AreaSelectionView: NSView {
    var onBegin: () -> Void = {}
    var onCommit: (CGRect) -> Void = { _ in }
    var onConfirm: () -> Void = {}
    var hasSelectionElsewhere: () -> Bool = { false }

    private let screen: NSScreen
    /// The area, in this view's points.
    private var selection: CGRect?
    private var gesture: Gesture?
    /// The area as it was when the press began, for a press that turns out to be a click.
    private var before: CGRect?
    private let hint = HintView()

    /// What the press that is going on is doing.
    private enum Gesture {
        case draw(origin: CGPoint)
        case move(start: CGPoint, from: CGRect)
        case resize(Handle, from: CGRect)
    }

    /// The eight places an area is resized from.
    private enum Handle: CaseIterable {
        case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .bottom: CGPoint(x: rect.midX, y: rect.minY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .right: CGPoint(x: rect.maxX, y: rect.midY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
            case .top: CGPoint(x: rect.midX, y: rect.maxY)
            case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .left: CGPoint(x: rect.minX, y: rect.midY)
            }
        }

        var cursor: NSCursor {
            switch self {
            case .left, .right: .resizeLeftRight
            case .top, .bottom: .resizeUpDown
            default: .crosshair
            }
        }
    }

    private static let minimumSide: CGFloat = 16
    private static let handleReach: CGFloat = 9
    private static let accent = NSColor(srgbRed: 0.18, green: 0.42, blue: 1, alpha: 1)

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        addSubview(hint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    var hasSelection: Bool { selection != nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    /// The first press starts the drag even when Cue Studio is not the active app.
    /// Without this, macOS spends that press on bringing the window forward and the view
    /// never hears it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ rect: CGRect) {
        selection = rect
        changed()
    }

    func clear() {
        guard selection != nil else { return }
        selection = nil
        changed()
    }

    func nudge() {
        hint.nudge()
    }

    /// The hint is there only while there is no area anywhere: once there is one, the area
    /// itself is the instruction.
    func refreshHint() {
        hint.isHidden = selection != nil || hasSelectionElsewhere()
        layoutHint()
    }

    private func changed() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        refreshHint()
    }

    override func layout() {
        super.layout()
        layoutHint()
    }

    private func layoutHint() {
        let size = hint.fittingSize
        hint.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                            y: ((bounds.height - size.height) / 2).rounded(),
                            width: size.width, height: size.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Light: enough to say "the screen is waiting for you", not so much that you
        // cannot see what you are drawing around.
        NSColor.black.withAlphaComponent(0.22).setFill()
        bounds.fill()

        guard let rect = selection, rect.width > 1, rect.height > 1 else { return }

        // The area is punched through the dim so it shows what will be recorded, not an
        // approximation of it.
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        Self.accent.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.75, dy: -0.75))
        border.lineWidth = 1.5
        border.stroke()

        // Handles only once the drag is over: while drawing they are noise.
        if !isDrawing {
            for handle in Handle.allCases {
                let point = handle.point(in: rect)
                let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
                NSColor.white.setFill()
                dot.fill()
                Self.accent.setStroke()
                dot.lineWidth = 1.5
                dot.stroke()
            }
        }

        drawSize(of: rect)
    }

    private func drawSize(of rect: CGRect) {
        let label = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        var box = NSRect(x: rect.midX - size.width / 2 - 8,
                         y: rect.minY - size.height - 16,
                         width: size.width + 16,
                         height: size.height + 8)
        // Inside the area's bottom edge when there is no room under it.
        if box.minY < 6 { box.origin.y = rect.minY + 10 }
        box.origin.x = min(max(box.minX, 6), bounds.width - box.width - 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        label.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attributes)
    }

    // MARK: Pointer

    override func resetCursorRects() {
        // A crosshair says "drag me" without a word of instruction.
        addCursorRect(bounds, cursor: .crosshair)
        guard let rect = selection else { return }
        // AppKit throws on an empty or null cursor rect — which an area thinner than the
        // handles, inset by their reach, turns into — so each one is clipped and checked.
        func add(_ area: NSRect, _ cursor: NSCursor) {
            let clipped = area.intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
            addCursorRect(clipped, cursor: cursor)
        }
        add(rect.insetBy(dx: Self.handleReach, dy: Self.handleReach), .openHand)
        for handle in Handle.allCases {
            let point = handle.point(in: rect)
            add(NSRect(x: point.x - Self.handleReach, y: point.y - Self.handleReach,
                       width: Self.handleReach * 2, height: Self.handleReach * 2),
                handle.cursor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        before = selection

        if let rect = selection {
            if let handle = Handle.allCases.first(where: { Self.distance($0.point(in: rect), point) <= Self.handleReach }) {
                gesture = .resize(handle, from: rect)
                return
            }
            if rect.contains(point) {
                if event.clickCount == 2 {
                    onConfirm()
                    return
                }
                gesture = .move(start: point, from: rect)
                NSCursor.closedHand.set()
                return
            }
        }
        gesture = .draw(origin: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let gesture else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))

        switch gesture {
        case .draw(let origin):
            let drawn = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                               width: abs(point.x - origin.x), height: abs(point.y - origin.y))
            // Only a real drag replaces the area — a twitch of the mouse while clicking
            // should not wipe out the one already drawn.
            guard drawn.width >= Self.minimumSide || drawn.height >= Self.minimumSide else { return }
            onBegin()
            selection = drawn
        case .move(let start, let from):
            var moved = from.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
            selection = moved
        case .resize(let handle, let from):
            selection = Self.resize(from, handle: handle, to: point)
        }
        needsDisplay = true
        refreshHint()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            changed()
        }
        guard let rect = selection else { return }
        if isDrawing, rect.width < Self.minimumSide || rect.height < Self.minimumSide {
            // A click, or a slip of a drag: not a ten-pixel recording. The area that was
            // there before the press is still the area.
            selection = before
            return
        }
        guard rect != before else { return }
        onCommit(rect.integral)
    }

    private var isDrawing: Bool {
        if case .draw = gesture { return true }
        return false
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// The rectangle with one edge or corner moved to `point`, kept the right way round
    /// and never smaller than the smallest area worth recording.
    private static func resize(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft: minX = min(point.x, maxX - minimumSide)
        case .right, .topRight, .bottomRight: maxX = max(point.x, minX + minimumSide)
        default: break
        }
        switch handle {
        case .bottom, .bottomLeft, .bottomRight: minY = min(point.y, maxY - minimumSide)
        case .top, .topLeft, .topRight: maxY = max(point.y, minY + minimumSide)
        default: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    override func keyDown(with event: NSEvent) {
        // Escape and Return are the controller's; everything else is ignored so a stray
        // key cannot start a take.
        if event.keyCode == 53 { window?.cancelOperation(nil) }
    }
}

/// "Drag to select an area to record" — quiet, until record is pressed with nothing
/// drawn, when it turns the accent and shakes.
private final class HintView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "esc to cancel")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 19
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        detail.font = .systemFont(ofSize: 12, weight: .medium)
        detail.textColor = NSColor.white.withAlphaComponent(0.6)
        for field in [label, detail] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        style(nudged: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The hint is information, not a target: presses go through to the drag under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func nudge() {
        style(nudged: true)
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -9, 9, -6, 6, -3, 3, 0]
        shake.duration = 0.42
        layer?.add(shake, forKey: "shake")
    }

    private func style(nudged: Bool) {
        label.stringValue = nudged ? "Select an area to record first" : "Drag to select an area to record"
        layer?.backgroundColor = nudged
            ? NSColor(srgbRed: 0.18, green: 0.42, blue: 1, alpha: 0.95).cgColor
            : NSColor.black.withAlphaComponent(0.66).cgColor
        detail.textColor = NSColor.white.withAlphaComponent(nudged ? 0.75 : 0.6)
        needsLayout = true
        superview?.needsLayout = true
    }
}
