import os
import AppKit
import ScreenCaptureKit

enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case noDisplay
    case cancelled
    case underlying(any Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Cue doesn't have Screen Recording permission."
        case .noDisplay: "No display is available to capture."
        case .cancelled: "The capture was cancelled."
        case .underlying(let error): error.localizedDescription
        }
    }
}

/// Thin wrapper over ScreenCaptureKit for single-shot captures.
///
/// `SCScreenshotManager` (macOS 14+) is used instead of an `SCStream` because a
/// screenshot needs exactly one frame. Should SCK misbehave on a particular
/// display configuration, `CGDisplayCreateImage` is the (deprecated) fallback —
/// it loses HDR/color-space fidelity but needs no stream plumbing.
final class ScreenCaptureService {
    func shareableContent() async throws(CaptureError) -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// The display under the given AppKit-coordinate point (e.g. `NSEvent.mouseLocation`),
    /// falling back to the first display.
    func display(containing point: CGPoint, in content: SCShareableContent) -> SCDisplay? {
        let screenID = NSScreen.screens
            .first { NSMouseInRect(point, $0.frame, false) }?
            .displayID
        return content.displays.first { $0.displayID == screenID } ?? content.displays.first
    }

    // MARK: - Full display

    /// The whole display, without Cue's own windows (the island, HUDs, panels).
    func captureDisplay(_ display: SCDisplay, in content: SCShareableContent, includeCursor: Bool = false) async throws(CaptureError) -> CapturedImage {
        let filter = Self.filterLeavingCueOut(display: display, in: content)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = Self.configuration(pointSize: CGSize(width: display.width, height: display.height), scale: scale)
        configuration.showsCursor = includeCursor
        let cgImage = try await capture(filter: filter, configuration: configuration)
        return CapturedImage(cgImage: cgImage, scale: scale, displayID: display.displayID, capturedAt: .now)
    }

    /// One frozen frame per connected display, keyed by display ID. Used to build the
    /// area-selection overlay so the selection and magnifier read pixel-exact data.
    func captureAllDisplays() async throws(CaptureError) -> [CGDirectDisplayID: CapturedImage] {
        let content = try await shareableContent()
        var images: [CGDirectDisplayID: CapturedImage] = [:]
        for display in content.displays {
            images[display.displayID] = try await captureDisplay(display, in: content)
        }
        return images
    }

    // MARK: - Window

