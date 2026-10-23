import os
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A recogniser somewhere else.
///
/// The only part of Cue that sends a capture off this Mac, and it exists only while
/// the switch in Settings › Capture is on and a key has been entered. What it uploads
/// is the selected area and nothing else — no file name, no window title, no library.
///
/// It reads anything, which is what makes it the last resort for a language with no
/// model on either side. It is never reached by default.
nonisolated struct CloudOCREngine: OCREngine {
    let id = OCREngineID.cloud
    let configuration: CloudOCRConfiguration

    func availability(for language: OCRLanguage) -> OCREngineAvailability {
        configuration.isUsable ? .ready : .needsSetup("Add your key in Settings › Capture.")
    }

    func recognize(_ cgImage: CGImage, languages: [OCRLanguage], minimumConfidence: Float) async throws -> [RecognizedTextItem] {
        guard configuration.isUsable else { throw OCRUnavailable.cloudNotConfigured }
        guard let png = Self.png(from: cgImage) else { throw CloudOCRRequests.Failure.malformedAnswer }

        let request: URLRequest
        switch configuration.provider {
        case .google: request = try CloudOCRRequests.googleRequest(png: png, languages: languages, secret: configuration.secret)
        case .model: request = try CloudOCRRequests.modelRequest(png: png, languages: languages, configuration: configuration)
        }

        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudOCRRequests.Failure.malformedAnswer }
            guard (200..<300).contains(http.statusCode) else {
                // The first couple of lines of the body, never the whole thing and
                // never the request — it holds the image and the key.
                let detail = String(decoding: body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw OCRUnavailable.cloudFailed("\(http.statusCode): \(detail)")
            }
            data = body
            // What it cost, so that is answerable without a Console trip. Counts
            // only — never the text, never the key, never the body.
            if let usage = CloudOCRRequests.usage(data) {
                Log.ocr.info("\(configuration.provider.rawValue, privacy: .public) read \(usage.input) in / \(usage.output) out tokens")
            }
        } catch let error as OCRUnavailable {
            throw error
        } catch {
            throw OCRUnavailable.cloudFailed(error.localizedDescription)
        }

        let size = CGSize(width: cgImage.width, height: cgImage.height)
        do {
            switch configuration.provider {
            case .google: return try CloudOCRRequests.parseGoogle(data, imageSize: size)
            case .model: return try CloudOCRRequests.parseModel(data)
            }
        } catch {
            throw OCRUnavailable.cloudFailed(error.localizedDescription)
        }
    }

    /// Sends a lossless PNG: recognition on a re-compressed screenshot is measurably
    /// worse, and a selected region is small.
    static func png(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Asks the service to read a tiny image, so Settings can say whether the key
    /// works without waiting for a real capture.
    func check() async throws {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context?.setFillColor(gray: 1, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context?.makeImage() else { throw CloudOCRRequests.Failure.malformedAnswer }
        _ = try await recognize(image, languages: [OCRLanguage("en-US")], minimumConfidence: 0)
    }
}
