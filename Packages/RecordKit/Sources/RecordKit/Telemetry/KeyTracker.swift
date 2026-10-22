import AppKit
import CoreMedia
import Foundation
import os

/// Whether the keys were watched during a take, for the manifest.
///
/// The manifest has to tell "nobody pressed a shortcut" apart from "shortcuts were not
/// being recorded", because the editor says something different for each: the first is
/// an empty lane, the second is a sentence about a setting. `nil` in the manifest is the
/// third answer — it was not asked for, which is also every recording made before it
/// could be.
///
/// A struct with a raw value rather than an enum, so a value a newer build writes reads
/// as a name this one does not know instead of as a manifest that will not open.
public struct KeyCapture: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    /// Keys were watched for the whole take.
    public static let recorded = KeyCapture(rawValue: "recorded")
    /// Keys were asked for, and macOS had not granted Accessibility, so none were
    /// watched. The setting is on and the data is absent, which is worth saying out loud.
    public static let notPermitted = KeyCapture(rawValue: "notPermitted")
}

/// Records which shortcuts were pressed, as data beside the video.
///
/// The keyboard half of `CursorTracker`, on its own because it is the one part of the
/// telemetry that needs the Accessibility grant, and the one part with a privacy rule
/// attached: `KeyRecorder` says what may be written, and nothing here reads an event's
/// text. See `KeyEvent` for the four things that are read.
///
/// The grant is *checked*, never asked for. A recording is the wrong moment for a system
/// dialog, and this package has no business putting one up: the app asks in Settings.
/// Without the grant a global key monitor is installed happily and delivers nothing at
/// all — which would look like a person who never typed rather than a permission that
/// was never given — so this refuses to install one and says so in `capture`.
///
/// Everything the machine supplies comes through `Environment`, so a test can feed a
/// press and read the sample without a keyboard, a grant or a person at the Mac.
public final class KeyTracker: @unchecked Sendable {
    /// Where presses come from, and what the machine allows.
    public struct Environment: Sendable {
        /// Whether macOS trusts this process for Accessibility, asked without prompting.
        public var isTrusted: @Sendable () -> Bool
        /// Starts watching, handing each press to the closure. Returns a token to stop
        /// with, or `nil` when watching is not possible.
        public var watch: @MainActor @Sendable (_ handler: @escaping @MainActor @Sendable (KeyEvent) -> Void) -> AnyObject?
        public var unwatch: @MainActor @Sendable (AnyObject) -> Void
        /// What the person's layout prints on a key.
        public var label: @MainActor @Sendable (UInt16) -> String?

        public init(isTrusted: @escaping @Sendable () -> Bool,
                    watch: @escaping @MainActor @Sendable (_ handler: @escaping @MainActor @Sendable (KeyEvent) -> Void) -> AnyObject?,
                    unwatch: @escaping @MainActor @Sendable (AnyObject) -> Void,
                    label: @escaping @MainActor @Sendable (UInt16) -> String?) {
            self.isTrusted = isTrusted
            self.watch = watch
            self.unwatch = unwatch
            self.label = label
        }

        /// The real Mac: the Accessibility grant, a global key monitor, the current
        /// layout.
        public static let system = Environment(
            isTrusted: { AXIsProcessTrusted() },
            watch: { handler in
                // A global monitor sees keys sent to *other* apps, which is what a
                // recording is of. The one field read off the event is done inside
                // `KeyEvent.init`, and it is not `characters`.
                NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
                    handler(KeyEvent(event))
                } as AnyObject?
            },
            unwatch: { token in NSEvent.removeMonitor(token) },
            label: { keyCode in KeyboardLayout.character(forKeyCode: keyCode) })
    }

    private static let log = Logger(subsystem: "com.stackrover.cue.recordkit", category: "keys")

    private let writer: JSONLWriter
    private let queue: DispatchQueue
    private let clock: RecordingClock
    /// The same nudge every click gets — see `CursorTracker.latency` — so a ⌘-click and
    /// the click it came with are stamped alike.
    private let latency: CMTime
    private let environment: Environment
    private var monitor: AnyObject?
    private let watched = OSAllocatedUnfairLock(initialState: false)
    /// For a window recording: a key pressed while another window is in front was typed
    /// into that window, not the one in the picture.
    private let presence: WindowPresence?

    public init(writer: JSONLWriter,
                queue: DispatchQueue,
                clock: RecordingClock,
                latency: Double = 0,
                environment: Environment = .system,
                presence: WindowPresence? = nil) {
        self.presence = presence
        self.writer = writer
        self.queue = queue
        self.clock = clock
        self.latency = CMTime(seconds: max(0, min(latency, 0.05)), preferredTimescale: 1_000_000_000)
        self.environment = environment
    }

    /// What the manifest should say: recorded if keys were ever watched, not permitted
    /// otherwise. Read after `stop()`.
    public var capture: KeyCapture {
        watched.withLock { $0 } ? .recorded : .notPermitted
    }

    /// Starts watching, if the grant allows. Called again after a pause.
    @MainActor
    @discardableResult
    public func start() -> KeyCapture {
        guard monitor == nil else { return capture }
        guard environment.isTrusted() else {
            Self.log.notice("Keyboard shortcuts were asked for, but Accessibility is not granted — recording without them")
            return capture
        }
        monitor = environment.watch { [weak self] event in
            self?.record(event)
        }
        if monitor != nil { watched.withLock { $0 = true } }
        return capture
    }

    @MainActor
    public func stop() {
        if let monitor { environment.unwatch(monitor) }
        monitor = nil
    }

    /// One press, stamped and written — or dropped.
    ///
    /// The event's own time, converted the way a click's is: the callback runs some
    /// time after the press, on a busy main thread. A press with no place in the
    /// recording — before the first frame, or inside a hold — is dropped rather than
    /// stamped at the nearest moment that is in it.
    @MainActor
    func record(_ event: KeyEvent, now: CMTime = RecordingClock.now) {
        if let presence, !presence.isInFront { return }
        let stamped = CursorTracker.hostTime(forEventTimestamp: event.timestamp, now: now) + latency
        guard let t = clock.moment(forHost: stamped) else { return }
        // The layout's raw character goes through the naming rule — named keys by their
        // names, a legend capitalised, the US name when the layout has none.
        let sample = KeyRecorder.sample(for: event, at: t) { keyCode in
            KeyLabels.label(forKeyCode: keyCode, layout: environment.label)
        }
        guard let sample else { return }
        queue.async { [writer] in writer.append(sample) }
    }
}

extension RecordingClock {
    /// Seconds since the start for a moment that is in the recording, or `nil` for one
    /// that is not: before the clock started, or inside a hold.
    ///
    /// `elapsed(at:)` answers every moment with a number, which is right for the
    /// pointer — a sample that races the first frame belongs at the start — and wrong
    /// for a key press, which either happened in the take or did not.
    public func moment(forHost time: CMTime) -> Double? {
        guard let origin = startTime, time >= origin,
              recordingTime(forHost: time) != nil else { return nil }
        return elapsed(at: time)
    }
}