    /// One window by itself, with its shadow, on a transparent background — the
    /// way a screenshot for a doc or a post wants it.
    func captureWindow(id: CGWindowID, in content: SCShareableContent, fallbackScale: CGFloat) async throws(CaptureError) -> CapturedImage? {
        guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale) > 0 ? CGFloat(filter.pointPixelScale) : fallbackScale
        let size = filter.contentRect.size
        let configuration = Self.configuration(pointSize: size, scale: scale)
        configuration.ignoreShadowsSingleWindow = false
        configuration.showsCursor = false
        let cgImage = try await capture(filter: filter, configuration: configuration)
        return CapturedImage(cgImage: cgImage, scale: scale, displayID: 0, capturedAt: .now)
    }

    // MARK: - Region

    /// Captures `rect` (global AppKit points) on the display that owns `screen`, leaving
    /// out every window belonging to Cue itself (HUDs, overlays).
    func captureRegion(_ rect: CGRect, on screen: NSScreen) async throws(CaptureError) -> CapturedImage {
        try await makeRegionCapturer(rect, on: screen).capture()
    }

    /// Diagnostics only: `rect` as the screen shows it, Cue's own windows included —
    /// the way to see a translucent Cue window over the desktop from outside.
    func captureRegionIncludingCue(_ rect: CGRect, on screen: NSScreen) async throws(CaptureError) -> CGImage {
        let content = try await shareableContent()
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw .noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = Self.configuration(pointSize: rect.size, scale: CGFloat(filter.pointPixelScale))
        configuration.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        return try await capture(filter: filter, configuration: configuration)
    }

    /// Prepares a filter + configuration once so repeated captures of the same region
    /// (scrolling capture) skip the shareable-content query.
    func makeRegionCapturer(_ rect: CGRect, on screen: NSScreen) async throws(CaptureError) -> RegionCapturer {
        let content = try await shareableContent()
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw .noDisplay }

        let filter = Self.filterLeavingCueOut(display: display, in: content)
        let scale = CGFloat(filter.pointPixelScale)

        let configuration = Self.configuration(pointSize: rect.size, scale: scale)
        // sourceRect is in points, relative to the display's top-left corner (y down).
        configuration.sourceRect = CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        return RegionCapturer(service: self, filter: filter, configuration: configuration, scale: scale, displayID: displayID)
    }

    struct RegionCapturer {
        fileprivate let service: ScreenCaptureService
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let scale: CGFloat
        let displayID: CGDirectDisplayID

        func capture() async throws(CaptureError) -> CapturedImage {
            let cgImage = try await service.capture(filter: filter, configuration: configuration)
            return CapturedImage(cgImage: cgImage, scale: scale, displayID: displayID, capturedAt: .now)
        }
    }

    // MARK: - Internals

    /// The display without Cue's floating windows (the island, HUDs, the dim overlay,
    /// the scrolling preview, the recorder bar): by application when ScreenCaptureKit
    /// lists us, else by the windows it does know. The island is shareable so that screen
    /// sharing and recordings show it; this filter is what keeps it out of Cue's own shots.
    ///
    /// Cue's ordinary windows — the video editor, Recordings, Settings — are documents
    /// like any other app's, and stay in the picture.
    private static func filterLeavingCueOut(display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier
        // By process ID, and by bundle identifier as well: ScreenCaptureKit does not
        // always list the calling app, and then the process ID matches nothing.
        func isOwn(_ app: SCRunningApplication) -> Bool {
            app.processID == pid || (bundleID != nil && app.bundleIdentifier == bundleID)
        }
        let ownApps = content.applications.filter(isOwn)
        let ownWindows = content.windows.filter { $0.owningApplication.map(isOwn) ?? false }
        let documents = ownWindows.filter { $0.windowLayer == 0 }
        let chrome = ownWindows.filter { $0.windowLayer != 0 }
        Log.capture.info("Capture filter excludes \(ownApps.count) app(s) / \(chrome.count) own window(s), keeps \(documents.count)")
        return ownApps.isEmpty
            ? SCContentFilter(display: display, excludingWindows: chrome)
            : SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: documents)
    }

    private static func configuration(pointSize: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int((pointSize.width * scale).rounded())
        configuration.height = Int((pointSize.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        return configuration
    }

    fileprivate func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws(CaptureError) -> CGImage {
        let start = ContinuousClock.now
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            Log.capture.debug("Captured \(image.width)×\(image.height)px in \(ContinuousClock.now - start)")
            return image
        } catch {
            throw Self.mapped(error)
        }
    }

    private static func mapped(_ error: any Error) -> CaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.userDeclined.rawValue {
            return .permissionDenied
        }
        Log.capture.error("ScreenCaptureKit error: \(nsError.domain, privacy: .public) \(nsError.code) \(nsError.localizedDescription, privacy: .public)")
        return .underlying(error)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }

    /// The primary display's height — the pivot for converting between AppKit
    /// (origin bottom-left, y up) and CoreGraphics (origin top-left, y down) coordinates.
    static var primaryHeight: CGFloat {
        screens.first?.frame.height ?? 0
    }
}

extension CGPoint {
    /// AppKit global point → CoreGraphics global point.
    var cgCoordinates: CGPoint {
        CGPoint(x: x, y: NSScreen.primaryHeight - y)
    }
}

extension CGRect {
    /// CoreGraphics global rect → AppKit global rect.
    var appKitCoordinates: CGRect {
        CGRect(x: minX, y: NSScreen.primaryHeight - maxY, width: width, height: height)
    }
}
