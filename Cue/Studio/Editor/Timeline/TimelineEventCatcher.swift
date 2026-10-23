import AppKit
import SwiftUI

/// Scroll and pinch over the timeline.
///
/// A local `NSEvent` monitor rather than an overridden `scrollWheel`, for the same
/// reason the host app's `StripEventView` uses one: AppKit routes scrolling through
/// `hitTest`, so a transparent SwiftUI overlay that lets clicks through lets scrolls
/// through as well. The monitor sees them wherever they land and filters by bounds.
struct TimelineEventCatcher: NSViewRepresentable {
    /// Points to move the view by, positive meaning "later".
    let scroll: (Double) -> Void
    /// A multiplier on the current zoom, and where the pointer was, in view points.
    let magnify: (Double, Double) -> Void

    func makeNSView(context: Context) -> CatchingView {
        let view = CatchingView()
        view.scroll = scroll
        view.magnify = magnify
        return view
    }

    func updateNSView(_ view: CatchingView, context: Context) {
        view.scroll = scroll
        view.magnify = magnify
    }

    final class CatchingView: NSView {
        var scroll: ((Double) -> Void)?
        var magnify: ((Double, Double) -> Void)?

        /// AppKit vends an event monitor as `Any?`, which a nonisolated `deinit` is not
        /// allowed to touch. Boxing it gives the teardown something it may read, so the
        /// monitor goes away when the view does rather than only when the view is
        /// politely removed from its window first.
        private let monitor = MonitorBox()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                monitor.clear()
            } else if !monitor.isInstalled {
                monitor.token = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                    self?.handle(event) == true ? nil : event
                }
            }
        }

        deinit { monitor.clear() }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }

            switch event.type {
            case .magnify:
                magnify?(1 + event.magnification, point.x)
                return true
            case .scrollWheel:
                if event.modifierFlags.contains(.command) {
                    // ⌘-scroll is the mouse's version of a pinch.
                    magnify?(1 + event.scrollingDeltaY * 0.01, point.x)
                } else {
                    // A trackpad reports in points; a wheel reports in lines.
                    let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                        ? event.scrollingDeltaX : event.scrollingDeltaY
                    scroll?(event.hasPreciseScrollingDeltas ? -delta : -delta * 8)
                }
                return true
            default:
                return false
            }
        }
    }
}

/// Somewhere to keep an event monitor that `deinit` is allowed to reach.
private final class MonitorBox: @unchecked Sendable {
    nonisolated(unsafe) var token: Any?

    nonisolated var isInstalled: Bool { token != nil }

    nonisolated func clear() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
