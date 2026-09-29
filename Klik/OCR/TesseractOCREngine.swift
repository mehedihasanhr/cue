import CoreGraphics
import Foundation

/// Tesseract, as one of Klik's engines.
///
/// This is the adapter: it turns BCP-47 tags into Tesseract's three-letter codes,
/// makes sure the language model is on disk, and hands the work to
/// `TesseractEngine`. It reads the scripts Vision has no model for — Bangla first
/// among them, which is why any of this exists.
nonisolated struct TesseractOCREngine: OCREngine {
    let id = OCREngineID.tesseract
    /// Downloads and keeps the models. Main-actor isolated, so it is only touched
    /// from the async path.
    let packs: LanguagePackStore

    /// Whether the model is already on disk. Deliberately a filesystem question: this
    /// has to answer without hopping to the main actor, and the disk is the durable
    /// truth anyway. A download in progress is Settings' business, not routing's.
    func availability(for language: OCRLanguage) -> OCREngineAvailability {
        guard let code = language.tesseractCode,
              let pack = TesseractLanguagePacks.pack(forCode: code) else { return .unsupported }
        return TessdataFiles.isInstalled(code) ? .ready : .needsDownload(bytes: pack.bytes)
    }

    func recognize(_ cgImage: CGImage, languages: [OCRLanguage], minimumConfidence: Float) async throws -> [RecognizedTextItem] {
        let codes = languages.compactMap(\.tesseractCode)
        guard let primary = languages.first, let primaryCode = codes.first else {
            throw TesseractError.couldNotStart
        }

        // Fetch the model if it is not here. A capture made while the download is
        // still running waits for it rather than being refused — the download starts
        // as soon as the language is chosen in Settings, so this is usually instant.
        do {
            for code in codes { try await packs.ensure(code) }
        } catch {
            let offline = (error as? URLError).map {
                [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .timedOut, .dataNotAllowed].contains($0.code)
            } ?? false
            throw OCRUnavailable.packDownloadFailed(primary, offline: offline)
        }

        guard let buffer = OCRImageBuffer.make(from: cgImage) else { throw TesseractError.couldNotRender }
        // Several languages are offered to Tesseract at once with "+", which is how
        // it reads a screen that mixes them.
        let language = codes.joined(separator: "+")
        return try await TesseractEngine.shared.recognize(buffer, language: language,
                                                          datapath: TessdataFiles.folder,
                                                          minimumConfidence: minimumConfidence)
    }

    /// Whether the pack for `language` still needs fetching, for the one case that
    /// wants to know before starting: Settings.
    static func needsDownload(_ language: OCRLanguage) -> Bool {
        guard let code = language.tesseractCode else { return false }
        return !TessdataFiles.isInstalled(code)
    }
}
