import AppKit
import Foundation
import Observation
import os
import RenderKit

/// One export, running somewhere other than in the window that asked for it.
///
/// Everything it needs is copied in before it starts: the exporter already holds the
/// timeline, the builder and the URLs as values, so a job has no reference to the editor
/// at all. That is what makes an export survivable — the window can close, the document
/// can be let go of, and the file still lands.
@MainActor
@Observable
final class ExportJob: Identifiable {
    enum Phase: Equatable {
        /// Waiting for the one in front of it. Exports are run one at a time on purpose:
        /// two of them share one GPU and finish later than they would in turn.
        case queued
        case running(ExportProgress)
        case finished(URL)
        case failed(String)
        case cancelled

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var isSettled: Bool {
            switch self {
            case .queued, .running: false
            case .finished, .failed, .cancelled: true
            }
        }
    }

    let id = UUID()
    /// The recording's name, because the window that could have told you is often gone.
    let name: String
    let destination: URL
    let settings: ExportSettings
    /// What we said it would be, kept so the file that lands can be held against it.
    let estimate: ExportEstimate

    private(set) var phase: Phase = .queued

    private let exporter: VideoExporter
    private var task: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "export")

    init(name: String,
         destination: URL,
         settings: ExportSettings,
         estimate: ExportEstimate,
         exporter: VideoExporter) {
        self.name = name
        self.destination = destination
        self.settings = settings
        self.estimate = estimate
        self.exporter = exporter
    }

    /// What the file will be called, for a progress line with no room for a path.
    var fileName: String { destination.lastPathComponent }

    // MARK: - Running

    /// Starts the work. `whenDone` is how the queue learns it can start the next one.
    func run(whenDone: @escaping () -> Void) {
        guard phase == .queued else { return }
        phase = .running(ExportProgress(framesWritten: 0, totalFrames: estimate.frameCount, elapsed: 0))

        task = Task {
            do {
                try await exporter.export(to: destination) { progress in
                    Task { @MainActor [weak self] in
                        // A report can be in flight when a cancel lands. Putting the job
                        // back into a state it has already left would leave a finished
                        // export showing a progress bar forever.
                        guard let self, self.phase.isRunning else { return }
                        self.phase = .running(progress)
                    }
                }
                phase = .finished(destination)
                Self.log.notice("Wrote \(self.destination.lastPathComponent, privacy: .public)")
            } catch let error as ExportError {
                phase = error == .cancelled ? .cancelled : .failed(error.localizedDescription)
            } catch {
                phase = .failed(error.localizedDescription)
            }
            whenDone()
        }
    }

    /// Stops it, whether it has started or not.
    ///
    /// The flag is set before the task is cancelled because the exporter reads the flag at
    /// every frame boundary and unwinds cleanly from there — task cancellation alone would
    /// interrupt it mid-write and leave the writer to tidy up on its own.
    func cancel() {
        guard !phase.isSettled else { return }
        exporter.cancel()
        task?.cancel()
        phase = .cancelled
    }

    // MARK: - Afterwards

    /// Whether the file is there to be acted on.
    var finishedURL: URL? {
        guard case .finished(let url) = phase else { return nil }
        return url
    }

    func reveal() {
        guard let url = finishedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The file itself on the pasteboard, not its path.
    ///
    /// Written as a file URL, which is what a Finder window, a Mail message and every
    /// chat app's compose field all read as "the file" — a string of the path would paste
    /// as text into most of them.
    func copyFile() {
        guard let url = finishedURL else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
    }

    func open() {
        guard let url = finishedURL else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Every export the app has going, and the ones that have just landed.
///
/// Owned by `EditorWindows` rather than by a window or a view, which is the whole point:
/// an export of a ten-minute take is minutes of work, and until now it lived in an
/// `ExportModel` held in a view's `@State` behind a modal sheet. Closing the window while
/// one ran left a `Task` writing into a file nobody could see the progress of or cancel,
/// and the sheet meant the answer to "what can I do while this runs" was "nothing".
///
/// Here, a job outlives its window, the editor stays usable, and the queue is a fact the
/// app can be asked about — including at quit time.
@MainActor
@Observable
final class ExportJobs {
    private(set) var jobs: [ExportJob] = []

    /// Told whenever one lands. The window layer listens, because a file that finished
    /// after its editor was closed has nowhere on screen left to announce itself — and an
    /// export nobody can find is only half an export.
    @ObservationIgnored var onFinish: ((ExportJob) -> Void)?

    /// Whether anything is still to be written. What Quit has to ask.
    var isBusy: Bool { jobs.contains { !$0.phase.isSettled } }

    var running: ExportJob? { jobs.first { $0.phase.isRunning } }

    /// Everything not yet dismissed, newest first — the pill in the toolbar shows the
    /// first of these, and that should be whatever just happened.
    var recent: [ExportJob] { jobs.reversed() }

    func add(_ job: ExportJob) {
        jobs.append(job)
        pump()
    }

    /// Takes a settled job off the list. A running one is cancelled first, so dismissing
    /// a progress row cannot leave an orphan writing to disk.
    func dismiss(_ job: ExportJob) {
        job.cancel()
        jobs.removeAll { $0 === job }
    }

    func dismissSettled() {
        jobs.removeAll { $0.phase.isSettled }
    }

    func cancelAll() {
        for job in jobs { job.cancel() }
    }

    /// Starts the next one when nothing else is running.
    ///
    /// Called both on enqueue and from each job's completion, so the two routes into
    /// "what runs next" are one piece of arithmetic rather than two that can disagree.
    private func pump() {
        guard running == nil else { return }
        guard let next = jobs.first(where: { $0.phase == .queued }) else { return }
        next.run { [weak self] in
            if next.finishedURL != nil { self?.onFinish?(next) }
            self?.pump()
        }
    }
}
