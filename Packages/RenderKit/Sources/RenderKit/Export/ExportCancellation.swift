import Foundation

/// A cancel that can be set from anywhere and read from anywhere.
///
/// `VideoExporter.cancel()` used to set a `var` on the actor, which only the actor's own
/// frame loop could see — so the GIF path, which runs inside a non-isolated struct, never
/// heard about it and only stopped because the surrounding `Task` happened to be
/// cancelled too. That is a cancel that works by coincidence, and it stops working the
/// moment anything calls `cancel()` without also cancelling the task.
///
/// A lock rather than `Synchronization.Mutex` because this ships to macOS 14, and rather
/// than an actor because the frame loops read it thousands of times and must not have to
/// `await` to ask.
public final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Set either by us or by the task tree above us. Structured cancellation counts:
    /// a window that goes away taking its task with it means the same thing as a Cancel
    /// button, and the frame loops should not have to check two things to notice.
    public var shouldStop: Bool { isSet || Task.isCancelled }
}
