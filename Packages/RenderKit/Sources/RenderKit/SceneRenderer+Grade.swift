import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TimelineKit

/// Colour correction, on the recording's picture and nothing else.
extension SceneRenderer {
    /// The picture with its colour corrected.
    ///
    /// Applied inside `videoLayer`, after the picture is placed and before its corners are
    /// cut and its border and window are laid over it — so the background, the window, the
    /// border, the camera and everything written on top keep their own colours. Each step is
    /// skipped when it would change nothing, so a grade that only warms the picture costs
    /// one filter.
    func graded(_ picture: CIImage, by grade: GradeLayer) -> CIImage {
        let extent = picture.extent
        var image = picture

        if grade.brightness != 0 || grade.contrast != 0 || grade.saturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            // A quarter of the way to white at the end of the slider: Core Image's brightness
            // is an offset added to every channel, and a whole unit of it is a white frame.
            controls.brightness = Float(grade.brightness * 0.25)
            // Half as much again, or half as little, at the ends.
            controls.contrast = Float(1 + grade.contrast * 0.5)
            // Grey at one end, twice as saturated at the other.
            controls.saturation = Float(max(0, 1 + grade.saturation))
            image = controls.outputImage ?? image
        }

        if grade.temperature != 0 || grade.tint != 0 {
            let balance = CIFilter.temperatureAndTint()
            balance.inputImage = image
            // Core Image asks what the picture's white was shot at and what it should be
            // shown as. Asking for it to be shown as a higher temperature than it was shot
            // at cools it — the camera's white-balance dial, not the look of the light —
            // so warming asks for a lower one.
            balance.neutral = CIVector(x: 6_500, y: 0)
            balance.targetNeutral = CIVector(x: 6_500 - grade.temperature * 3_000, y: -grade.tint * 60)
            image = balance.outputImage ?? image
        }

        if let url = grade.lut, grade.lutIntensity > 0.001, let lut = Self.lut(at: url) {
            let cube = CIFilter.colorCubeWithColorSpace()
            cube.inputImage = image
            cube.cubeDimension = Float(lut.dimension)
            cube.cubeData = lut.data
            // A `.cube` is written for gamma-encoded sRGB values, whatever space the
            // renderer is working in.
            cube.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            // Kept to where the picture is by its own alpha, not by a crop alone. A table can
            // map black to anything, and Core Image, taking a colour table to leave clear
            // pixels clear, moves a crop inside it: outside a flat picture with square
            // corners the "nothing" came out as the table's colour for black — an inverting
            // table drew a white frame over the whole background.
            if let looked = cube.outputImage?.applyingFilter("CISourceInCompositing", parameters: [
                kCIInputBackgroundImageKey: image,
            ]) {
                if grade.lutIntensity >= 0.999 {
                    image = looked
                } else {
                    let mix = CIFilter.dissolveTransition()
                    mix.inputImage = image
                    mix.targetImage = looked
                    mix.time = Float(grade.lutIntensity)
                    image = mix.outputImage ?? looked
                }
            }
        }
        return image.cropped(to: extent)
    }

    /// Tables are read once and kept: the same file is asked for on every frame.
    private static let luts = ArtworkCache<URL, CubeLUT>(capacity: 4)

    static func lut(at url: URL) -> CubeLUT? {
        luts.value(for: url) { try? CubeLUT(contentsOf: url) }
    }
}

/// A three-dimensional colour look-up table, read from a `.cube` file.
///
/// The format every grading tool writes: a `LUT_3D_SIZE` line, then one `r g b` line per
/// entry with red changing fastest — which is exactly the order Core Image's colour cube
/// wants, so the entries go straight into its data with an alpha of one beside each.
public struct CubeLUT: Equatable, Sendable {
    public let dimension: Int
    /// Four `Float`s an entry — red, green, blue, one — ready for `CIColorCube`.
    public let data: Data

    public enum Failure: Error, LocalizedError, Equatable {
        case unreadable
        case noSize
        case oneDimensional
        case tooLarge(Int)
        case wrongCount(expected: Int, found: Int)
        case badLine(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable: "That file couldn't be read."
            case .noSize: "That isn't a .cube colour table: it doesn't say how big it is."
            case .oneDimensional: "That is a one-dimensional table. Cue Studio reads 3D .cube tables."
            case .tooLarge(let size): "That table is \(size) steps a side. Cue Studio reads tables of up to \(CubeLUT.largest)."
            case .wrongCount(let expected, let found): "That table should have \(expected) entries and has \(found)."
            case .badLine(let line): "Line \(line) of that table isn't three numbers."
            }
        }
    }

    /// Past this a table is megabytes of data for a difference nobody can see; Core Image
    /// itself stops at 128.
    public static let largest = 65

    /// Copies a `.cube` file into a project, once it is known to be one this can draw, and
    /// says where it went — relative to the package, like a background picture — and what
    /// it was called.
    ///
    /// Copied as it is, not rewritten: the file somebody graded with is the file they
    /// would expect to find in the project.
    public static func copy(_ url: URL, into packageURL: URL) throws -> LUTReference {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        _ = try CubeLUT(contentsOf: url)
        let folder = packageURL.appendingPathComponent(LUTReference.folderName, isDirectory: true)
        let name = "\(UUID().uuidString).cube"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        return LUTReference(path: "\(LUTReference.folderName)/\(name)",
                            name: url.deletingPathExtension().lastPathComponent)
    }

    public init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw Failure.unreadable }
        try self.init(parsing: text)
    }

    public init(parsing text: String) throws {
        var size: Int?
        var values: [Float] = []
        var lineNumber = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = words.first else { continue }
            switch first.uppercased() {
            case "LUT_3D_SIZE":
                guard words.count > 1, let value = Int(words[1]), value >= 2 else { throw Failure.noSize }
                guard value <= Self.largest else { throw Failure.tooLarge(value) }
                size = value
                values.reserveCapacity(value * value * value * 4)
            case "LUT_1D_SIZE":
                throw Failure.oneDimensional
            case "TITLE", "DOMAIN_MIN", "DOMAIN_MAX", "LUT_3D_INPUT_RANGE", "LUT_IN_VIDEO_RANGE", "LUT_OUT_VIDEO_RANGE":
                // Names and ranges: the ranges are 0…1 in every table anybody ships, and a
                // table written for another range is still better drawn than refused.
                continue
            default:
                guard words.count >= 3,
                      let r = Float(words[0]), let g = Float(words[1]), let b = Float(words[2])
                else {
                    // A keyword this reader has not met, before the numbers start, is
                    // skipped; a line in among the numbers that is not three of them is a
                    // broken file.
                    if values.isEmpty, Float(words[0]) == nil { continue }
                    throw Failure.badLine(lineNumber)
                }
                values.append(contentsOf: [r, g, b, 1])
            }
        }
        guard let size else { throw Failure.noSize }
        let expected = size * size * size
        guard values.count / 4 == expected else {
            throw Failure.wrongCount(expected: expected, found: values.count / 4)
        }
        dimension = size
        data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
