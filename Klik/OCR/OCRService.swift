import os
import CoreGraphics
import Vision

/// One recognised line of text. `boundingBox` is in Vision's normalised image space:
/// (0, 0) is the image's bottom-left, (1, 1) its top-right. Kept so a later version
/// can draw selectable text over the capture; use `pixelRect(in:)` for view space.
///
/// Every engine answers in these coordinates, whatever it uses internally, so
/// `TextLayout` never has to know who read the image.
nonisolated struct RecognizedTextItem: Hashable, Sendable {
    let text: String
    /// 0…1, from the engine.
    let confidence: Float
    let boundingBox: CGRect

    /// The box in pixel coordinates with a top-left origin, for drawing over the image.
    func pixelRect(in imageSize: CGSize) -> CGRect {
        CGRect(
            x: boundingBox.minX * imageSize.width,
            y: (1 - boundingBox.maxY) * imageSize.height,
            width: boundingBox.width * imageSize.width,
            height: boundingBox.height * imageSize.height
        )
    }
}

/// Text came back, but in an alphabet worth mentioning.
///
/// Only raised in automatic mode, where Klik was never told what to expect and so
/// cannot refuse — it can only point out that the answer may not be the one wanted.
nonisolated struct OCRScriptWarning: Sendable, Equatable {
    let found: OCRScript
    /// What the reader may actually have been looking at.
    let possiblyIntended: OCRScript
}

/// The outcome of recognising an image: the individual items plus the composed text.
nonisolated struct RecognizedText: Sendable {
    let items: [RecognizedTextItem]
    /// Items arranged in reading order with line and paragraph breaks preserved.
    let text: String
    /// Who read it.
    let engine: OCREngineID
    /// What it was read as, or `nil` when the language was detected rather than asked for.
    let language: OCRLanguage?
    let scriptWarning: OCRScriptWarning?
    let direction: TextLayout.Direction

    init(items: [RecognizedTextItem], text: String, engine: OCREngineID = .vision,
         language: OCRLanguage? = nil, scriptWarning: OCRScriptWarning? = nil,
         direction: TextLayout.Direction = .leftToRight) {
        self.items = items
        self.text = text
        self.engine = engine
        self.language = language
        self.scriptWarning = scriptWarning
        self.direction = direction
    }

    var isEmpty: Bool { text.isEmpty }

    /// The same lines with their indentation kept — what code wants.
    var indentedText: String { TextLayout.compose(items, keepIndentation: true, direction: direction) }

    /// Code keeps its indentation; prose comes as plain lines.
    var bestText: String {
        let indented = indentedText
        return CodeSnippet.detect(indented) != nil ? indented : text
    }
}

nonisolated enum OCRError: Error, LocalizedError {
    case recognitionFailed(any Error)
    /// Klik declined to answer, and can say why in terms the reader can act on.
    case unavailable(OCRUnavailable)

    var errorDescription: String? {
        switch self {
        case .recognitionFailed(let error): "Text recognition failed: \(error.localizedDescription)"
        case .unavailable(let reason): reason.errorDescription
        }
    }
}

