import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// What a display recording leaves out, worked out as a plan before any filter is built.
///
/// Two things are left out, for two different reasons, and ScreenCaptureKit makes them
/// awkward to say together:
///
/// - **Cue Studio and Cue themselves** — the bar, the menu bar icon and its menu, the
///   speaker notes, the camera preview, any alert. These are left out *by application*,
///   which is the only form that also covers a window opened halfway through the take:
///   the menu bar icon's menu, opened to press Stop, is a window that did not exist when
///   the filter was made.
/// - **The desktop's icons**, when asked. These are windows of the Finder, and the Finder
///   also owns the windows somebody may be demonstrating. So the Finder is left out by
///   application too, and every Finder window that is *not* the desktop is named back in
///   as an exception.
///
/// A filter cannot exclude applications and individual windows at once — its initialisers
/// take one or the other — which is why the icons are removed this roundabout way rather
/// than by naming their windows. The one cost is that a Finder window that opens during
/// the take is not among the exceptions until the filter is rebuilt; `DesktopIconsWatcher`
/// notices and rebuilds it within a quarter of a second.
public struct CaptureExclusion: Equatable, Sendable {
    /// One window, as much of it as the plan needs.
    public struct Window: Equatable, Sendable {
        public var id: CGWindowID
        public var bundleID: String?
        /// The window server's layer. Ordinary windows are at 0; menus and panels above.
        public var layer: Int

        public init(id: CGWindowID, bundleID: String?, layer: Int) {
            self.id = id
            self.bundleID = bundleID
            self.layer = layer
        }
    }

    /// Applications whose every window is left out, by bundle identifier.
    public var excludedApplications: Set<String>
    /// Windows of those applications that are recorded all the same.
    public var exceptedWindows: Set<CGWindowID>

    public static let finderBundleID = "com.apple.finder"

    /// The plan for a display or an area.
    ///
    /// - Parameters:
    ///   - running: the bundle identifiers of what is running — only these can be excluded.
    ///   - windows: every window ScreenCaptureKit lists.
    ///   - ownBundleIDs: this app and its host, which are always left out.
    public static func plan(running: [String],
                            windows: [Window],
                            ownBundleIDs: Set<String>,
                            hidesDesktopIcons: Bool) -> CaptureExclusion {
        var excluded = Set(running).intersection(ownBundleIDs)
        var excepted: Set<CGWindowID> = []
        if hidesDesktopIcons, running.contains(finderBundleID), !ownBundleIDs.contains(finderBundleID) {
            excluded.insert(finderBundleID)
            excepted = Set(windows.filter { $0.bundleID == finderBundleID && !isDesktop($0) }.map(\.id))
        }
        return CaptureExclusion(excludedApplications: excluded, exceptedWindows: excepted)
    }

    /// Whether a window is part of the desktop the Finder draws: its icons, the stacks, and
    /// the invisible window that catches clicks on the wallpaper.
    ///
    /// Told apart by layer, not by title or size. The Finder puts the desktop at
    /// `kCGDesktopIconWindowLevel`, a little above the very bottom of the window server's
    /// range and far below 0, where every ordinary window lives — so a Finder window below
    /// the normal layer is the desktop, and nothing else the Finder shows ever is. The
    /// wallpaper itself belongs to the Dock or the wallpaper agent, is not the Finder's, and
    /// stays in the picture; so do desktop widgets, which belong to their own process.
    public static func isDesktop(_ window: Window) -> Bool {
        window.bundleID == finderBundleID && window.layer < Int(CGWindowLevelForKey(.normalWindow))
    }
}

extension ShareableContentStore {
    /// The filter for a target, leaving the desktop's icons out when asked.
    ///
    /// Only a display or an area has a desktop in it. A window recording is of that window
    /// alone, so it is built exactly as it always was.
    public func filter(for target: CaptureTarget,
                       in content: SCShareableContent,
                       hidingDesktopIcons: Bool) throws(RecordingError) -> SCContentFilter {
        guard hidingDesktopIcons, let displayID = target.displayID else {
            return try filter(for: target, in: content)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw .targetDisappeared
        }
        let plan = CaptureExclusion.plan(
            running: content.applications.map(\.bundleIdentifier),
            windows: content.windows.map {
                CaptureExclusion.Window(id: $0.windowID,
                                        bundleID: $0.owningApplication?.bundleIdentifier,
                                        layer: $0.windowLayer)
            },
            ownBundleIDs: excludedBundleIDs,
            hidesDesktopIcons: true)
        let applications = content.applications.filter { plan.excludedApplications.contains($0.bundleIdentifier) }
        let exceptions = content.windows.filter { plan.exceptedWindows.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: exceptions)
    }
}

/// Notices a Finder window opening or closing while the desktop's icons are being left
/// out, so the filter can be rebuilt with it named back in.
///
/// Asks the window server rather than ScreenCaptureKit: a list of the windows on screen is
/// cheap enough to read four times a second, and ScreenCaptureKit is asked only when that
/// list has actually changed.
@MainActor
public final class DesktopIconsWatcher {
    private var timer: Timer?
    /// Empty to begin with, not what is on screen now: the filter was made before the
    /// countdown, and a Finder window opened during it has to count as a change.
    private var last: Set<CGWindowID> = []
    private let onChange: @MainActor () async -> Void

    public init(interval: TimeInterval = 0.25, onChange: @escaping @MainActor () async -> Void) {
        self.onChange = onChange
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let now = Self.finderWindows()
        guard now != last else { return }
        last = now
        Task { await onChange() }
    }

    /// The Finder's ordinary windows on screen right now: everything of its at or above
    /// the normal layer, which is everything but the desktop.
    static func finderWindows() -> Set<CGWindowID> {
        let finders = Set(NSRunningApplication.runningApplications(withBundleIdentifier: CaptureExclusion.finderBundleID)
            .map(\.processIdentifier))
        guard !finders.isEmpty,
              let listing = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return Set(listing.compactMap { entry -> CGWindowID? in
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, finders.contains(owner),
                  let layer = entry[kCGWindowLayer as String] as? Int, layer >= 0 else { return nil }
            return entry[kCGWindowNumber as String] as? CGWindowID
        })
    }
}
