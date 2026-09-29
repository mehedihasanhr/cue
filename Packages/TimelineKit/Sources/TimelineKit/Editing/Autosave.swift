import Foundation

/// When an edit is written back without being asked — and nothing about how.
///
/// Autosave is two jobs that fail in different ways: deciding *when* to write, and
/// writing. The writing is `EditorDocument`'s and needs a disk; this is the deciding,
/// and it needs only a clock, which is passed in as a number so a test can be the clock.
/// The rule is quiet, not tempo: a write is due a fixed moment after the *last* edit, so
/// a burst of dragging costs one write at its end rather than one per pixel, and a person
/// who never pauses is never interrupted.
public struct AutosaveTiming: Equatable, Sendable {
    /// How long the edit has to be left alone before it is written, in seconds.
    public var quiet: TimeInterval

    /// When the last edit happened, or `nil` while nothing is waiting to be written.
    public private(set) var lastEdit: TimeInterval?

    /// Two seconds: long enough that a drag and the correction after it are one write,
    /// short enough that a crash costs a moment's work rather than an afternoon's.
    public static let defaultQuiet: TimeInterval = 2

    public init(quiet: TimeInterval = AutosaveTiming.defaultQuiet) {
        self.quiet = max(0, quiet)
    }

    /// An edit happened at `now`. Any write that was due is put off by the quiet period
    /// again, measured from this edit.
    public mutating func edited(at now: TimeInterval) {
        lastEdit = now
    }

    /// The same, for a write that had to be put off — the person was mid-gesture — so it
    /// is tried again after another quiet period rather than on every tick until they stop.
    public mutating func postponed(at now: TimeInterval) {
        edited(at: now)
    }

    /// When the write is due, or `nil` when nothing is waiting.
    public var due: TimeInterval? {
        lastEdit.map { $0 + quiet }
    }

    /// Whether the write should happen now.
    public func isDue(at now: TimeInterval) -> Bool {
        guard let due else { return false }
        return now >= due
    }

    /// How long to wait from `now` before asking again, or `nil` when nothing is waiting.
    /// Never negative: a write that is overdue is due now.
    public func wait(from now: TimeInterval) -> TimeInterval? {
        due.map { max(0, $0 - now) }
    }

    /// The edit has been written, or turned out not to need writing. Nothing is waiting.
    public mutating func settled() {
        lastEdit = nil
    }

    public var isWaiting: Bool { lastEdit != nil }
}
