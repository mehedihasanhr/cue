import CoreGraphics
import Foundation

/// Who read the text.
nonisolated enum OCREngineID: String, Sendable, Codable, CaseIterable {
    /// Apple's, built into macOS. Fast, free, private — and limited to the languages
    /// Apple ships models for.
    case vision
    /// Bundled, with a language model downloaded on demand. Reads the scripts Vision
    /// has never had, Bangla among them.
    case tesseract
    /// A service the user configured with their own key. Off unless turned on.
    case cloud

    var title: String {
        switch self {
        case .vision: "Apple Vision"
        case .tesseract: "Tesseract"
        case .cloud: "a cloud service"
        }
    }

    var isOnDevice: Bool { self != .cloud }
}

/// Whether an engine could read a given language right now.
nonisolated enum OCREngineAvailability: Equatable, Sendable {
    case ready
    /// Installed on demand; `bytes` is what it would cost to fetch.
    case needsDownload(bytes: Int?)
    case downloading
    /// Configured by hand and not configured yet; the string says what is missing.
    case needsSetup(String)
    case failed(String, offline: Bool)
    /// This engine will never read this language, whatever the user does.
    case unsupported

    var isReady: Bool { self == .ready }
}

/// Something that turns an image into lines of text.
nonisolated protocol OCREngine: Sendable {
    var id: OCREngineID { get }
    func availability(for language: OCRLanguage) -> OCREngineAvailability
    /// `languages` is ordered and already filtered to what this engine can read; the
    /// first is the primary. Empty means "detect it yourself", which only Vision
    /// offers and only in Cue's automatic mode.
    func recognize(_ cgImage: CGImage, languages: [OCRLanguage], minimumConfidence: Float) async throws -> [RecognizedTextItem]
}

/// The engines one `OCRService` may use, as a value it can carry across an actor hop.
///
/// Vision is always present. The other two are absent until the app builds them —
/// `.onDevice` is what a bare `OCRService()` gets, which keeps every existing call
/// site behaving exactly as it did.
nonisolated struct OCREngineSet: Sendable {
    var vision: any OCREngine
    var tesseract: (any OCREngine)?
    var cloud: (any OCREngine)?

    init(vision: any OCREngine = VisionOCREngine(), tesseract: (any OCREngine)? = nil, cloud: (any OCREngine)? = nil) {
        self.vision = vision
        self.tesseract = tesseract
        self.cloud = cloud
    }

    static let onDevice = OCREngineSet()

    func engine(_ id: OCREngineID) -> (any OCREngine)? {
        switch id {
        case .vision: vision
        case .tesseract: tesseract
        case .cloud: cloud
        }
    }

    /// An engine Cue does not hold cannot read anything.
    func availability(_ id: OCREngineID, _ language: OCRLanguage) -> OCREngineAvailability {
        engine(id)?.availability(for: language) ?? .unsupported
    }
}

/// Why Cue is not going to hand back any text.
///
/// One case per situation a person could act on, because the alternative — the one
/// this whole feature exists to undo — is answering in the wrong alphabet and saying
/// nothing about it.
nonisolated enum OCRUnavailable: Equatable, Sendable, LocalizedError {
    case noEngine(OCRLanguage)
    case packMissing(OCRLanguage, bytes: Int?)
    case packDownloadFailed(OCRLanguage, offline: Bool)
    case cloudNotConfigured
    case cloudFailed(String)
    /// The text came back in an alphabet the user did not ask for.
    case wrongScript(expected: OCRScript, found: OCRScript)

    var errorDescription: String? {
        switch self {
        case .noEngine(let language): "Cue can't read \(language.displayName) yet"
        case .packMissing(let language, _): "The \(language.displayName) pack isn't downloaded"
        case .packDownloadFailed(let language, _): "Couldn't download \(language.displayName)"
        case .cloudNotConfigured: "The cloud service needs a key"
        case .cloudFailed: "The cloud service didn't answer"
        case .wrongScript(let expected, let found): "That looks like \(found.displayName), not \(expected.displayName)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noEngine:
            return "Turn on a cloud service in Settings › Capture."
        case .packMissing(_, let bytes):
            guard let bytes else { return "Download it in Settings › Capture." }
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "Download it (\(size)) in Settings › Capture."
        case .packDownloadFailed(_, let offline):
            return offline ? "Cue is offline. Try again in Settings › Capture."
                           : "The download failed. Try again in Settings › Capture."
        case .cloudNotConfigured:
            return "Add it in Settings › Capture."
        case .cloudFailed(let message):
            return message
        case .wrongScript:
            return "Cue didn't copy it. Pick the right language in Settings › Capture."
        }
    }

    /// The SF Symbol the HUD shows.
    var symbol: String {
        switch self {
        case .noEngine, .wrongScript: "character.magnify"
        case .packMissing: "arrow.down.circle"
        case .packDownloadFailed(_, let offline): offline ? "wifi.slash" : "exclamationmark.triangle.fill"
        case .cloudNotConfigured: "key.fill"
        case .cloudFailed: "exclamationmark.icloud.fill"
        }
    }
}
