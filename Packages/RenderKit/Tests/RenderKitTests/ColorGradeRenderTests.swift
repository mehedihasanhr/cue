import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Colour correction changes the recording, and only the recording.
///
/// Each test draws a flat-coloured recording on a flat background with a border and an
/// annotation, and reads back the middle of the picture, the background, the border and the
/// annotation — the first must change as asked and the other three must not change at all.
struct ColorGradeRenderTests {
    private let videoSize = CGSize(width: 800, height: 500)
    private let backgroundColour = ColorValue(r: 0.2, g: 0.5, b: 0.3)
    private let borderColour = ColorValue(r: 0.9, g: 0.1, b: 0.6)
    private let noteColour = ColorValue(r: 0.1, g: 0.3, b: 0.9)

    private func timeline(_ grade: ColorGrade) -> Timeline {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.style.background = .color(backgroundColour)
        timeline.style.padding = 0.1
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.style.borderWidth = 0.02
        timeline.style.borderColor = borderColour
        timeline.style.grade = grade
        timeline.cursor.isVisible = false
        timeline.annotations = [AnnotationItem(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600),
                                               kind: .rectangle,
                                               rect: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1),
                                               color: noteColour,
                                               style: AnnotationStyle(fill: .solid))]
        return timeline
    }

    private struct Reading {
        let picture: ColorValue
        let background: ColorValue
        let border: ColorValue
        let note: ColorValue
    }

    private func read(_ grade: ColorGrade, recording: ColorValue,
                      packageURL: URL? = nil) throws -> Reading {
        let builder = SceneBuilder(videoSize: videoSize, packageURL: packageURL)
        let scene = builder.descriptor(for: timeline(grade), at: CMTime(seconds: 1, preferredTimescale: 600))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: DressingFixtures.flat(recording, size: videoSize)))
        let pixels = DressingPixels(image)
        let frame = scene.videoFrame
        let top = Double(pixels.height) - frame.maxY
        return Reading(picture: pixels.colour(Int(frame.midX), Int(top + frame.height * 0.7)),
                       background: pixels.colour(4, 4),
                       // Just above the picture's top edge: the border is outside it.
                       border: pixels.colour(Int(frame.midX), Int(top - 2)),
                       note: pixels.colour(Int(0.25 * Double(pixels.width)), Int(0.25 * Double(pixels.height))))
    }

    /// The annotation as it is drawn with no grade at all — the drawing shades its fill a
    /// little, so it is compared with itself rather than with the colour it was given.
    private var drawnNote: ColorValue {
        (try? read(ColorGrade(), recording: grey).note) ?? noteColour
    }

    private func expectUntouched(_ reading: Reading, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(DressingPixels.distance(reading.background, backgroundColour) < 0.02,
                "background \(reading.background)", sourceLocation: sourceLocation)
        #expect(DressingPixels.distance(reading.border, borderColour) < 0.02,
                "border \(reading.border)", sourceLocation: sourceLocation)
        #expect(DressingPixels.distance(reading.note, drawnNote) < 0.02,
                "annotation \(reading.note)", sourceLocation: sourceLocation)
    }

    private let grey = ColorValue(r: 0.5, g: 0.5, b: 0.5)

    @Test func neutralChangesNothing() throws {
        let reading = try read(ColorGrade(), recording: grey)
        #expect(DressingPixels.distance(reading.picture, grey) < 0.02)
        expectUntouched(reading)
    }

    @Test func brightnessLightensThePictureOnly() throws {
        let reading = try read(ColorGrade(brightness: 0.6), recording: grey)
        #expect(reading.picture.r > 0.6, "\(reading.picture)")
        expectUntouched(reading)
    }

    @Test func contrastSpreadsDarkAndLight() throws {
        let dark = try read(ColorGrade(contrast: 0.8), recording: ColorValue(r: 0.25, g: 0.25, b: 0.25))
        let light = try read(ColorGrade(contrast: 0.8), recording: ColorValue(r: 0.75, g: 0.75, b: 0.75))
        #expect(dark.picture.r < 0.22, "dark got darker: \(dark.picture)")
        #expect(light.picture.r > 0.78, "light got lighter: \(light.picture)")
        expectUntouched(dark)
    }

    @Test func noSaturationIsGrey() throws {
        let reading = try read(ColorGrade(saturation: -1), recording: ColorValue(r: 0.8, g: 0.2, b: 0.2))
        let c = reading.picture
        #expect(max(c.r, c.g, c.b) - min(c.r, c.g, c.b) < 0.03, "\(c)")
        expectUntouched(reading)
    }

    @Test func warmerIsRedderAndCoolerIsBluer() throws {
        let warm = try read(ColorGrade(temperature: 0.8), recording: grey).picture
        let cool = try read(ColorGrade(temperature: -0.8), recording: grey).picture
        #expect(warm.r > warm.b + 0.05, "warm \(warm)")
        #expect(cool.b > cool.r + 0.05, "cool \(cool)")
        expectUntouched(try read(ColorGrade(temperature: 0.8), recording: grey))
    }

    @Test func tintRunsFromGreenToMagenta() throws {
        let magenta = try read(ColorGrade(tint: 0.8), recording: grey).picture
        let green = try read(ColorGrade(tint: -0.8), recording: grey).picture
        #expect(magenta.g < min(magenta.r, magenta.b) - 0.02, "magenta \(magenta)")
        #expect(green.g > max(green.r, green.b) + 0.02, "green \(green)")
    }

    // MARK: - Tables

    /// A table that turns every colour into its opposite, written as a grading tool writes
    /// one: comments, a title, the size, then red changing fastest.
    static func invertingCube(size: Int = 2) -> String {
        var lines = ["# made by a test", "TITLE \"Invert\"", "LUT_3D_SIZE \(size)", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1", ""]
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let step = Double(size - 1)
                    lines.append("\(1 - Double(r) / step) \(1 - Double(g) / step) \(1 - Double(b) / step)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func package(with cube: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("grade-\(UUID().uuidString).klikrec", isDirectory: true)
        let luts = folder.appendingPathComponent(LUTReference.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: luts, withIntermediateDirectories: true)
        try cube.write(to: luts.appendingPathComponent("invert.cube"), atomically: true, encoding: .utf8)
        return folder
    }

    /// Square corners, a flat recording and a table that turns black white: the case where
    /// Core Image once drew the table's white over the whole background. See `graded`.
    @Test func aTableIsAppliedToThePictureOnly() throws {
        let folder = try package(with: Self.invertingCube(size: 17))
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = ColorValue(r: 0.2, g: 0.4, b: 0.7)
        let lut = LUTReference(path: "\(LUTReference.folderName)/invert.cube", name: "Invert")
        let reading = try read(ColorGrade(lut: lut), recording: recording, packageURL: folder)
        #expect(DressingPixels.distance(reading.picture, ColorValue(r: 0.8, g: 0.6, b: 0.3)) < 0.03,
                "inverted: \(reading.picture)")
        expectUntouched(reading)
    }

    @Test func intensityMixesTheTableIn() throws {
        let folder = try package(with: Self.invertingCube())
        defer { try? FileManager.default.removeItem(at: folder) }
        let lut = LUTReference(path: "\(LUTReference.folderName)/invert.cube", name: "Invert")
        let recording = ColorValue(r: 0.2, g: 0.2, b: 0.2)
        let half = try read(ColorGrade(lut: lut, lutIntensity: 0.5), recording: recording, packageURL: folder).picture
        #expect(abs(half.r - 0.5) < 0.03, "halfway between 0.2 and its opposite: \(half)")
        let none = try read(ColorGrade(lut: lut, lutIntensity: 0), recording: recording, packageURL: folder).picture
        #expect(abs(none.r - 0.2) < 0.02, "no table at no intensity: \(none)")
    }

    /// A table that has gone missing leaves the picture as it was rather than breaking it.
    @Test func aMissingTableIsNoTable() throws {
        let lut = LUTReference(path: "LUTs/gone.cube", name: "Gone")
        let reading = try read(ColorGrade(lut: lut), recording: grey,
                               packageURL: FileManager.default.temporaryDirectory)
        #expect(DressingPixels.distance(reading.picture, grey) < 0.02)
    }

    // MARK: - Reading a .cube

    @Test func aCubeIsRead() throws {
        let lut = try CubeLUT(parsing: Self.invertingCube(size: 3))
        #expect(lut.dimension == 3)
        #expect(lut.data.count == 27 * 4 * MemoryLayout<Float>.size)
        let floats = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(Array(floats.prefix(4)) == [1, 1, 1, 1], "the first entry is black's, inverted")
        #expect(Array(floats[4..<8]) == [0.5, 1, 1, 1], "red changes fastest")
    }

    @Test func aBrokenCubeSaysWhy() {
        #expect(throws: CubeLUT.Failure.noSize) { try CubeLUT(parsing: "0 0 0\n1 1 1") }
        #expect(throws: CubeLUT.Failure.oneDimensional) { try CubeLUT(parsing: "LUT_1D_SIZE 2\n0 0 0\n1 1 1") }
        #expect(throws: CubeLUT.Failure.wrongCount(expected: 8, found: 2)) {
            try CubeLUT(parsing: "LUT_3D_SIZE 2\n0 0 0\n1 1 1")
        }
        #expect(throws: CubeLUT.Failure.badLine(3)) { try CubeLUT(parsing: "LUT_3D_SIZE 2\n0 0 0\n1 x 1") }
        #expect(throws: CubeLUT.Failure.tooLarge(129)) { try CubeLUT(parsing: "LUT_3D_SIZE 129") }
    }

    @Test func aTableIsCopiedIntoTheProjectOnlyIfItReads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lut-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appendingPathComponent("Teal and Orange.cube")
        try Self.invertingCube().write(to: good, atomically: true, encoding: .utf8)
        let package = folder.appendingPathComponent("Take.klikrec", isDirectory: true)
        let lut = try CubeLUT.copy(good, into: package)
        #expect(lut.name == "Teal and Orange")
        #expect(lut.path.hasPrefix("\(LUTReference.folderName)/"))
        #expect(try CubeLUT(contentsOf: package.appendingPathComponent(lut.path)).dimension == 2)

        let bad = folder.appendingPathComponent("broken.cube")
        try "LUT_1D_SIZE 2\n0 0 0\n1 1 1".write(to: bad, atomically: true, encoding: .utf8)
        #expect(throws: CubeLUT.Failure.oneDimensional) { try CubeLUT.copy(bad, into: package) }
        let kept = try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent(LUTReference.folderName).path)
        #expect(kept.count == 1, "nothing copied for the broken one")
    }

    // MARK: - The description

    @Test func theGradeIsDescribedOnlyWhenItDoesSomething() {
        let builder = SceneBuilder(videoSize: videoSize)
        let at = CMTime(seconds: 1, preferredTimescale: 600)
        #expect(builder.descriptor(for: timeline(ColorGrade()), at: at).grade == nil)
        #expect(builder.descriptor(for: timeline(ColorGrade(saturation: 0.3)), at: at).grade?.saturation == 0.3)
        // A file's out-of-range number is held to the slider's end.
        #expect(builder.descriptor(for: timeline(ColorGrade(contrast: 7)), at: at).grade?.contrast == 1)
    }

    @Test func presetsSetTheSlidersAndKeepTheTable() {
        let lut = LUTReference(path: "LUTs/a.cube", name: "A")
        let graded = ColorGrade(lut: lut, lutIntensity: 0.4).with(.mono)
        #expect(graded.saturation == -1)
        #expect(graded.lut == lut)
        #expect(graded.lutIntensity == 0.4)
        #expect(graded.preset == .mono)
        #expect(ColorGrade().preset == ColorGrade.Preset.none)
    }
}
