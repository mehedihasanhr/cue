import AppKit
import CoreGraphics
import Foundation
import RecordKit

/// Choosing a window by pointing at it.
///
/// The old picker was a grid of window *names* floating over a dimmed screen — which asked
/// you to read "Finder · Untitled window" while the window itself was six inches away,
/// half-visible through the scrim, with its name nowhere on it. Anyone choosing a window
/// already knows which one they mean; the list made them translate that into a title they
/// had never looked at, and several apps offer three windows called the same thing.
///
/// So this works the way the system's own screenshot tool works: move over the screen, the
/// window under the pointer lights up and names itself, click to take it. The list is still
/// there behind `L`, because a window on another Space cannot be pointed at and still has
/// to be reachable.
///
/// AppKit rather than SwiftUI for the same reason `AreaSelectionController` is: the whole
/// interaction is mouse movement over a transparent overlay that must sit above everything,
/// including full-screen apps, which is exactly where a plain `NSView` is less code.
@MainActor
final class WindowPickerController {
    /// What the picker hands back: a window, the request to show the list instead, or
    /// nothing at all.
    enum Outcome {
        case picked(RecorderModel.Source)
        case wantsList
        case cancelled
    }

    private var windows: [NSWindow] = []
    private var finish: ((Outcome) -> Void)?

    /// Puts an overlay on every screen and calls back exactly once.
    func begin(candidates: [RecorderModel.Source], _ completion: @escaping (Outcome) -> Void) {
        finish = completion
        // Only what can actually be pointed at.
        //
        // Deliberately *not* filtered on `isOnScreen`: that flag is the window server's
        // opinion, it is false for anything on another Space, and — the reason this is a
        // filter on geometry instead — it has been observed false for windows that are
        // plainly visible. A window with a real frame that lands on a real screen can be
        // pointed at; one that cannot be is simply never under the pointer, which costs
        // nothing. Getting this wrong the other way costs everything: a dim screen that
        // highlights nothing and does nothing when clicked.
        let screens = NSScreen.screens.map(\.frame)
        let pointable = candidates.filter { source in
            guard source.frame.width > 1, source.frame.height > 1 else { return false }
            guard let primary = NSScreen.screens.first else { return true }
            let onGlass = DisplayGeometry.appKit(source.frame, primaryMaxY: primary.frame.maxY)
            return screens.contains { $0.intersects(onGlass) }
        }

        // Nothing to point at — every window is on another Space, or the list arrived
        // empty. The list is the honest answer rather than an overlay that does nothing.
        guard !pointable.isEmpty else {
            completion(.wantsList)
            return
        }

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: [.borderless],
                                  backing: .buffered,
                                  defer: false,
                                  screen: screen)
            // Above full-screen apps, which is the whole point: a full-screen window is
            // the one people most want to record and the one an ordinary overlay cannot
            // reach over.
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.acceptsMouseMovedEvents = true
            window.isExcludedFromWindowsMenu = true
            window.animationBehavior = .none

            let view = WindowPickerView(screen: screen, candidates: pointable)
            view.onFinish = { [weak self] outcome in self?.close(with: outcome) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        // Key, and first responder, on the screen the pointer is actually on — otherwise
        // esc and L are typed into an overlay on a display nobody is looking at, and the
        // picker appears to ignore the keyboard.
        let pointer = NSEvent.mouseLocation
        let underPointer = windows.first { NSMouseInRect(pointer, $0.frame, false) } ?? windows.first
        underPointer?.makeKeyAndOrderFront(nil)
        underPointer?.makeFirstResponder(underPointer?.contentView)
    }

    private func close(with outcome: Outcome) {
        let finish = finish
        self.finish = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        finish?(outcome)
    }
}

/// The glass over one screen: a dim, a lit window, and its name.
private final class WindowPickerView: NSView {
    var onFinish: ((WindowPickerController.Outcome) -> Void)?

    private let screenFrame: CGRect
    private let candidates: [RecorderModel.Source]
    /// The window under the pointer, in this view's coordinates.
    private var highlighted: (source: RecorderModel.Source, rect: CGRect)?
    private var tracking: NSTrackingArea?

