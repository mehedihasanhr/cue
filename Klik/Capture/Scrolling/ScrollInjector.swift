import AppKit
import CoreGraphics

/// Posts synthetic, pixel-precise ("trackpad-style") scroll-wheel events so the
/// content under a point scrolls by an exact number of points. Requires the
/// Accessibility permission; without it the user scrolls by hand instead.
enum ScrollInjector {
    /// Scrolls the content at `point` (CoreGraphics coordinates) down by `points`.
    static func scrollDown(points: Int32, at point: CGPoint) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: -points, wheel2: 0, wheel3: 0
        ) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}