/// Text recognition.
///
/// On this Mac by default: Apple Vision for the languages macOS ships models for,
/// Tesseract with a downloaded language pack for the scripts it does not — Bangla
/// among them. Nothing leaves the Mac unless the cloud engine is turned on by hand in
/// Settings › Capture, which uploads the selected area, and only that, to the service
/// configured there with the reader's own key.
///
/// The recognised text is never logged, and neither is the key.
///
/// The rule this type enforces: **an engine is only ever asked for a language it
/// actually has a model for.** Vision does not refuse work it cannot do — asked to
/// read Bangla it answers in Devanagari at full confidence — so the refusing is done
/// here, and a result in an unexpected alphabet is reported rather than pasted.
nonisolated struct OCRService: Sendable {
    /// Lines below this confidence are dropped; Vision's accurate level is rarely wrong
    /// above it and it keeps stray marks out of the clipboard.
    var minimumConfidence: Float = 0.3
    var settings = OCRSettings()
    var engines = OCREngineSet.onDevice

    /// Today's behaviour, unchanged: Vision, detecting the language itself.
    init() {}

    init(settings: OCRSettings, engines: OCREngineSet = .onDevice, minimumConfidence: Float = 0.3) {
        self.settings = settings
        self.engines = engines
        self.minimumConfidence = minimumConfidence
    }

    /// The full recognised text, in reading order.
    func recognizeText(from image: CapturedImage) async throws(OCRError) -> String {
        try await recognize(image.cgImage).text
    }

    /// Recognised lines with their positions (normalised, bottom-left origin).
    func recognizeTextWithBounds(from image: CapturedImage) async throws(OCRError) -> [RecognizedTextItem] {
        try await recognize(image.cgImage).items
    }

    /// Everything the chosen engine found in a `CGImage`, composed into readable text.
    func recognize(_ cgImage: CGImage) async throws(OCRError) -> RecognizedText {
        let route: OCRRoute
        switch OCRRouter.route(settings, availability: { engines.availability($0, $1) }) {
        case .success(let resolved): route = resolved
        case .failure(let reason):
            Log.ocr.info("Declined: \(String(describing: reason), privacy: .public)")
            throw .unavailable(reason)
        }

        let items = try await run(route, on: cgImage)
        let direction: TextLayout.Direction = (route.expectedScript?.isRightToLeft ?? false) ? .rightToLeft : .leftToRight
        let text = TextLayout.compose(items, direction: direction)

        // Only judged when there is enough writing to judge — a capture of a column
        // of numbers has no alphabet and must not be refused for it.
        if let expected = route.expectedScript, settings.checksScript,
           OCRScript.letterCount(in: text) >= OCRScript.minimumLettersToJudge,
           expected.share(in: text) < OCRScript.minimumShare {
            let found = OCRScript.dominant(in: text) ?? .other
            Log.ocr.info("Declined: asked for \(expected.rawValue, privacy: .public), got \(found.rawValue, privacy: .public)")
            throw .unavailable(.wrongScript(expected: expected, found: found))
        }

        return RecognizedText(items: items, text: text, engine: route.engine,
                              language: route.languages.first,
                              scriptWarning: warning(for: route, in: text),
                              direction: direction)
    }

    /// Runs the route's engine, and its fallback if it has one and the first threw.
    private func run(_ route: OCRRoute, on cgImage: CGImage) async throws(OCRError) -> [RecognizedTextItem] {
        guard let engine = engines.engine(route.engine) else {
            throw .unavailable(route.languages.first.map(OCRUnavailable.noEngine) ?? .cloudNotConfigured)
        }
        do {
            return try await engine.recognize(cgImage, languages: route.languages, minimumConfidence: minimumConfidence)
        } catch {
            if let reason = error as? OCRUnavailable, route.fallback == nil {
                throw .unavailable(reason)
            }
            guard let fallbackID = route.fallback, let fallback = engines.engine(fallbackID) else {
                Log.ocr.error("\(route.engine.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                throw .recognitionFailed(error)
            }
            Log.ocr.info("\(route.engine.rawValue, privacy: .public) failed; falling back to \(fallbackID.rawValue, privacy: .public)")
            let languages = fallbackID == .vision ? route.languages.filter(OCRLanguageCatalog.isVisionSupported) : route.languages
            do {
                return try await fallback.recognize(cgImage, languages: languages, minimumConfidence: minimumConfidence)
            } catch {
                throw .recognitionFailed(error)
            }
        }
    }

    /// In automatic mode Klik was never told what to expect, so it cannot refuse. The
    /// one thing worth flagging is Devanagari, which is what Vision answers when it is
    /// shown Bangla it has no model for.
    private func warning(for route: OCRRoute, in text: String) -> OCRScriptWarning? {
        guard route.detectsLanguage, !text.isEmpty,
              let found = OCRScript.dominant(in: text),
              let intended = OCRScript.possiblyIntended(whenAnsweredIn: found),
              // Only worth saying if Klik could actually read the other one.
              OCRLanguageCatalog.tesseract.contains(where: { $0.script == intended })
        else { return nil }
        return OCRScriptWarning(found: found, possiblyIntended: intended)
    }
}
