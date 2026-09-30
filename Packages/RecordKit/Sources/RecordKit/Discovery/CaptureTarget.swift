import AddOnKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// What is being recorded.
public enum CaptureTarget: Sendable, Hashable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// A rectangle of a display, in that display's points with the origin at its top left.
    case area(display: CGDirectDisplayID, rect: CGRect)
    /// An iPhone or iPad on a cable, by its capture device's `uniqueID` — see
    /// `DeviceScreens`. Not a thing on this Mac's screen at all: its picture comes from
    /// AVFoundation rather than ScreenCaptureKit, and it has no pointer to follow.
    case device(uniqueID: String)

    public var displayID: CGDirectDisplayID? {
        switch self {
        case .display(let id), .area(let id, _): id
        case .window, .device: nil
        }
    }

    /// The capture device's `uniqueID` for a device target, `nil` for anything on screen.
    public var deviceID: String? {
        if case .device(let id) = self { id } else { nil }
    }

    /// Whether this target is one of the Mac's own screens — a display, a window or an
    /// area — which is what decides whether ScreenCaptureKit, the Screen Recording grant
    /// and the pointer have anything to do with the take.
    public var isOnScreen: Bool { deviceID == nil }

    /// The recorded area's top-left, given where the thing it is part of sits on screen.
    ///
    /// `container` is the display's bounds for a display or an area, and the window's frame
    /// for a window — both already in the space the pointer is read in: points, y
    /// downwards, main display's top-left at zero.
    ///
    /// Pulled out as arithmetic on its own so it can be checked without a screen. The
    /// mistake it replaces was not a hard sum, it was asking the wrong object for the
    /// number, and a sum nobody can run is how that survives.
    public func origin(inside container: CGRect) -> CGPoint {
        switch self {
        case .display, .window, .device:
            return container.origin
        case .area(_, let rect):
            // The area is measured from the display's top-left, so the recorded corner is
            // the display's corner plus the area's own offset.
            return CGPoint(x: container.origin.x + rect.origin.x,
                           y: container.origin.y + rect.origin.y)
        }
    }

    /// The target a host's request asks for, or `nil` when the request says "ask me" and
    /// the add-on has to put a picker up.
    public init?(_ request: RecordingRequest.Target) {
        switch request {
        case .display(let id): self = .display(id)
        case .window(let id): self = .window(id)
        case .area(let display, let rect): self = .area(display: display, rect: rect)
        case .device(let id): self = .device(uniqueID: id)
        case .ask: return nil
        }
    }
}

/// Which windows the system will actually let a recording see.
///
/// A window can refuse to be captured — `NSWindow.sharingType = .none`, which a browser's
/// private window and a password manager both use — and ScreenCaptureKit does not say so.
/// It lists the window, the recording starts, and what lands in the file is a black
/// rectangle. Asking the window server directly is the only way to know before the take
/// rather than after it.
public enum WindowSharing {
    /// The windows that would come out black, by id.
    ///
    /// Read from the window server rather than from `SCShareableContent`, which carries no
    /// equivalent. A window missing from the list is treated as shareable: the failure to
    /// read a state must not mark a perfectly good window as unrecordable.
    public static func refusing() -> Set<CGWindowID> {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let listing = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var refusing: Set<CGWindowID> = []
        for entry in listing {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let sharing = entry[kCGWindowSharingState as String] as? Int else { continue }
            if sharing == 0 { refusing.insert(id) }
        }
        return refusing
    }
}

/// What can be recorded right now.
///
/// A thin wrapper over `SCShareableContent` so the rest of the package never has to
/// think about the permission dance: this is where a missing grant becomes a typed
/// error rather than an empty list of displays.
public struct ShareableContentStore: Sendable {
    /// Windows the add-on should never offer, because recording your own recorder is
    /// never what anyone wanted.
    public let excludedBundleIDs: Set<String>

    public init(excludedBundleIDs: Set<String> = [AddOnBridge.studioBundleID, "com.stackrover.klik"]) {
        self.excludedBundleIDs = excludedBundleIDs
    }

    public func content() async throws(RecordingError) -> SCShareableContent {
        do {
            // `onScreenWindowsOnly: false` on purpose. A full-screen app lives on its
            // own Space, and a Space you are not looking at is not "on screen" — so the
            // strict version left the one window somebody most wants to record out of the
            // list entirely, with no way to reach it. The cost is that hidden and
            // minimised windows arrive too, which the caller filters on what it can see.
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            // SCK reports a missing Screen Recording grant as a plain stream error, and
            // the difference matters to the user: one is a dialog, the other is a bug.
            let code = (error as NSError).code
            if code == -3801 || code == -3802 { throw .permissionDenied }
            throw .contentUnavailable(error.localizedDescription)
        }
    }

    /// Where the recorded area's top-left sits in global screen points.
    ///
    /// The one number the pointer track is built on, and the one that was wrong. It has to
    /// be in `CGEvent`'s space — points, y downwards, main display's top-left at zero —
    /// because that is what the pointer is read in. `SCContentFilter.contentRect` is not in
    /// that space: its origin is zero, because it describes how big the content is rather
    /// than where on the desk it is. Reading it gave a translation of nothing, which is
    /// right only for a recording of the main display and wrong by a whole display or a
    /// whole window for everything else.
    ///
    /// `CGDisplayBounds` and `SCWindow.frame` are both already in that space, which is why
    /// they are asked instead.
    public func origin(of target: CaptureTarget, in content: SCShareableContent) -> CGPoint {
        switch target {
        case .display(let id), .area(let id, _):
            return target.origin(inside: CGDisplayBounds(id))
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { return .zero }
            return target.origin(inside: window.frame)
        case .device:
            // Not on the desk at all, so there is no corner of it to find.
            return .zero
        }
    }

    /// The filter for a target, with Klik's own windows left out.
    public func filter(for target: CaptureTarget, in content: SCShareableContent) throws(RecordingError) -> SCContentFilter {
        switch target {
        case .display(let id), .area(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                throw .targetDisappeared
            }
            let excluded = content.applications.filter { excludedBundleIDs.contains($0.bundleIdentifier) }
            return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw .targetDisappeared
            }
            return SCContentFilter(desktopIndependentWindow: window)
        case .device:
            // A device's picture comes from AVFoundation, and `RecordingSession` never asks
            // for a filter for one. Said as an error rather than trapped, because a caller
            // that did ask is a bug worth a readable message, not a crash mid-countdown.
            throw .contentUnavailable("an iPhone or iPad isn't on this Mac's screen")
        }
    }
}
