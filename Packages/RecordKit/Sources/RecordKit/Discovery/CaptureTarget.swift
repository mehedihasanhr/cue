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

    public var displayID: CGDirectDisplayID? {
        switch self {
        case .display(let id), .area(let id, _): id
        case .window: nil
        }
    }

    /// The target a host's request asks for, or `nil` when the request says "ask me" and
    /// the add-on has to put a picker up.
    public init?(_ request: RecordingRequest.Target) {
        switch request {
        case .display(let id): self = .display(id)
        case .window(let id): self = .window(id)
        case .area(let display, let rect): self = .area(display: display, rect: rect)
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
        }
    }
}
