import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A picture of a window, for choosing between windows.
///
/// A list of names is the wrong instrument when an application offers five windows and
/// calls them all by its own name — which is what Chrome, Finder and a browser with
/// several profiles all do. The title is often empty, often identical, and never the thing
/// the person is picturing. They are picturing the window.
///
/// `SCScreenshotManager` rather than `CGWindowListCreateImage`: the latter is deprecated,
/// is refused outright on recent systems, and would be a second capture path alongside the
/// one the recorder already uses. This asks the same framework the recording does, so a
/// window that cannot be photographed here is exactly the window that would have recorded
/// as a black rectangle — which makes a missing thumbnail a useful signal rather than a
/// glitch.
public enum WindowThumbnail {
    /// One window, no larger than `maximumWidth` points on its long edge.
    ///
    /// Returns `nil` rather than throwing: a thumbnail is a convenience, and a window that
    /// refuses to be photographed still has to be offerable by name.
    /// Takes window *ids* rather than `SCWindow`s because `SCWindow` is not `Sendable`:
    /// handing one to a background task is a data race the compiler is right to refuse.
    /// Resolving them here costs one extra query and keeps the crossing honest.
    public static func images(of ids: [CGWindowID],
                              maximumWidth: CGFloat = 320,
                              each: @Sendable @escaping (CGWindowID, CGImage) async -> Void) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false,
                                                                                  onScreenWindowsOnly: false)
        else { return }
        let wanted = Set(ids)
        for window in content.windows where wanted.contains(window.windowID) {
            guard !Task.isCancelled else { return }
            guard let image = await image(of: window, maximumWidth: maximumWidth) else { continue }
            await each(window.windowID, image)
        }
    }

    static func image(of window: SCWindow, maximumWidth: CGFloat = 320) async -> CGImage? {
        let scale = min(1, maximumWidth / max(window.frame.width, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.scalesToFit = true
        configuration.showsCursor = false
        // No point paying for colour accuracy in a 320-point tile.
        configuration.captureResolution = .nominal

        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: configuration)
    }
}
