import CoreGraphics
import Foundation

/// What a recording is asked to be: its target, its tracks and where it goes.
///
/// Codable because it used to cross a process boundary, when the recorder was a separate
/// app; the wire format is kept so the tests that pin it still describe it.
public struct RecordingRequest: Sendable, Codable, Equatable {
    public enum Target: Sendable, Codable, Equatable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
        case area(display: CGDirectDisplayID, rect: CGRect)
        /// An iPhone or iPad on a cable, by its capture device's `uniqueID`.
        case device(uniqueID: String)
        /// Let the add-on ask, which is what the menu bar item does.
        case ask

        /// The shape the compiler would have written for these cases, kept as a type of
        /// its own so the wire format is exactly the one every request has always had.
        private enum Wire: Codable {
            case display(CGDirectDisplayID)
            case window(CGWindowID)
            case area(display: CGDirectDisplayID, rect: CGRect)
            case device(uniqueID: String)
            case ask
        }

        /// Leniently: a target this build does not recognise — one a newer host added —
        /// reads as `.ask` rather than failing the whole request. "Ask me" is the one
        /// target that is always safe to fall back on, because it puts a picker up
        /// instead of recording something nobody chose; failing to decode would have
        /// dropped the request on the floor, which is the one outcome nobody asked for.
        public init(from decoder: any Decoder) throws {
            guard let wire = try? Wire(from: decoder) else {
                self = .ask
                return
            }
            self = switch wire {
            case .display(let id): .display(id)
            case .window(let id): .window(id)
            case .area(let display, let rect): .area(display: display, rect: rect)
            case .device(let id): .device(uniqueID: id)
            case .ask: .ask
            }
        }

        public func encode(to encoder: any Encoder) throws {
            let wire: Wire = switch self {
            case .display(let id): .display(id)
            case .window(let id): .window(id)
            case .area(let display, let rect): .area(display: display, rect: rect)
            case .device(let id): .device(uniqueID: id)
            case .ask: .ask
            }
            try wire.encode(to: encoder)
        }
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
    /// The `.cuerec` package, when there is one.
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
