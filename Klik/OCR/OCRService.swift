import os
import CoreGraphics
import Vision

/// One recognised line of text. `boundingBox` is in Vision's normalised image space:
/// (0, 0) is the image's bottom-left, (1, 1) its top-right. Kept so a later version
/// can draw selectable text over the capture; use `pixelRect(in:)` for view space.
nonisolated struct RecognizedTextItem: Hashable, Sendable {
    let text: String
    /// 0…1, from Vision.
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

/// The outcome of recognising an image: the individual items plus the composed text.
nonisolated struct RecognizedText: Sendable {
    let items: [RecognizedTextItem]
    /// Items arranged in reading order with line and paragraph breaks preserved.
    let text: String

    var isEmpty: Bool { text.isEmpty }
}

nonisolated enum OCRError: Error, LocalizedError {
    case recognitionFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .recognitionFailed(let error): "Text recognition failed: \(error.localizedDescription)"
        }
    }
}

/// On-device text recognition with Vision. Nothing leaves the Mac, and the recognised
/// text is never logged.
nonisolated struct OCRService: Sendable {
    /// Lines below this confidence are dropped; Vision's accurate level is rarely wrong
    /// above it and it keeps stray marks out of the clipboard.
    var minimumConfidence: Float = 0.3

    init() {}

    /// The full recognised text, in reading order.
    func recognizeText(from image: CapturedImage) async throws(OCRError) -> String {
        try await recognize(image.cgImage).text
    }

    /// Recognised lines with their positions (normalised, bottom-left origin).
    func recognizeTextWithBounds(from image: CapturedImage) async throws(OCRError) -> [RecognizedTextItem] {
        try await recognize(image.cgImage).items
    }

    /// Everything Vision found in a `CGImage`, composed into readable text.
    func recognize(_ cgImage: CGImage) async throws(OCRError) -> RecognizedText {
        let items: [RecognizedTextItem]
        do {
            items = try await Self.performRecognition(on: cgImage, minimumConfidence: minimumConfidence)
        } catch {
            Log.ocr.error("Vision request failed: \(error.localizedDescription, privacy: .public)")
            throw .recognitionFailed(error)
        }
        return RecognizedText(items: items, text: TextLayout.compose(items))
    }

    /// Vision's handler is synchronous, so the request runs on a background executor.
    @concurrent
    private static func performRecognition(on cgImage: CGImage, minimumConfidence: Float) async throws -> [RecognizedTextItem] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // macOS 13+: pick the script/language per image instead of assuming English.
        request.automaticallyDetectsLanguage = true

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