    init(screen: NSScreen, candidates: [RecorderModel.Source]) {
        self.screenFrame = screen.frame
        self.candidates = candidates
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NSCursor.crosshair.set()
        // The pointer is already somewhere when this opens; without this the first window
        // does not light up until the mouse is nudged.
        updateHighlight(to: NSEvent.mouseLocation)
    }

    // MARK: - Pointing

    override func mouseMoved(with event: NSEvent) {
        updateHighlight(to: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        updateHighlight(to: NSEvent.mouseLocation)
        if let highlighted {
            onFinish?(.picked(highlighted.source))
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish?(.cancelled)                       // Escape
        case 37: onFinish?(.wantsList)                       // L
        case 36, 76:                                          // Return
            if let highlighted { onFinish?(.picked(highlighted.source)) }
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onFinish?(.cancelled) }

    /// The frontmost window containing the pointer.
    ///
    /// `depth` is the window server's own front-to-back order, so the smallest one wins —
    /// which is what makes pointing at overlapping windows pick the one you can see rather
    /// than the one behind it.
    private func updateHighlight(to pointer: CGPoint) {
        let found = candidates
            .filter { flipped($0.frame).contains(pointer) }
            .min { $0.depth < $1.depth }

        let next = found.map { (source: $0, rect: convert(flipped($0.frame))) }
        // Redrawing on every mouse move would be redrawing a dim the size of a display
        // sixty times a second for nothing.
        guard next?.source.id != highlighted?.source.id else { return }
        highlighted = next
        needsDisplay = true
    }

    /// A window's frame as AppKit screen coordinates.
    ///
    /// Through `DisplayGeometry`, which is in a package with tests, rather than spelled
    /// out here: this flip is the one this project has already got wrong once.
    private func flipped(_ frame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return frame }
        return DisplayGeometry.appKit(frame, primaryMaxY: primary.frame.maxY)
    }

    private func convert(_ screenRect: CGRect) -> CGRect {
        CGRect(x: screenRect.minX - screenFrame.minX,
               y: screenRect.minY - screenFrame.minY,
               width: screenRect.width,
               height: screenRect.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // The dim, with the pointed-at window punched clear — so what lights up is the
        // real window, not a picture of its name.
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.fill(bounds)
        if let highlighted {
            context.setBlendMode(.clear)
            context.fill(highlighted.rect)
            context.setBlendMode(.normal)

            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(3)
            context.stroke(highlighted.rect.insetBy(dx: 1.5, dy: 1.5))

            label(for: highlighted.source, over: highlighted.rect, in: context)
        }

        hint(in: context)
    }

    private func label(for source: RecorderModel.Source, over rect: CGRect, in context: CGContext) {
        var name = source.subtitle.isEmpty ? source.title : "\(source.title) · \(source.subtitle)"
        if !source.isShareable {
            // Said here rather than after the take, when the file is a black rectangle and
            // the recording is gone.
            name += "  ·  hidden from recording"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: source.isShareable ? NSColor.white : NSColor.systemOrange,
        ]
        let text = NSAttributedString(string: name, attributes: attributes)
        let size = text.size()
        let padding: CGFloat = 10
        let box = CGRect(x: rect.midX - (size.width + padding * 2) / 2,
                         y: max(12, rect.minY - size.height - padding * 2 - 8),
                         width: size.width + padding * 2,
                         height: size.height + padding)
        context.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        context.fillPath(roundedRect: box, radius: 8)
        text.draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2))
    }

    private func hint(in context: CGContext) {
        let text = NSAttributedString(
            string: highlighted == nil
                ? "Move over a window to choose it  ·  L for the full list  ·  esc to cancel"
                : "Click to record this window  ·  L for the full list  ·  esc to cancel",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ])
        let size = text.size()
        let padding: CGFloat = 12
        let box = CGRect(x: bounds.midX - (size.width + padding * 2) / 2,
                         y: 40,
                         width: size.width + padding * 2,
                         height: size.height + padding)
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.fillPath(roundedRect: box, radius: 10)
        text.draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2))
    }
}

private extension CGContext {
    func fillPath(roundedRect rect: CGRect, radius: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        addPath(path)
        fillPath()
    }
}
