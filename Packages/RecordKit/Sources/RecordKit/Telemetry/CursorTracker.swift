import AppKit
import CoreGraphics
import Foundation
import os

/// Where a point on screen lands inside what is being recorded.
///
/// Global screen coordinates are not what the editor wants: it draws on top of a frame
/// whose origin is the top-left of the recorded area. Translating once, here, means
/// every sample on disk is already in the frame's space.
public struct CursorMapper: Sendable {
    /// The recorded area's origin in global screen points, top-left.
    public var origin: CGPoint

    public init(origin: CGPoint) { self.origin = origin }

    public func map(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }
}

/// Records where the pointer went and what it did, as data beside the video.
///
/// This is the file that makes everything afterwards possible: auto-zoom follows it,
/// the rendered cursor is drawn from it, click bounce comes from the button events. None
/// of that can be recovered from pixels, which is why the video is recorded without a
/// cursor in it at all.
///
/// Positions are sampled with `CGEvent`, which is safe to read from any thread, on the
/// same queue the encoder runs on. The *shape* is AppKit's and main-thread-only, so it
/// is polled more slowly on the main actor and read back under a lock — a pointer that
/// changes shape 20 times a second is already an unusual second.
public final class CursorTracker: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.stackrover.klik.recordkit", category: "cursor")

    private let queue: DispatchQueue
    private let cursorWriter: JSONLWriter
    private let inputWriter: JSONLWriter?
    private let clock: RecordingClock
    private let mapper: CursorMapper
    private let sampleRate: Int

    private let capturesKeystrokes: Bool

    private var positionTimer: DispatchSourceTimer?
    private var shapeTimer: Timer?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private let shape = OSAllocatedUnfairLock(initialState: CursorShape.arrow)

    /// Whether the keystroke *rhythm* was actually recorded.
    ///
    /// Read after `start()`. False when it was not asked for, and false when it was but
    /// macOS has not granted Accessibility — the two are different to the user and the
    /// second is worth saying out loud, because the setting is on and the data is absent.
    public private(set) var isRecordingKeystrokes = false

    public init(cursorWriter: JSONLWriter,
                inputWriter: JSONLWriter?,
                queue: DispatchQueue,
                clock: RecordingClock,
                mapper: CursorMapper,
                sampleRate: Int,
                capturesKeystrokes: Bool = false) {
        self.cursorWriter = cursorWriter
        self.inputWriter = inputWriter
        self.queue = queue
        self.clock = clock
        self.mapper = mapper
        self.sampleRate = max(1, sampleRate)
        self.capturesKeystrokes = capturesKeystrokes
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(sampleRate)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sample() }
        positionTimer = timer
        timer.resume()

        MainActor.assumeIsolated { startMainThreadWatchers() }
    }

    public func stop() {
        positionTimer?.cancel()
        positionTimer = nil
        MainActor.assumeIsolated { stopMainThreadWatchers() }
    }

    /// One position sample. Runs on the capture queue.
    private func sample() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let point = mapper.map(location)
        cursorWriter.append(CursorSample(t: clock.elapsed(),
                                         x: Double(point.x),
                                         y: Double(point.y),
                                         shape: shape.withLock { $0 }))
    }

    // MARK: - Main thread

    @MainActor
    private func startMainThreadWatchers() {
        // Mouse events, unlike key events, need no Accessibility grant.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp,
                                                                    .rightMouseDown, .rightMouseUp,
                                                                    .otherMouseDown, .otherMouseUp,
                                                                    .scrollWheel]) { [weak self] event in
            self?.record(event)
        }

        startKeyboardWatcher()

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // `currentSystem` is nil when the pointer is over another app's window
                // that hides it; the last known shape is a better answer than `.arrow`.
                guard let self, let cursor = NSCursor.currentSystem else { return }
                let current = CursorShape(cursor)
                self.shape.withLock { $0 = current }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shapeTimer = timer
    }

    /// Watches the *rhythm* of typing, and nothing else.
    ///
    /// A global key monitor is the one thing here that needs Accessibility, which is why
    /// it is opt-in and why this asks rather than assumes: without the grant the monitor
    /// is installed happily and then delivers nothing at all, which would look like a
    /// user who never typed rather than a permission that was never given.
    ///
    /// Nothing is read off the event but its time and its modifier flags. `characters`
    /// is never touched — not stored, not inspected, not logged. The samples it writes
    /// cannot reconstruct what was typed, by construction rather than by filtering.
    @MainActor
    private func startKeyboardWatcher() {
        guard capturesKeystrokes else { return }
        guard AXIsProcessTrusted() else {
            Self.log.notice("Keystroke timing was asked for, but Accessibility is not granted — recording without it")
            return
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.record(event)
        }
        isRecordingKeystrokes = keyMonitor != nil
    }

    @MainActor
    private func stopMainThreadWatchers() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        isRecordingKeystrokes = false
        shapeTimer?.invalidate()
        shapeTimer = nil
    }

    @MainActor
    private func record(_ event: NSEvent) {
        guard let inputWriter else { return }
        let t = clock.elapsed()
        let location = mapper.map(CGEvent(source: nil)?.location ?? .zero)

        let sample: InputSample? = switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            .mouseDown(t: t, button: event.buttonNumber, x: Double(location.x), y: Double(location.y))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            .mouseUp(t: t, button: event.buttonNumber, x: Double(location.x), y: Double(location.y))
        case .scrollWheel:
            .scroll(t: t, dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
        case .keyDown:
            // The time and the modifiers. Deliberately not `event.characters`, and not
            // `keyCode` either — a key code is the letter by another name.
            .key(t: t, modifiers: Int(event.modifierFlags.rawValue))
        default:
            nil
        }
        guard let sample else { return }
        queue.async { inputWriter.append(sample) }
    }
}

extension CursorShape {
    /// Names the system cursor. Compared by identity because `NSCursor` has no other
    /// way to say which one it is, and an unrecognised cursor is recorded as `other`
    /// rather than mislabelled as an arrow.
    @MainActor
    init(_ cursor: NSCursor) {
        switch cursor {
        case NSCursor.arrow: self = .arrow
        case NSCursor.iBeam, NSCursor.iBeamCursorForVerticalLayout: self = .iBeam
        case NSCursor.pointingHand: self = .pointingHand
        case NSCursor.openHand: self = .openHand
        case NSCursor.closedHand: self = .closedHand
        case NSCursor.crosshair: self = .crosshair
        case NSCursor.resizeLeftRight, NSCursor.resizeLeft, NSCursor.resizeRight: self = .resizeLeftRight
        case NSCursor.resizeUpDown, NSCursor.resizeUp, NSCursor.resizeDown: self = .resizeUpDown
        case NSCursor.disappearingItem: self = .disappearingItem
        case NSCursor.operationNotAllowed: self = .operationNotAllowed
        case NSCursor.dragCopy: self = .dragCopy
        case NSCursor.dragLink: self = .dragLink
        case NSCursor.contextualMenu: self = .contextualMenu
        default: self = .other
        }
    }
}
