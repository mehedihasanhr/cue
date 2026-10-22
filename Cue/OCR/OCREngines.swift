import Foundation
import Observation

/// The recognisers the app has built, and the language packs behind them.
///
/// One place that knows which engines exist, so Settings and a capture never disagree
/// about whether a language can be read. The set is rebuilt on each read because the
/// cloud engine only exists while it is switched on and configured — reading it is a
/// struct initialisation, and a capture happens at most a few times a minute.
@Observable
@MainActor
final class OCREngines {
    let packs = LanguagePackStore()
    private let preferences: AppPreferences

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    /// Rebuilt only when the cloud configuration changes.
    ///
    /// Settings reads this for every language on every redraw, and building it means
    /// reading the preferences and resolving the stored tags — work with one answer
    /// that was being redone dozens of times a frame.
    /// Ignored by observation: a view reading `set` writes these, and tracking that
    /// would invalidate the view that just read it, over and over.
    @ObservationIgnored private var cached: OCREngineSet?
    @ObservationIgnored private var cachedCloud: CloudOCRConfiguration?

    var set: OCREngineSet {
        let cloud = preferences.ocrSettings.cloud
        if let cached, cachedCloud == cloud { return cached }
        let built = OCREngineSet(
            vision: VisionOCREngine(),
            tesseract: TesseractOCREngine(packs: packs),
            // Exists only while the switch is on; `cloud` is nil until a usable key
            // has been entered, so there is nothing to reach by accident.
            cloud: cloud.map { CloudOCREngine(configuration: $0) }
        )
        cached = built
        cachedCloud = cloud
        return built
    }

    /// Asks the configured service to read a blank image, so Settings can report
    /// whether the key works.
    func checkCloud() async -> String {
        guard let configuration = preferences.ocrSettings.cloud else { return "Add a key first." }
        do {
            try await CloudOCREngine(configuration: configuration).check()
            return "Connected."
        } catch {
            return error.localizedDescription
        }
    }

    /// What Settings shows against each language. Tesseract is asked of the pack
    /// store rather than the engine so a download in progress can be shown; the
    /// engine itself only knows what is on disk.
    func availability(_ id: OCREngineID, _ language: OCRLanguage) -> OCREngineAvailability {
        let engines = set
        switch id {
        case .tesseract:
            return engines.tesseract == nil ? .unsupported : packs.availability(for: language)
        default:
            return engines.availability(id, language)
        }
    }

    /// Starts fetching the pack for a newly chosen language, so the download is
    /// already done — or at least under way — by the time the next capture happens.
    func prepare(for tags: [String]) {
        guard let code = tags.first.flatMap(OCRLanguageCatalog.language(for:))?.tesseractCode,
              !OCRLanguageCatalog.isVisionSupported(OCRLanguage(tags[0])),
              packs.state(of: code) == .missing
        else { return }
        packs.download(code)
    }
}
