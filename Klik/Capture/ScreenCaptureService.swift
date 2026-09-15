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
        case .permissionDenied: "Klik doesn't have Screen Recording permission."
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
/// it loses HDR/colour-space fidelity but needs no stream plumbing.
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

    func captureDisplay(_ display: SCDisplay, includeCursor: Bool = false) async throws(CaptureError) -> CapturedImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
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
            images[display.displayID] = try await captureDisplay(display)
        }
        return images
    }

    // MARK: - Region

    /// Captures `rect` (global AppKit points) on the display that owns `screen`, leaving
    /// out every window belonging to Klik itself (HUDs, overlays).
    func captureRegion(_ rect: CGRect, on screen: NSScreen) async throws(CaptureError) -> CapturedImage {
        try await makeRegionCapturer(rect, on: screen).capture()
    }

    /// Prepares a filter + configuration once so repeated captures of the same region
    /// (scrolling capture) skip the shareable-content query.
    func makeRegionCapturer(_ rect: CGRect, on screen: NSScreen) async throws(CaptureError) -> RegionCapturer {
        let content = try await shareableContent()
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw .noDisplay }

        // Leave out every Klik window (HUDs, the dim overlay, the scrolling preview). By
        // application when ScreenCaptureKit lists us, else by the windows it does know.
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = ownApps.isEmpty
            ? SCContentFilter(display: display, excludingWindows: ownWindows)
            : SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        Log.capture.info("Region filter excludes \(ownApps.count) app(s) / \(ownWindows.count) own window(s)")
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
