import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
import WebPKit

/// What Transform does to files, each written as a new file into a folder (the
/// originals are only read). Off the main actor: it is all slow work.
nonisolated enum TransformEngine {
    /// The image formats Transform writes.
    enum Format: String, CaseIterable, Sendable, Codable {
        case automatic, jpeg, heic, avif, webp, png, tiff, bmp

        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .jpeg: "JPEG"
            case .heic: "HEIC"
            case .avif: "AVIF"
            case .webp: "WebP"
            case .png: "PNG"
            case .tiff: "TIFF"
            case .bmp: "BMP"
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .heic: "heic"
            case .avif: "avif"
            case .webp: "webp"
            case .png, .automatic: "png"
            case .tiff: "tiff"
            case .bmp: "bmp"
            }
        }

        var type: UTType {
            switch self {
            case .jpeg: .jpeg
            case .heic: .heic
            case .avif: UTType("public.avif") ?? .heic
            case .webp: .webP
            case .png, .automatic: .png
            case .tiff: .tiff
            case .bmp: .bmp
            }
        }

        var isLossy: Bool { self == .jpeg || self == .heic || self == .avif || self == .webp }

        /// The ones this Mac can write: AVIF only where ImageIO writes it (WebP always,
        /// through libwebp).
        static var available: [Format] {
            let types = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
            return allCases.filter { $0 == .webp || $0 == .automatic || types.contains($0.type.identifier) }
        }
    }

    struct Rotation: Equatable, Sendable, Codable {
        /// Clockwise quarter turns, 0 to 3.
        var quarterTurns = 1
        var flipHorizontal = false
        var flipVertical = false
    }

    // MARK: - Reading

    static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false
    }

    static func isPDF(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .pdf) ?? false
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// The image upright, at most `maxSide` pixels on its long side (nil: full size).
    static func upright(_ url: URL, maxSide: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let full = pixelSize(source).map { max($0.width, $0.height) } ?? 0
        let side = min(maxSide ?? full, full)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(side, 1)]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func pixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// The format an image keeps under Automatic: HEIC stays HEIC, transparency PNG, the rest JPEG.
    static func automaticFormat(for url: URL) -> Format {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        if type == .heic { return .heic }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return .jpeg }
        return (properties[kCGImagePropertyHasAlpha] as? Bool ?? false) ? .png : .jpeg
    }

    /// The source's metadata to carry over, without what drawing upright already did.
    private static func metadata(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        properties[kCGImagePropertyOrientation] = nil
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyHasAlpha] { properties[key] = nil }
        return properties
    }

    // MARK: - Encoding

    /// `image` as `format` (never Automatic) at `quality`, with `properties`.
    static func encode(_ image: CGImage, as format: Format, quality: Double, properties: [CFString: Any] = [:]) -> Data? {
        if format == .webp { return WebP.encode(image, quality: quality) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { return nil }
        var options = properties
        if format.isLossy { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A file named `name` in a new folder of its own inside `folder`.
    static func write(_ data: Data, named name: String, into folder: URL) -> URL? {
        let output = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: output)) != nil ? output : nil
    }

    private static func baseName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    // MARK: - Compress

    struct CompressOptions: Equatable, Sendable, Codable {
        enum By: String, Sendable, Codable { case quality, fileSize }
        var by: By = .quality
        /// 0.05 to 1.
        var quality = 0.7
        /// The most each file may weigh, in bytes, compressing by file size.
        var targetBytes = 1_000_000
        var format: Format = .automatic
        /// Pixels on the long side; nil keeps the size.
        var maxSide: Int?
        var removeMetadata = true
    }

    static func compressed(_ url: URL, _ options: CompressOptions) -> (data: Data, format: Format)? {
        guard var image = upright(url, maxSide: options.maxSide) else { return nil }
        let format = options.format == .automatic ? automaticFormat(for: url) : options.format
        let properties = options.removeMetadata ? [:] : metadata(url)
        switch options.by {
        case .quality:
            return encode(image, as: format, quality: options.quality, properties: properties).map { ($0, format) }
        case .fileSize:
            // A lossless format only gets smaller by shrinking; a lossy one tries
            // qualities first, then shrinks too if even the lowest is over.
            var best: Data?
            for _ in 0..<6 {
                if format.isLossy {
                    var low = 0.05, high = 0.95
                    for _ in 0..<7 {
                        let mid = (low + high) / 2
                        guard let data = encode(image, as: format, quality: mid, properties: properties) else { break }
                        if data.count <= options.targetBytes { best = data; low = mid } else { high = mid }
                    }
                } else if let data = encode(image, as: format, quality: 1, properties: properties), data.count <= options.targetBytes {
                    best = data
                }
                if let best { return (best, format) }
                let side = Int(Double(max(image.width, image.height)) * 0.75)
                guard side > 64, let smaller = upright(url, maxSide: side) else { break }
                image = smaller
            }
            return encode(image, as: format, quality: 0.05, properties: properties).map { ($0, format) }
        }
    }

    static func compress(_ url: URL, _ options: CompressOptions, into folder: URL) -> URL? {
        guard let (data, format) = compressed(url, options) else { return nil }
        return write(data, named: baseName(url) + "." + format.fileExtension, into: folder)
    }

    // MARK: - Convert

    static func converted(_ url: URL, to format: Format, quality: Double) -> Data? {
        guard let image = upright(url) else { return nil }
        return encode(image, as: format == .automatic ? automaticFormat(for: url) : format, quality: quality, properties: metadata(url))
    }

    static func convert(_ url: URL, to format: Format, quality: Double, into folder: URL) -> URL? {
        let format = format == .automatic ? automaticFormat(for: url) : format
        guard let data = converted(url, to: format, quality: quality) else { return nil }
        return write(data, named: baseName(url) + "." + format.fileExtension, into: folder)
    }

    // MARK: - Resize

    struct ResizeOptions: Equatable, Sendable, Codable {
        enum By: String, Sendable, Codable { case side, percent }
        var by: By = .side
        var maxSide = 1920
        /// 5 to 100.
        var percent = 50.0
    }

    static func resized(_ url: URL, _ options: ResizeOptions) -> (data: Data, format: Format)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let size = pixelSize(source) else { return nil }
        let long = max(size.width, size.height)
        let side = options.by == .side ? options.maxSide : Int(Double(long) * options.percent / 100)
        guard let image = upright(url, maxSide: max(side, 1)) else { return nil }
        let format = automaticFormat(for: url)
        return encode(image, as: format, quality: 0.9, properties: metadata(url)).map { ($0, format) }
    }

    static func resize(_ url: URL, _ options: ResizeOptions, into folder: URL) -> URL? {
        guard let (data, format) = resized(url, options) else { return nil }
        return write(data, named: baseName(url) + "." + format.fileExtension, into: folder)
    }

    // MARK: - Remove background

    /// The subject cut out of `url` by Vision, on a transparent background, as PNG.
    static func removeBackground(_ url: URL, into folder: URL) -> URL? {
        guard let image = upright(url) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let result = request.results?.first,
              let buffer = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        else { return nil }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cut = CIContext().createCGImage(ciImage, from: ciImage.extent),
              let data = encode(cut, as: .png, quality: 1) else { return nil }
        return write(data, named: baseName(url) + " (cut out).png", into: folder)
    }

    // MARK: - Rotate

    static func rotated(_ url: URL, _ rotation: Rotation) -> (data: Data, format: Format)? {
        guard let image = upright(url) else { return nil }
        let turns = ((rotation.quarterTurns % 4) + 4) % 4
        let swap = turns % 2 == 1
        let width = swap ? image.height : image.width, height = swap ? image.width : image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        // Quartz turns counter-clockwise; a clockwise quarter turn is a negative angle.
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.scaleBy(x: rotation.flipHorizontal ? -1 : 1, y: rotation.flipVertical ? -1 : 1)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let turned = context.makeImage() else { return nil }
        let format = automaticFormat(for: url)
        return encode(turned, as: format, quality: 0.92, properties: metadata(url)).map { ($0, format) }
    }

    static func rotate(_ url: URL, _ rotation: Rotation, into folder: URL) -> URL? {
        guard let (data, format) = rotated(url, rotation) else { return nil }
        return write(data, named: baseName(url) + "." + format.fileExtension, into: folder)
    }

    // MARK: - Remove metadata

    /// The image without its location, camera and other details, re-encoded only
    /// when the format can't be copied losslessly.
    static func withoutMetadata(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { return nil }
        let data = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(data, type, 1, nil) {
            let options: [CFString: Any] = [kCGImageDestinationMetadata: CGImageMetadataCreateMutable(), kCGImageDestinationMergeMetadata: false,
                                            kCGImageMetadataShouldExcludeGPS: true, kCGImageMetadataShouldExcludeXMP: true]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) { return data as Data }
        }
        guard let image = upright(url) else { return nil }
        return encode(image, as: automaticFormat(for: url), quality: 0.95)
    }

    static func removeMetadata(_ url: URL, into folder: URL) -> URL? {
        guard let data = withoutMetadata(url) else { return nil }
        return write(data, named: url.lastPathComponent, into: folder)
    }

    // MARK: - Combine, zip, rename

    /// Images and PDFs, one after the other, as one PDF.
    static func combine(_ urls: [URL], named name: String, into folder: URL) -> URL? {
        guard let data = combined(urls) else { return nil }
        return write(data, named: (name.isEmpty ? "Combined" : name) + ".pdf", into: folder)
    }

    static func combined(_ urls: [URL]) -> Data? {
        let document = PDFDocument()
        for url in urls {
            if isPDF(url), let pdf = PDFDocument(url: url) {
                for index in 0..<pdf.pageCount { if let page = pdf.page(at: index) { document.insert(page, at: document.pageCount) } }
            } else if let image = upright(url) {
                let picture = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
                if let page = PDFPage(image: picture) { document.insert(page, at: document.pageCount) }
            }
        }
        return document.pageCount > 0 ? document.dataRepresentation() : nil
    }

    static func zip(_ urls: [URL], named name: String, into folder: URL) -> URL? {
        guard let made = FileActions.zip(urls, into: folder) else { return nil }
        guard !name.isEmpty else { return made }
        let renamed = made.deletingLastPathComponent().appendingPathComponent(name + ".zip")
        return (try? FileManager.default.moveItem(at: made, to: renamed)) != nil ? renamed : made
    }

    struct RenameOptions: Equatable, Sendable, Codable {
        var base = ""
        var numbered = true
        var start = 1
    }

    /// What each file is called after renaming: "Trip 1.jpg", "Trip 2.jpg"…
    static func newNames(for urls: [URL], _ options: RenameOptions) -> [String] {
        urls.enumerated().map { index, url in
            let base = options.base.isEmpty ? baseName(url) : options.base
            let number = options.numbered || urls.count > 1 ? " \(options.start + index)" : ""
            let ext = url.pathExtension
            return base + number + (ext.isEmpty ? "" : "." + ext)
        }
    }

    /// Copies under their new names (the originals can't be renamed in place from here).
    static func rename(_ urls: [URL], _ options: RenameOptions, into folder: URL) -> [URL] {
        zip2(urls, newNames(for: urls, options)).compactMap { url, name in
            let output = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? FileManager.default.copyItem(at: url, to: output)) != nil ? output : nil
        }
    }

    private static func zip2<A, B>(_ a: [A], _ b: [B]) -> Zip2Sequence<[A], [B]> { Swift.zip(a, b) }
}
