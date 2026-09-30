import Foundation

/// One export at a time in a process.
///
/// Each export holds a hardware encoder for as long as it runs, and waits on a hardware
/// decoder for every frame. The Mac has only so many of either, and several exports at once
/// can each end up holding what the others are waiting for: every one of them stops inside
/// `copyNextSampleBuffer`, and nothing moves until one gives up. The test suites, which
/// export in parallel, did exactly that — measured, every stuck read came back the moment
/// another export unwound. The editor already queues its exports one behind another
/// (`ExportJobs`); this makes it a guarantee of the exporter rather than a habit of one
/// caller, so no second caller can walk into the same wait.
///
/// Fair: exports run in the order they asked.
actor ExportGate {
    static let shared = ExportGate()

    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `work` once no other export is running.
    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await enter()
        defer { leave() }
        return try await work()
    }

    private func enter() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the gate straight to the next in line, so it is never briefly open for a
    /// newcomer to slip past someone who has been waiting.
    private func leave() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
