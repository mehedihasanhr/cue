import AppKit
import CoreGraphics
import Foundation

/// Dragging out the part of the screen to record.
///
/// A borderless window per display, dimmed, with the chosen rectangle punched clear.
/// AppKit rather than SwiftUI because the whole interaction is one mouse drag over a
/// transparent overlay that has to sit above everything including full-screen apps —
/// exactly the case where a plain `NSView` is less code than the alternative.
@MainActor
final class AreaSelectionController {
    struct Selection {
        /// Which display the rectangle is on.
        let displayID: CGDirectDisplayID
        /// The rectangle in that display's points, origin at its top left, which is what
        /// `SCStreamConfiguration.sourceRect` wants.
        let rect: CGRect
    }

    private var windows: [NSWindow] = []
    private var finish: ((Selection?) -> Void)?

    /// Puts an overlay on every screen and calls back once, with the selection or `nil`.
    func begin(_ completion: @escaping (Selection?) -> Void) {
        finish = completion

        for screen in NSScreen.screens {
            // A non-activating panel that can take the keyboard, like the target overlay.
            // A plain borderless window could not become key, so Escape never reached it,
            // and it relied on Klik Studio becoming the active app first — which macOS no
            // longer grants on request — so the press that should start the drag went on
            // activating the window instead, and the drag never began.
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
            window.animationBehavior = .none
            window.onCancel = { [weak self] in self?.end(with: nil) }

            let view = AreaSelectionView(screen: screen)
            view.onFinish = { [weak self] rect in
                guard let self else { return }
                if let rect, let displayID = Self.displayID(of: screen) {
                    // Screen points, origin bottom-left, into display points, origin top
                    // left — the flip every capture API expects and every overlay forgets.
                    let local = CGRect(x: rect.minX - screen.frame.minX,
                                       y: screen.frame.maxY - rect.maxY,
                                       width: rect.width,
                                       height: rect.height)
                    end(with: Selection(displayID: displayID, rect: local))
                } else {
                    end(with: nil)
                }
            }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            window.makeFirstResponder(view)
        }

        // Key on the screen the pointer is on, not whichever screen came last out of the
        // loop: on two displays escape was being typed into an overlay nobody was looking
        // at, and the drag appeared to ignore the keyboard.
        let front = windows.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? windows.first
        front?.makeKeyAndOrderFront(nil)
        front?.makeFirstResponder(front?.contentView)
    }

    private func end(with selection: Selection?) {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        let finish = finish
        self.finish = nil
        finish?(selection)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// Borderless, but able to take the keyboard, so Escape cancels the drag.
private final class AreaSelectionWindow: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// The dimmed overlay and the rectangle being dragged on it.
private final class AreaSelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private let screen: NSScreen
    private var origin: CGPoint?
    private var current: CGRect = .zero
    private var tracking: NSTrackingArea?

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: screen.frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    /// The first press starts the drag even when Klik Studio is not the active app. Without
    /// this, macOS spends that press on bringing the window forward and the view never
    /// hears it: the drag had no origin, and letting go read as a click — a cancel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        // A crosshair says "drag me" without a word of instruction.
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard current.width > 1, current.height > 1 else { return }

        // The selection is punched through the dim so the user sees what they will get,
        // not an approximation of it.
        NSColor.clear.setFill()
        current.fill(using: .copy)

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: current)
        border.lineWidth = 1.5
        border.stroke()

        let label = "\(Int(current.width)) × \(Int(current.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let box = NSRect(x: current.midX - size.width / 2 - 6,
                         y: max(current.minY - size.height - 10, 6),
                         width: size.width + 12,
                         height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        label.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        current = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        current = CGRect(x: min(origin.x, point.x),
                         y: min(origin.y, point.y),
                         width: abs(point.x - origin.x),
                         height: abs(point.y - origin.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { origin = nil }
        // A click with no drag is a cancel, not a zero-sized recording.
        guard current.width > 8, current.height > 8 else {
            onFinish?(nil)
            return
        }
        // Back into screen coordinates for the controller to turn into display points.
        let inScreen = CGRect(x: current.minX + screen.frame.minX,
                              y: current.minY + screen.frame.minY,
                              width: current.width,
                              height: current.height)
        onFinish?(inScreen)
    }

    override func keyDown(with event: NSEvent) {
        // Escape cancels; everything else is ignored so a stray key cannot start a take.
        if event.keyCode == 53 { onFinish?(nil) }
    }
}
