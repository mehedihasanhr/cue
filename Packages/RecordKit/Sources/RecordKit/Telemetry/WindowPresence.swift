import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import os

/// Whether the window being recorded is the one in front.
///
/// A window recording is a recording of what somebody does in that window. While they are
/// in another app, or another window, its clicks are not clicks in the recording — they
/// landed on something that is not in the picture — and the window itself, sitting still
/// behind whatever they went to, is not what they were doing. This watches which window is
/// in front, so the clicks and keys made elsewhere can be left out as they happen, and
/// writes down when the window was in front, so the editor can show black for the rest.
///
/// "In front" is the window's app being the active one, with the window — or something
/// of the app's laid over it, such as a sheet or the tab strip a full-screen browser
/// stacks above its page — topmost among that app's windows.
public final class WindowPresence: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.stackrover.klik.recordkit", category: "presence")

    private let window: CGWindowID
    private let owner: pid_t?
    private let writer: JSONLWriter?
    private let queue: DispatchQueue
    private let clock: RecordingClock
    /// The answer last written down, `nil` until the first one.
    private let state = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    private var timer: Timer?
    private var observer: (any NSObjectProtocol)?

    public init(window: CGWindowID, writer: JSONLWriter?, queue: DispatchQueue, clock: RecordingClock) {
        self.window = window
        self.writer = writer
        self.queue = queue
        self.clock = clock
        let listing = CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]]
        owner = (listing?.first?[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.int32Value) }
    }

    /// Whether the window is in front now. In front until the first look says otherwise:
    /// the take began with somebody choosing this window, so that is where they were.
    public var isInFront: Bool { state.withLock { $0 } ?? true }

    @MainActor
    public func start() {
        check()
        // On every switch of app, at once, and a few times a second as well, for a switch
        // between two windows of the same app, which the workspace does not announce.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @MainActor
    public func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    @MainActor
    private func check() {
        let front = Self.isInFront(window, owner: owner)
        let changed = state.withLock { last -> Bool in
            defer { last = front }
            return last != front
        }
        guard changed else { return }
        let t = max(0, clock.elapsed(at: RecordingClock.now))
        Self.log.info("Recorded window \(front ? "in front" : "behind", privacy: .public) at \(t, privacy: .public) s")
        guard let writer else { return }
        let sample = PresenceSample(t: t, front: front)
        queue.async { writer.append(sample) }
    }

    /// The window's app active, and no other window of the app's — one the size of a
    /// window rather than a strip or a popup — lying over it.
    @MainActor
    static func isInFront(_ window: CGWindowID, owner: pid_t?) -> Bool {
        guard let owner else { return true }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == owner else { return false }
        guard let listing = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return true }
        let windows: [(id: CGWindowID, bounds: CGRect)] = listing.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == owner,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = (info[kCGWindowBounds as String] as? [String: Any])
                      .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return nil }
            return (id, bounds)
        }
        return frontmost(window, among: windows)
    }

    /// The rule, on a listing already read, front to back.
    ///
    /// The app's windows above the recorded one are mostly not other windows at all. A
    /// full-screen browser keeps a strip for the menu bar, one for its toolbar and one per
    /// open popup above its page, each its own window; taking the topmost of the app's
    /// windows as "the one in front" found one of those every time, and a whole take was
    /// shown black. So: anything not over the window is passed by, and so is anything over
    /// it but much smaller — a strip, a popup, a sheet — and the window is in front when it
    /// is reached before something of a window's size covers it. Not reached at all, it is
    /// not on screen: on another Space, behind whatever the person went to.
    static func frontmost(_ window: CGWindowID, among windows: [(id: CGWindowID, bounds: CGRect)]) -> Bool {
        guard let mine = windows.first(where: { $0.id == window })?.bounds else { return false }
        let area = mine.width * mine.height
        for other in windows {
            if other.id == window { return true }
            let overlap = mine.intersection(other.bounds)
            guard !overlap.isNull, overlap.width * overlap.height > 0 else { continue }
            if other.bounds.width * other.bounds.height < area * 0.6 { continue }
            return false
        }
        return false
    }
}
