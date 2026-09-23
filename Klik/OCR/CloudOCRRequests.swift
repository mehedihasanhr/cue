import CoreGraphics
import Foundation

/// Building the requests a cloud recogniser takes, and reading what comes back.
///
/// Separate from the engine that sends them, so all of this can be tested without a
/// network or a key — the same split as `TaskWire` and `TaskSync`.
nonisolated enum CloudOCRRequests {
    enum Failure: Error, LocalizedError {
        case badURL
        case malformedAnswer
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .badURL: "That endpoint isn't a valid URL."
            case .malformedAnswer: "The service's answer wasn't in a shape Klik understands."
            case .refused(let message): message
            }
        }
    }

    // MARK: - Google Cloud Vision

    /// `DOCUMENT_TEXT_DETECTION`, which is the mode meant for dense text rather than
    /// the odd sign in a photograph. The key goes in the query string because that is
    /// the only place this API takes it.
    static func googleRequest(png: Data, languages: [OCRLanguage], secret: String) throws -> URLRequest {
        guard var components = URLComponents(string: "https://vision.googleapis.com/v1/images:annotate") else {
            throw Failure.badURL
        }
        components.queryItems = [URLQueryItem(name: "key", value: secret)]
        guard let url = components.url else { throw Failure.badURL }

        let body: [String: Any] = [
            "requests": [[
                "image": ["content": png.base64EncodedString()],
                "features": [["type": "DOCUMENT_TEXT_DETECTION"]],
                "imageContext": ["languageHints": languages.map(\.tag)],
            ]],
        ]
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Google answers in pixels measured from the top left. Everything downstream
    /// wants Vision's normalised box with its origin at the bottom left, so each
    /// paragraph's vertices are converted here — get this wrong and the lines come out
    /// upside down, quietly.
    static func parseGoogle(_ data: Data, imageSize: CGSize) throws -> [RecognizedTextItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformedAnswer
        }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            throw Failure.refused(message)
        }
        guard let responses = root["responses"] as? [[String: Any]], let first = responses.first else {
            throw Failure.malformedAnswer
        }
        if let error = first["error"] as? [String: Any], let message = error["message"] as? String {
            throw Failure.refused(message)
        }
        guard let annotation = first["fullTextAnnotation"] as? [String: Any] else { return [] }
        guard let pages = annotation["pages"] as? [[String: Any]] else { return [] }

        var items: [RecognizedTextItem] = []
        for page in pages {
            for block in page["blocks"] as? [[String: Any]] ?? [] {
                for paragraph in block["paragraphs"] as? [[String: Any]] ?? [] {
                    let words = paragraph["words"] as? [[String: Any]] ?? []
                    let text = words.map { word in
                        (word["symbols"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
                    }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let confidence = (paragraph["confidence"] as? NSNumber)?.floatValue ?? 1
                    let box = boundingBox(from: paragraph["boundingBox"] as? [String: Any], imageSize: imageSize)
                    items.append(RecognizedTextItem(text: text, confidence: confidence, boundingBox: box ?? .zero))
                }
            }
        }
        return items
    }

    /// Converts Google's `boundingBox.vertices` — pixels, top-left origin — into a
    /// normalised, bottom-left-origin rect.
    static func boundingBox(from box: [String: Any]?, imageSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0,
              let vertices = box?["vertices"] as? [[String: Any]], !vertices.isEmpty
        else { return nil }
        // Via NSNumber: JSONSerialization hands back numbers that bridge to either
        // Int or Double depending on how they were written, and `as? Double` alone
        // silently misses the integer ones — which would put every box at the origin.
        let xs = vertices.map { ($0["x"] as? NSNumber)?.doubleValue ?? 0 }
        let ys = vertices.map { ($0["y"] as? NSNumber)?.doubleValue ?? 0 }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX / imageSize.width,
                      y: 1 - maxY / imageSize.height,
                      width: (maxX - minX) / imageSize.width,
                      height: (maxY - minY) / imageSize.height)
    }

    // MARK: - A vision model

    /// One message with the image attached and an instruction naming the language.
    /// The shape is the OpenAI chat-completions one, which Anthropic-compatible
    /// gateways and most self-hosted servers also speak.
    static func modelRequest(png: Data, languages: [OCRLanguage], configuration: CloudOCRConfiguration) throws -> URLRequest {
        guard let url = URL(string: configuration.endpoint) else { throw Failure.badURL }
        let named = languages.first?.displayName
        let instruction = named.map { "Transcribe the text in this image exactly, in \($0). Reply with the text only." }
            ?? "Transcribe the text in this image exactly. Reply with the text only."

        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": 4096,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": instruction],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(png.base64EncodedString())"]],
                ],
            ]],
        ]
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.secret)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// A model returns prose, not boxes. The whole answer becomes one item spanning
    /// the image, which `TextLayout` then passes through unchanged — so
    /// `RecognizedText.bestText`'s indentation path does nothing for this provider,
    /// and code captured this way keeps whatever shape the model gave it.
    static func parseModel(_ data: Data) throws -> [RecognizedTextItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformedAnswer
        }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            throw Failure.refused(message)
        }
        let text: String?
        if let choices = root["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            text = message["content"] as? String
        } else if let content = root["content"] as? [[String: Any]] {
            // Anthropic's native shape, in case the endpoint speaks that instead.
            text = content.compactMap { $0["text"] as? String }.joined()
        } else {
            text = nil
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard text != nil else { throw Failure.malformedAnswer }
            return []
        }
        return [RecognizedTextItem(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                   confidence: 1,
                                   boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))]
    }

    static var userAgent: String {
        "Klik/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"
    }

    /// What the service says the request cost.
    ///
    /// Best-effort by design: the two wire shapes name the fields differently, and
    /// Google Cloud Vision bills per image rather than per token and reports none.
    /// It exists so the cost of a capture is visible at all — this is the one path
    /// in Klik that spends the reader's money.
    struct Usage: Sendable, Equatable {
        var input: Int
        var output: Int
    }

    static func usage(_ data: Data) -> Usage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any],
              // NSNumber, because JSON integers bridge to Int or Double by how they
              // were written and `as? Int` alone misses half of them.
              let input = (usage["input_tokens"] ?? usage["prompt_tokens"]) as? NSNumber,
              let output = (usage["output_tokens"] ?? usage["completion_tokens"]) as? NSNumber
        else { return nil }
        return Usage(input: input.intValue, output: output.intValue)
    }
}
