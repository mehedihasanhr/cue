import AppKit

/// Keeps a drag over the island out of the menu bar, where macOS opens Mission
/// Control's Spaces bar on it.
///
/// A drag that lingers anywhere in the menu bar's band (not only at the screen's
/// edge) brings the Spaces bar down, and the island sits in that band: every file
/// dragged onto the notch, and every card dragged about inside the open island, ended
/// with the window list over it. Accepting the drop doesn't stop it, and moving the
/// pointer back after the fact is too late: the Dock has already seen it arrive. So
/// the drag events are changed on their way through, before anything downstream sees
/// them: while a drag and drop is over the island's span, the pointer stops a point
/// below the menu bar, and the island opens there to take the drop.
///
/// An active event tap, so it needs Accessibility; without it Cue behaves as before.
/// Only drags carrying something (a drag pasteboard written since the press) are held,
/// so selecting text or moving a window is never touched, and only across the island.
@MainActor
final class IslandDragGuard {
    /// The band to keep drags out of, in Quartz (top-left) screen coordinates.
    nonisolated(unsafe) private static var zone: CGRect = .null
    /// The drag pasteboard's count at the last press: changed means a drag and drop.
    nonisolated(unsafe) private static var pressCount = 0
    /// Whether the current drag has already been held (the island told once per drag).
    nonisolated(unsafe) private static var heldThisDrag = false
    nonisolated(unsafe) private static var tap: CFMachPort?
    nonisolated(unsafe) private static var onHeld: (@MainActor () -> Void)?
    /// Off while the island is hidden (a capture flow) or has no screen.
    nonisolated(unsafe) static var active = false

    /// Starts the tap. Returns false when it can't (no Accessibility).
    @discardableResult
    static func start(onHeld: @escaping @MainActor () -> Void) -> Bool {
        guard tap == nil else { return true }
        self.onHeld = onHeld
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
            IslandDragGuard.handle(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return false }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// The island's span on its screen, in Cocoa coordinates: the band held clear is
    /// the menu bar's height across it.
    static func update(span: ClosedRange<CGFloat>, on screen: NSScreen) {
        guard let primary = NSScreen.screens.first else { return }
        let menuBar = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        let top = primary.frame.maxY - screen.frame.maxY
        zone = CGRect(x: span.lowerBound, y: top, width: span.upperBound - span.lowerBound, height: menuBar)
    }

    /// Runs on the main thread (the tap's run loop source is on the main run loop).
    nonisolated private static func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            pressCount = NSPasteboard(name: .drag).changeCount
            heldThisDrag = false
        case .leftMouseDragged:
            guard active else { return }
            var location = event.location
            guard zone.contains(location) || (location.y < zone.minY && location.x >= zone.minX && location.x <= zone.maxX) else { return }
            guard NSPasteboard(name: .drag).changeCount != pressCount else { return }
            location.y = zone.maxY + 1
            event.location = location
            if !heldThisDrag {
                heldThisDrag = true
                DispatchQueue.main.async { MainActor.assumeIsolated { onHeld?() } }
            }
        default:
            break
        }
    }
}
