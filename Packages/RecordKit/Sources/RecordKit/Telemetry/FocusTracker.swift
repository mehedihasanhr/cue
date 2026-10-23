import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Records what had focus while the recording ran.
///
/// The companion to `CursorTracker`, and the reason a zoom can be about a *thing*
/// rather than a point. Three events, in descending order of how much they need from
/// the user:
///
/// - **application** — another app came forward. `NSWorkspace` tells us, free.
/// - **window** — the frontmost window changed, moved or resized. Read from the window
///   list, which needs no grant beyond the Screen Recording one a recording already has.
/// - **field** — keyboard focus landed on something text goes into. This one needs
///   Accessibility, so it is opt-in and simply absent when the grant is missing; every
///   other event still lands, and the editor degrades to zooming on windows and clicks.
///
/// Rectangles are mapped through the same `CursorMapper` the cursor samples use, so a
/// focus rect and a pointer position are in one space and the suggester never has to
/// ask which.
public final class FocusTracker: @unchecked Sendable {
    private let writer: JSONLWriter
    private let queue: DispatchQueue
    private let clock: RecordingClock
    private let mapper: CursorMapper
    private let tracksFields: Bool

    private var activationObserver: (any NSObjectProtocol)?
    private var windowTimer: Timer?
    private var axObserver: AXObserver?
    private var axApplication: AXUIElement?
    private var observedPID: pid_t = 0

    /// The last thing written, so an unchanged window is not re-recorded twice a second.
    private let lastWindow = OSAllocatedUnfairLock<CGRect?>(initialState: nil)

    /// How often the frontmost window is measured. Twice a second: a window being
    /// dragged is not something to zoom at every step of, and the editor only needs to
    /// know where it came to rest.
    private static let windowPollInterval: TimeInterval = 0.5
    /// Movement smaller than this is a window nudging itself — a shadow redraw, a
    /// one-pixel resize — not a thing that happened.
    private static let movementThreshold: CGFloat = 8

    private static let log = Logger(subsystem: "com.stackrover.cue.studio", category: "focus")

    public init(writer: JSONLWriter,
                queue: DispatchQueue,
                clock: RecordingClock,
                mapper: CursorMapper,
                tracksFields: Bool) {
        self.writer = writer
        self.queue = queue
        self.clock = clock
        self.mapper = mapper
        self.tracksFields = tracksFields
    }

    /// Whether the Accessibility grant that `field` events need is in place.
    ///
    /// Asked without prompting: a recording is the wrong moment to put a system dialog
    /// on screen, so the UI asks for this grant in Settings and this only reports.
    public static var canTrackFields: Bool { AXIsProcessTrusted() }

    public func start() {
        MainActor.assumeIsolated {
            let workspace = NSWorkspace.shared
            activationObserver = workspace.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.applicationDidActivate(app) }
            }

            let timer = Timer(timeInterval: Self.windowPollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollFrontWindow() }
            }
            RunLoop.main.add(timer, forMode: .common)
            windowTimer = timer

            // The state at the start is an event too: a recording that opens on a
            // window already in front should still be able to frame it.
            applicationDidActivate(workspace.frontmostApplication)
        }
    }

    public func stop() {
        MainActor.assumeIsolated {
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            }
            activationObserver = nil
            windowTimer?.invalidate()
            windowTimer = nil
            detachFieldObserver()
        }
        lastWindow.withLock { $0 = nil }
    }

    // MARK: - Writing

    private func record(_ kind: FocusSample.Kind, rect: CGRect, app: String?) {
        // A zero-sized rect is a window that has not laid out yet, or an element the
        // Accessibility API knows about but cannot place. Neither is somewhere to point
        // a camera.
        guard rect.width > 1, rect.height > 1 else { return }
        let mapped = mapper.map(rect)
        let sample = FocusSample(t: clock.elapsed(), kind: kind, rect: mapped, app: app)
        queue.async { [writer] in writer.append(sample) }
    }

    // MARK: - Applications and windows

    @MainActor
    private func applicationDidActivate(_ app: NSRunningApplication?) {
        guard let app else { return }
        // Cue's own recorder bar coming forward is not a moment in the recording.
        if let bundle = app.bundleIdentifier, bundle.hasPrefix("com.stackrover.cue") { return }

        if let rect = Self.frontWindowBounds(of: app.processIdentifier) {
            lastWindow.withLock { $0 = rect }
            record(.application, rect: rect, app: app.bundleIdentifier)
        }
        attachFieldObserver(to: app)
    }

    @MainActor
    private func pollFrontWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let rect = Self.frontWindowBounds(of: app.processIdentifier) else { return }
        if let bundle = app.bundleIdentifier, bundle.hasPrefix("com.stackrover.cue") { return }

        let moved = lastWindow.withLock { last -> Bool in
            guard let last else { return true }
            let delta = max(abs(rect.minX - last.minX), abs(rect.minY - last.minY))
            let resized = max(abs(rect.width - last.width), abs(rect.height - last.height))
            return max(delta, resized) > Self.movementThreshold
        }
        guard moved else { return }
        lastWindow.withLock { $0 = rect }
        record(.window, rect: rect, app: app.bundleIdentifier)
    }

    /// The frontmost normal window of a process, in global screen points.
    ///
    /// Read from the window list rather than through Accessibility so this works with
    /// nothing but the grant a recording already has. The list is front-to-back, so the
    /// first window at layer 0 owned by the process is the one on top; anything at a
    /// higher layer is a panel, a menu or a HUD, which is not what "the window someone
    /// switched to" means.
    static func frontWindowBounds(of pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            return rect
        }
        return nil
    }

    // MARK: - Keyboard focus

    /// Watches one app's keyboard focus, when the grant allows it.
    ///
    /// One app at a time, swapped as the front app changes: an observer per running
    /// application would be dozens of ports open for events about windows nobody is
    /// looking at.
    @MainActor
    private func attachFieldObserver(to app: NSRunningApplication) {
        guard tracksFields, Self.canTrackFields else { return }
        let pid = app.processIdentifier
        guard pid != observedPID else { return }
        detachFieldObserver()

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue().focusChanged(to: element)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let application = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, application, notification as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        axObserver = observer
        axApplication = application
        observedPID = pid

        // Whatever already has focus counts, so tabbing into a field that was focused
        // before the switch is not silently missed.
        if let focused = Self.attribute(of: application, kAXFocusedUIElementAttribute) {
            focusChanged(to: focused as! AXUIElement)
        }
    }

    @MainActor
    private func detachFieldObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        axApplication = nil
        observedPID = 0
    }

    /// Called from the Accessibility run-loop source. Nonisolated because a C callback
    /// carries no isolation with it; everything it touches is either a lock or the
    /// writer's queue.
    private func focusChanged(to element: AXUIElement) {
        guard let role = Self.attribute(of: element, kAXRoleAttribute) as? String,
              Self.textRoles.contains(role),
              let rect = Self.frame(of: element) else { return }
        record(.field, rect: rect, app: nil)
    }

    /// Roles worth framing. Deliberately short: a zoom every time focus lands on a
    /// button would be a camera with a nervous tic, and tab-to-button is how a lot of
    /// people move through a window.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    private static func attribute(of element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// An element's bounds in global screen points.
    ///
    /// Position and size arrive as `AXValue` boxes rather than as numbers, which is why
    /// this is four calls instead of one.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(of: element, kAXPositionAttribute),
              let sizeValue = attribute(of: element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
