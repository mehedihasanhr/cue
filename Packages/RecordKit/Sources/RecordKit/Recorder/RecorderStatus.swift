import Foundation

extension RecordingSession.State {
    /// Seconds of footage in the take so far, pauses left out — what the bar's timer says.
    /// Zero when nothing is being recorded.
    public func recordedSeconds(at now: Date) -> Double {
        switch self {
        case .recording(let started): max(0, now.timeIntervalSince(started))
        case .paused(let started, let pausedAt): max(0, pausedAt.timeIntervalSince(started))
        case .idle, .preparing, .countdown, .finishing, .finished, .failed: 0
        }
    }
}

/// What the menu bar icon shows for each state of the session.
///
/// A symbol and a few characters, because the menu bar is narrow and shared: the elapsed
/// time while recording, the number while counting down, nothing at all while idle.
public struct RecorderStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, starting, countdown, recording, paused, finishing
    }

    public var phase: Phase
    /// SF Symbol name.
    public var symbol: String
    /// Beside the symbol; empty for none.
    public var title: String
    /// For VoiceOver and the tooltip.
    public var description: String

    public init(_ state: RecordingSession.State, at now: Date) {
        switch state {
        case .idle, .finished, .failed:
            self.init(phase: .idle, symbol: "record.circle", title: "", description: "Klik Studio")
        case .preparing:
            self.init(phase: .starting, symbol: "record.circle", title: "", description: "Getting ready to record")
        case .countdown(let remaining):
            self.init(phase: .countdown, symbol: "record.circle",
                      title: "\(remaining)", description: "Recording starts in \(remaining)")
        case .recording:
            let time = Self.clock(state.recordedSeconds(at: now))
            self.init(phase: .recording, symbol: "record.circle.fill",
                      title: time, description: "Recording, \(time)")
        case .paused:
            let time = Self.clock(state.recordedSeconds(at: now))
            self.init(phase: .paused, symbol: "pause.circle.fill",
                      title: time, description: "Paused at \(time)")
        case .finishing:
            self.init(phase: .finishing, symbol: "record.circle", title: "", description: "Finishing the recording")
        }
    }

    public init(phase: Phase, symbol: String, title: String, description: String) {
        self.phase = phase
        self.symbol = symbol
        self.title = title
        self.description = description
    }

    /// "0:42", "12:05", "1:02:10" — minutes and seconds until an hour has gone by. Rounded
    /// the way the bar's timer rounds, so the two never show different seconds.
    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = total / 60 % 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// Throwing a take away to start it again.
public enum TakeRestart {
    /// Takes longer than this are asked about before they are thrown away. Ten seconds is
    /// a false start; anything longer is somebody's work.
    public static let confirmationThreshold: Double = 10

    /// Whether a take this long is asked about before it is thrown away.
    ///
    /// The threshold is the user's to move — somebody who records thirty-second clips all
    /// day reads a question at eleven seconds as nagging, and somebody who has lost a take
    /// to a stray shortcut wants to be asked every time. `nil` is "never ask"; zero is
    /// "always ask", for anything that has recorded at all.
    public static func needsConfirmation(recordedSeconds: Double,
                                         threshold: Double? = confirmationThreshold) -> Bool {
        guard let threshold else { return false }
        return recordedSeconds > max(0, threshold)
    }

    /// Makes sure the package a restart threw away is gone, marker and all, and says
    /// whether it is.
    ///
    /// The session discards the package itself; this is the check afterwards, because a
    /// restart that leaves the old take on disk leaves an "interrupted" recording in the
    /// library that the person already said they did not want. Refuses anything that is not
    /// a recording package, like `RecordingPackage.discard`.
    @discardableResult
    public static func removeLeftovers(of url: URL?) -> Bool {
        guard let url else { return true }
        guard url.pathExtension == RecordingPackage.fileExtension else { return false }
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return true }
        RecordingPackage(url: url).removeMarker()
        try? FileManager.default.removeItem(at: url)
        return !FileManager.default.fileExists(atPath: path)
    }
}
