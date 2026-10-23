import CoreGraphics
import Vision

/// Apple's recogniser — the one built into macOS.
///
/// It is fast, free and never leaves the Mac, and for the languages Apple ships models
/// for it is the best of the three. The important thing here is the boundary: this
/// engine reports `.unsupported` for every language outside
/// `OCRLanguageCatalog.vision`, so nothing can route Bangla to it.
///
/// That boundary has to be drawn by Cue, because Vision will not draw it. Setting
/// `recognitionLanguages` to a language it has no model for throws neither on
/// assignment nor when the request runs; it simply answers in whatever script it does
/// know. Asked to read Bangla it returns Devanagari, at confidence 1.00.
nonisolated struct VisionOCREngine: OCREngine {
    let id = OCREngineID.vision

    func availability(for language: OCRLanguage) -> OCREngineAvailability {
        OCRLanguageCatalog.isVisionSupported(language) ? .ready : .unsupported
    }

    /// Vision's handler is synchronous, so the request runs on a background executor.
    @concurrent
    func recognize(_ cgImage: CGImage, languages: [OCRLanguage], minimumConfidence: Float) async throws -> [RecognizedTextItem] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty {
            // Cue's automatic mode, and the only place detection still happens.
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = languages.map(\.tag)
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        return observations.compactMap { observation -> RecognizedTextItem? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence
            else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedTextItem(text: text, confidence: candidate.confidence, boundingBox: observation.boundingBox)
        }
    }
}
