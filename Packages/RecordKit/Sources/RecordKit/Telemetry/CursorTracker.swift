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
    private let queue: DispatchQueue
    private let cursorWriter: JSONLWriter
    private let inputWriter: JSONLWriter?
    private let clock: RecordingClock
    private let mapper: CursorMapper
    private let sampleRate: Int

    private var positionTimer: DispatchSourceTimer?
    private var shapeTimer: Timer?
    private var clickMonitor: Any?
    private let shape = OSAllocatedUnfairLock(initialState: CursorShape.arrow)

    public init(cursorWriter: JSONLWriter,
                inputWriter: JSONLWriter?,
                queue: DispatchQueue,
                clock: RecordingClock,
                mapper: CursorMapper,
                sampleRate: Int) {
        self.cursorWriter = cursorWriter
        self.inputWriter = inputWriter
        self.queue = queue
        self.clock = clock
        self.mapper = mapper
        self.sampleRate = max(1, sampleRate)
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

    @MainActor
    private func stopMainThreadWatchers() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
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
