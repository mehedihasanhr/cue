import AppKit
import Foundation
import Observation
import os
import RecordKit

/// Takes that were interrupted, and bringing them back.
///
/// The app's rather than the Recordings window's: a recovery outlives the window that
/// started it, and the offer made at launch comes before any window exists. The work is
/// `TakeRecovery` in RecordKit; this is only who asked, how far it has got, and what to say.
///
/// Nothing is recovered unless somebody presses Recover, and nothing is opened afterwards:
/// a recovered take turns into an ordinary row in Recordings and waits there.
@MainActor
@Observable
final class TakeRecoveryCenter {
    static let shared = TakeRecoveryCenter()

    enum Status: Equatable {
        case recovering(Double)
        /// One sentence, for the row.
        case failed(String)
        case nothingToRecover
    }

    private var statuses: [String: Status] = [:]
    /// Moves on every time a take finishes recovering, so a list showing it knows to read
    /// the folder again.
    private(set) var finished = 0

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "recovery")
    /// The takes already offered at a launch, so the question is asked once per take and
    /// not at every launch until it is answered the way the app would like.
    private static let offeredKey = "offeredInterruptedTakes"

    func status(of url: URL) -> Status? { statuses[Self.key(url)] }

    var isRecovering: Bool {
        statuses.values.contains { if case .recovering = $0 { true } else { false } }
    }

    /// Starts recovering a take in the background. A second press while it runs does
    /// nothing.
    func recover(_ url: URL) {
        let key = Self.key(url)
        if case .recovering = statuses[key] { return }
        statuses[key] = .recovering(0)

        let progress = ProgressThrottle { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .recovering = self.statuses[key] else { return }
                self.statuses[key] = .recovering(fraction)
            }
        }
        Task {
            let result: Result<RecoveryOutcome, RecoveryError> = await Task.detached(priority: .userInitiated) {
                do throws(RecoveryError) {
                    return .success(try await TakeRecovery.recover(RecordingPackage(url: url)) { progress.report($0) })
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(.recovered), .success(.alreadyFinished):
                statuses[key] = nil
                finished += 1
            case .success(.nothingRecorded):
                statuses[key] = .nothingToRecover
            case .failure(let error):
                statuses[key] = .failed(error.errorDescription ?? "It couldn\u{2019}t be recovered.")
                Self.log.error("Recovery failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - At launch

    /// Asks once about takes that a previous run of the app left unfinished.
    ///
    /// One alert, and only for takes it has not asked about before: a take the user said
    /// "Not Now" to stays in Recordings with its own Recover button, and is not asked about
    /// again. Not asked at all while a take is starting or running — an alert over a
    /// recording would be in the recording. A take whose manifest was written and whose
    /// marker was not is simply tidied: it finished, so there is nothing to ask.
    func offerAtLaunch(library: URL,
                       isBusy: @escaping @MainActor () -> Bool,
                       live: @escaping @MainActor () -> URL?,
                       showLibrary: @escaping @MainActor () -> Void) async {
        let excluded = live().map { Set([$0]) } ?? []
        let found = await Task.detached(priority: .utility) {
            RecordingLibrary(folder: library).interruptedTakes(excluding: excluded)
        }.value

        for take in found where take.hasFinished { recover(take.url) }

        let offered = Set(UserDefaults.standard.stringArray(forKey: Self.offeredKey) ?? [])
        let unasked = found.filter { !$0.hasFinished && $0.hasFootage && !offered.contains(Self.key($0.url)) }
        guard !unasked.isEmpty, !isBusy(), !StudioAutomation.isQuiet else { return }
        // Only the ones still there, so the list does not grow for ever.
        let present = Set(found.map { Self.key($0.url) })
        UserDefaults.standard.set(Array(offered.intersection(present).union(unasked.map { Self.key($0.url) })),
                                  forKey: Self.offeredKey)

        let alert = NSAlert()
        if unasked.count == 1, let take = unasked.first {
            alert.messageText = "A recording was interrupted"
            alert.informativeText = "Klik Studio stopped before \u{201C}\(take.name)\u{201D} was saved. You can recover what was recorded."
        } else {
            alert.messageText = "\(unasked.count) recordings were interrupted"
            alert.informativeText = "Klik Studio stopped before they were saved. You can recover what was recorded."
        }
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        showLibrary()
        for take in unasked { recover(take.url) }
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}

/// Passes progress on at most once a percent: recovery reports every sample it copies, and
/// a hop to the main actor for each would be the slowest part of it.
nonisolated private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private let forward: @Sendable (Double) -> Void

    init(_ forward: @escaping @Sendable (Double) -> Void) {
        self.forward = forward
    }

    func report(_ fraction: Double) {
        let due = lock.withLock {
            guard fraction - last >= 0.01 || fraction >= 1 else { return false }
            last = fraction
            return true
        }
        if due { forward(fraction) }
    }
}
