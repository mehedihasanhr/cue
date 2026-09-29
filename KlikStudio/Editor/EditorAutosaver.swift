import Foundation
import Observation
import os
import TimelineKit

/// Writes the edit back without being asked, and says whether it is written.
///
/// The document decides what is dirty and how a save is written; `AutosaveTiming`
/// decides when a save is due; this joins the two to a clock and a disk. It watches the
/// document for changes, waits for a couple of seconds of quiet, and writes — never when
/// nothing has changed, never in the middle of a gesture, and never two writes at once.
///
/// It is also the one place the truth about saving lives, for the toolbar and for the
/// window that is closing: written, being written, or not written and why. A failure
/// stays on show until a later write succeeds, because an autosave that fails quietly is
/// worse than no autosave at all — the person believes their work is on disk.
@MainActor
@Observable
final class EditorAutosaver {
    enum State: Equatable {
        /// Everything is on disk.
        case saved
        /// Something has changed since the last write.
        case edited
        /// A write is in flight.
        case saving
        /// The last write failed, and this is why. Stays until a write succeeds.
        case failed(String)
    }

    private let document: EditorDocument
    private let settings: StudioSettings?
    private var timing = AutosaveTiming()

    /// The wait for the quiet period, if one is running.
    private var pending: Task<Void, Never>?
    /// The write in flight. Every write waits for the one before it, so two can never
    /// race for the file — the later one would lose to the earlier one's rename.
    private var writing: Task<Bool, Never>?
    private var lastFailure: String?

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "autosave")

    init(document: EditorDocument, settings: StudioSettings?) {
        self.document = document
        self.settings = settings
        watch()
    }

    /// Whether edits are written on their own. A preference, so it can be turned off by
    /// somebody who wants to be asked.
    var isEnabled: Bool { settings?.savesAutomatically ?? false }

    var state: State {
        if writing != nil { return .saving }
        if let lastFailure { return .failed(lastFailure) }
        return document.isDirty ? .edited : .saved
    }

    // MARK: - Watching

    /// Told of every change to the edit, and of every gesture ending.
    ///
    /// Observation rather than a call from each command: the edit changes by a command, a
    /// slider drag, an undo, a redo and a paste, and a hook in every one of those is one
    /// that the next one forgets. The registration is one-shot, so it is renewed after
    /// each change — on the next turn of the run loop, because the change is announced
    /// before the new value is in place.
    private func watch() {
        withObservationTracking {
            _ = document.timeline
            _ = document.isInteracting
            _ = settings?.savesAutomatically
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.changed()
                self.watch()
            }
        }
    }

    private func changed() {
        guard isEnabled, document.isDirty else {
            timing.settled()
            pending?.cancel()
            pending = nil
            return
        }
        timing.edited(at: now)
        schedule()
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Waits for the quiet period, then writes — or, if the person is mid-gesture when it
    /// falls due, waits another one rather than asking on every tick.
    private func schedule() {
        pending?.cancel()
        guard let wait = timing.wait(from: now) else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            guard self.isEnabled, self.document.isDirty else {
                self.timing.settled()
                return
            }
            if self.document.isInteracting {
                self.timing.postponed(at: self.now)
                self.schedule()
                return
            }
            self.timing.settled()
            _ = await self.write()
        }
    }

    // MARK: - Writing

    /// Writes now, whatever the timing says, and waits for it. `true` when the document
    /// is clean afterwards — which is also the answer when there was nothing to write.
    ///
    /// For the window closing, the app quitting, and ⌘S. A write already in flight is
    /// waited for rather than joined: what matters is that the disk ends up holding the
    /// edit as it stands, and the loop below checks that after every write it waits on.
    func flush() async -> Bool {
        pending?.cancel()
        pending = nil
        timing.settled()
        return await write()
    }

    /// One write at a time, and only when there is something to write.
    private func write() async -> Bool {
        while let inflight = writing {
            _ = await inflight.value
        }
        guard document.isDirty else { return true }

        let task = Task { [document] () -> Bool in
            do {
                try await document.saveInBackground().value
                return true
            } catch {
                Self.log.error("Couldn't save: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        writing = task
        let saved = await task.value
        if writing == task { writing = nil }
        if saved {
            lastFailure = nil
        } else {
            lastFailure = "The edits couldn't be saved into the recording. Check that the recording is on a disk you can write to, then press Save."
        }
        return saved && !document.isDirty
    }

    /// The last write's failure, for a control that wants to show it — `nil` when the
    /// last write succeeded.
    var failure: String? { lastFailure }

    /// Stops waiting. For a window on its way out, which writes on its own account.
    func stop() {
        pending?.cancel()
        pending = nil
    }
}
