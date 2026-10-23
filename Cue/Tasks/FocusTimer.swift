import AppKit
import Foundation

/// One focus session at a time on a task: a countdown the island shows in its
/// header (and as a status when it starts and ends), with a sound at the end.
@Observable
@MainActor
final class FocusTimer {
    static let lengths = [15, 25, 45, 60]

    private(set) var task: TaskItem?
    private(set) var endsAt: Date?
    private(set) var startedAt: Date?
    /// Ticks every second while running so views redraw.
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activity: (any NSObjectProtocol)?

    /// Where to say what happened (the island, or a HUD).
    var announce: (IslandStatus) -> Void = { _ in }

    var isRunning: Bool { endsAt != nil }

    var remaining: TimeInterval { max(0, (endsAt ?? now).timeIntervalSince(now)) }

    /// 0…1 of the session that has gone by.
    var progress: Double {
        guard let startedAt, let endsAt else { return 0 }
        let total = endsAt.timeIntervalSince(startedAt)
        return total > 0 ? min(1, max(0, now.timeIntervalSince(startedAt) / total)) : 0
    }

    /// "24:12".
    var clock: String {
        let seconds = Int(remaining.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func start(_ task: TaskItem, minutes: Int) {
        stop(quietly: true)
        self.task = task
        startedAt = Date()
        endsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        now = Date()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Focus session")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        announce(IslandStatus(symbol: "timer", title: "Focus · \(minutes) min", subtitle: task.title, duration: .seconds(2.5)))
    }

    /// Ends the session; says so unless `quietly`.
    func stop(quietly: Bool = false) {
        guard let task, let startedAt else { return }
        let minutes = Int(Date().timeIntervalSince(startedAt) / 60)
        clear()
        if !quietly {
            announce(IslandStatus(symbol: "stop.circle", title: "Focus stopped", subtitle: minutes > 0 ? "\(minutes) min on \(task.title)" : task.title, duration: .seconds(2)))
        }
    }

    private func tick() {
        now = Date()
        guard let endsAt, let task, now >= endsAt else { return }
        let minutes = Int(endsAt.timeIntervalSince(startedAt ?? endsAt) / 60)
        clear()
        NSSound(named: "Glass")?.play()
        announce(IslandStatus(symbol: "checkmark.seal.fill", title: "Focus done · \(minutes) min", subtitle: task.title, duration: .seconds(6)))
    }

    private func clear() {
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        task = nil
        endsAt = nil
        startedAt = nil
    }
}
