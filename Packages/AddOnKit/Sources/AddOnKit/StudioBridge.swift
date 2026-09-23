import Foundation

/// The names both sides have to agree on before either can find the other.
public enum AddOnBridge {
    /// The add-on's bundle identifier — the handle discovery, the signature check and
    /// the future Mach service name all derive from.
    public static let studioBundleID = "com.stackrover.klik.studio"

    /// The App Group both apps join. Mach ports are blocked by the App Sandbox except
    /// between processes in the same group, and a group-prefixed service name is the
    /// supported way for two sandboxed apps to talk. The group container is also where
    /// media is handed over, so no security-scoped bookmarks are needed.
    public static let appGroup = "group.com.stackrover.klik"

    /// The XPC service the add-on's login-item helper will vend. Prefixed with the
    /// group because the sandbox refuses anything else.
    public static let machServiceName = "\(appGroup).studio"

    /// The URL scheme the add-on answers on. This is the transport until the Mach
    /// service exists, and stays afterwards as the way Finder and the host launch it.
    public static let urlScheme = "klik-studio"

    /// The query item carrying the path of a written `RecordingRequest`.
    public static let requestQueryItem = "request"
}

/// What an installed add-on can do.
///
/// Capability-first, so the host asks before it offers: an older add-on simply exposes
/// fewer menu items instead of failing when one is chosen. Adding a capability is a
/// new field with a default of `false`, never a new protocol.
public struct StudioCapabilities: Sendable, Codable, Equatable {
    /// The contract this add-on speaks. Bumped only on a breaking change.
    public static let currentContract = 1

    public var contract: Int
    public var version: String
    public var canRecordDisplay: Bool
    public var canRecordWindow: Bool
    public var canRecordArea: Bool
    public var canRecordSystemAudio: Bool
    public var canRecordMicrophone: Bool
    public var canRecordWebcam: Bool
    public var canEdit: Bool
    public var canExportGIF: Bool
    public var canCaption: Bool

    public init(contract: Int = StudioCapabilities.currentContract,
                version: String,
                canRecordDisplay: Bool = false,
                canRecordWindow: Bool = false,
                canRecordArea: Bool = false,
                canRecordSystemAudio: Bool = false,
                canRecordMicrophone: Bool = false,
                canRecordWebcam: Bool = false,
                canEdit: Bool = false,
                canExportGIF: Bool = false,
                canCaption: Bool = false) {
        self.contract = contract
        self.version = version
        self.canRecordDisplay = canRecordDisplay
        self.canRecordWindow = canRecordWindow
        self.canRecordArea = canRecordArea
        self.canRecordSystemAudio = canRecordSystemAudio
        self.canRecordMicrophone = canRecordMicrophone
        self.canRecordWebcam = canRecordWebcam
        self.canEdit = canEdit
        self.canExportGIF = canExportGIF
        self.canCaption = canCaption
    }

    /// Whether a host speaking `contract` can talk to this add-on at all.
    public func speaks(contract host: Int) -> Bool { contract == host }

    /// Whether the add-on can serve this request as asked.
    public func supports(_ request: RecordingRequest) -> Bool {
        let targetSupported = switch request.target {
        case .display: canRecordDisplay
        case .window: canRecordWindow
        case .area: canRecordArea
        case .ask: canRecordDisplay || canRecordWindow || canRecordArea
        }
        if !targetSupported { return false }
        if request.systemAudio && !canRecordSystemAudio { return false }
        if request.microphone && !canRecordMicrophone { return false }
        if request.webcam && !canRecordWebcam { return false }
        return true
    }
}

/// What the add-on offers the host, whatever the transport underneath.
///
/// Written now so the URL-scheme handoff and the eventual XPC service are two
/// implementations of one contract rather than two designs.
public protocol StudioRecording: Sendable {
    func capabilities() async -> StudioCapabilities
    func beginRecording(_ request: RecordingRequest) async throws -> RecordingResult
    func cancelRecording(_ correlationID: UUID) async
}

/// Every answer carries one of these, so a failure means the same thing on both sides.
public enum AddOnBridgeError: String, Error, Sendable, Codable {
    case unsupportedContract
    case unsupportedRequest
    case permissionDenied
    case busy
    case cancelled
    case internalFailure
}
