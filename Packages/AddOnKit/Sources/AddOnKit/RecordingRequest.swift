import CoreGraphics
import Foundation

/// What Klik asks the recording add-on to do.
///
/// A value type rather than a pile of arguments because it crosses a process boundary:
/// it travels as JSON today and becomes the XPC request unchanged once the add-on vends
/// a Mach service. Every field has a default, so a host that predates a field still
/// produces a request a newer add-on can read.
public struct RecordingRequest: Sendable, Codable, Equatable {
    public enum Target: Sendable, Codable, Equatable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
        case area(display: CGDirectDisplayID, rect: CGRect)
        /// Let the add-on ask, which is what the menu bar item does.
        case ask
    }

    public var target: Target
    public var microphone: Bool
    public var systemAudio: Bool
    public var webcam: Bool
    public var countdownSeconds: Int
    /// Open the editor when the recording stops, rather than leaving the file for later.
    /// Defaults to false, so an add-on that predates the field behaves as it did.
    public var opensEditorWhenFinished: Bool
    /// Where the finished project should land. `nil` means the add-on's own library.
    public var destination: URL?
    /// Correlates the host's log with the add-on's for one recording. Logged by both
    /// sides at `.notice`, so a bug report can be filtered out of a log archive without
    /// a reproduction.
    public var correlationID: UUID

    public init(target: Target = .ask,
                microphone: Bool = false,
                systemAudio: Bool = true,
                webcam: Bool = false,
                countdownSeconds: Int = 3,
                opensEditorWhenFinished: Bool = false,
                destination: URL? = nil,
                correlationID: UUID = UUID()) {
        self.target = target
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.webcam = webcam
        self.countdownSeconds = countdownSeconds
        self.opensEditorWhenFinished = opensEditorWhenFinished
        self.destination = destination
        self.correlationID = correlationID
    }
}

/// What the add-on did with a request.
public struct RecordingResult: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        case finished
        case cancelled
        case failed
    }

    public var correlationID: UUID
    public var outcome: Outcome
    /// The `.klikrec` package, when there is one.
    public var project: URL?
    /// Why it failed, in the add-on's words, for the host to show as-is.
    public var message: String?

    public init(correlationID: UUID, outcome: Outcome, project: URL? = nil, message: String? = nil) {
        self.correlationID = correlationID
        self.outcome = outcome
        self.project = project
        self.message = message
    }
}
