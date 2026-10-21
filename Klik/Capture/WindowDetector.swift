import AppKit
import CoreGraphics

/// An on-screen window, for hover-to-select and edge snapping.
struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let ownerName: String
    let title: String
    /// Global AppKit coordinates (points).
    let frame: CGRect
}

enum WindowDetector {
    /// Normal-level windows currently on screen, front to back. Klik's own count too — the
    /// video editor and Recordings are windows like any other app's — while its overlays,
    /// panels and HUDs sit above the normal level and are left out by it.
    static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict),
                  cgBounds.width >= 24, cgBounds.height >= 24
            else { return nil }

            return WindowInfo(
                id: id,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                frame: cgBounds.appKitCoordinates
            )
        }
    }

    /// Whether `screen` is showing another app's full-screen Space right now.
    ///
    /// Two signs together, because either alone lies: the menu bar is gone, so the
    /// visible frame reaches the top of the display (an auto-hiding menu bar does
    /// that too), and a window fills the whole display (a maximised window on a
    /// display with the menu bar showing does not).
    static func isFullScreenSpace(on screen: NSScreen) -> Bool {
        guard screen.visibleFrame.maxY >= screen.frame.maxY - 1 else { return false }
        let size = screen.frame.size
        return onScreenWindows().contains {
            abs($0.frame.width - size.width) < 2 && abs($0.frame.height - size.height) < 2
        }
    }

    /// The frontmost window containing `point` (global AppKit coordinates).
    static func window(at point: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.frame.contains(point) }
    }

    /// Snaps `point` to any window edge within `tolerance` points, per axis.
    static func snap(_ point: CGPoint, to windows: [WindowInfo], tolerance: CGFloat) -> CGPoint {
        var snapped = point
        var bestDX = tolerance
        var bestDY = tolerance
        for window in windows {
            for x in [window.frame.minX, window.frame.maxX] where abs(x - point.x) < bestDX {
                bestDX = abs(x - point.x)
                snapped.x = x
            }
            for y in [window.frame.minY, window.frame.maxY] where abs(y - point.y) < bestDY {
                bestDY = abs(y - point.y)
                snapped.y = y
            }
        }
        return snapped
    }
}
