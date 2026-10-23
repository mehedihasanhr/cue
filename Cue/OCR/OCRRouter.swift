import Foundation

/// The decision about who reads an image, and in what.
nonisolated struct OCRRoute: Equatable, Sendable {
    let engine: OCREngineID
    /// Ordered and already filtered to what `engine` can actually read. Empty means
    /// "detect it", which only Vision offers.
    let languages: [OCRLanguage]
    /// Tried only when the primary engine throws, and only when it genuinely reads
    /// this language. Never set for a language Vision has no model for — that is the
    /// rule this whole feature exists to enforce.
    let fallback: OCREngineID?

    var detectsLanguage: Bool { engine == .vision && languages.isEmpty }
    /// The alphabet the answer ought to be in; `nil` when nothing was asked for.
    var expectedScript: OCRScript? { languages.first?.script }
}

/// Picks the engine from the language. The user never chooses an engine — they choose
/// what they are reading, and this works out who can read it.
nonisolated enum OCRRouter {
    /// Availability comes in as a closure so the whole table can be exercised without
    /// building a single engine.
    static func route(
        _ settings: OCRSettings,
        availability: (OCREngineID, OCRLanguage) -> OCREngineAvailability
    ) -> Result<OCRRoute, OCRUnavailable> {
        guard let primary = settings.selection.primary else {
            // Nothing asked for: Vision detects the language, exactly as Cue has
            // always done. No fallback, no second guess, no behaviour change.
            return .success(OCRRoute(engine: .vision, languages: [], fallback: nil))
        }

        let requested = settings.selection.languages
        let visionState = availability(.vision, primary)
        let tesseractState = availability(.tesseract, primary)
        let cloudState = availability(.cloud, primary)

        // Vision is considered only for languages macOS actually ships a model for.
        // `VisionOCREngine` reports `.unsupported` for everything else, so Bangla can
        // never reach the Devanagari model by this path.
        let visionCan = visionState != .unsupported
        let tesseractCan = tesseractState != .unsupported
        let cloudPresent = cloudState != .unsupported
        let cloudReady = cloudState.isReady

        func visionRoute(fallback: OCREngineID? = nil) -> OCRRoute {
            OCRRoute(engine: .vision, languages: requested.filter(OCRLanguageCatalog.isVisionSupported), fallback: fallback)
        }

        if settings.preferCloud, cloudReady {
            return .success(OCRRoute(engine: .cloud, languages: requested, fallback: visionCan ? .vision : nil))
        }
        if visionCan {
            return .success(visionRoute())
        }
        if tesseractCan {
            // No Vision fallback: it would answer in the wrong alphabet, which is the
            // bug. If Tesseract cannot do it, Cue says so instead.
            return .success(OCRRoute(engine: .tesseract, languages: requested.filter { $0.tesseractCode != nil }, fallback: nil))
        }
        if cloudReady {
            return .success(OCRRoute(engine: .cloud, languages: requested, fallback: nil))
        }
        if cloudPresent, case .needsSetup = cloudState {
            return .failure(.cloudNotConfigured)
        }
        return .failure(.noEngine(primary))
    }
}
