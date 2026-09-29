import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// A transparent background: see-through around the picture in the preview's frame and in
/// a file that can carry alpha, and black in one that cannot.
@Suite("Transparent background", .serialized, .timeLimit(.minutes(3)))
struct TransparentExportTests {
    private let size = CGSize(width: 320, height: 180)
    private let green = ColorValue(r: 0.1, g: 0.8, b: 0.3)

    private func timeline(seconds: Double = 1) -> Timeline {
        var timeline = Timeline(sourceDuration: DressingFixtures.time(seconds))
        timeline.style.background = .transparent
        timeline.style.padding = 0.15
        return timeline
    }

    @Test("The resolver and the renderer both leave it see-through")
    func rendered() throws {
        #expect(DefaultBackgroundResolver().layer(for: .transparent, packageURL: nil) == .transparent)

        var edit = timeline()
        edit.style.shadowOpacity = 0
        let (scene, pixels) = try DressingFixtures.render(edit, at: 0.5,
                                                          source: DressingFixtures.flat(green, size: size),
                                                          videoSize: size)
        #expect(scene.background == .transparent)
        #expect(pixels.alpha(2, 2) == 0, "the corner of the frame is nothing at all")
        #expect(pixels.alpha(pixels.width - 3, pixels.height - 3) == 0)
        #expect(pixels.alpha(pixels.width / 2, pixels.height / 2) == 1)
        #expect(pixels.isClose(pixels.width / 2, pixels.height / 2, to: green), "and the picture is the picture")
    }

    @Test("The shadow falls on nothing as a soft, part-transparent shade")
    func shadowIsPartTransparent() throws {
        var edit = timeline()
        edit.style.shadowOpacity = 0.8
        edit.style.shadowRadius = 0.03
        let (scene, pixels) = try DressingFixtures.render(edit, at: 0.5,
                                                          source: DressingFixtures.flat(green, size: size),
                                                          videoSize: size)
        // Just below the picture, where the shadow is offset towards.
        let below = Int(scene.outputSize.height - scene.videoFrame.minY) + 3
        let alpha = pixels.alpha(pixels.width / 2, below)
        #expect(alpha > 0.05 && alpha < 0.95, "the shadow is neither missing nor a solid band: \(alpha)")
    }

    private func export(_ settings: ExportSettings, name: String) async throws -> (folder: URL, file: URL) {
        let folder = try ExportTests.scratch()
        let source = folder.appendingPathComponent("source.mov")
        try await ExportTests.writeSilentVideo(to: source, size: size, frames: 30, frameRate: 30)
        var edit = timeline()
        edit.style.shadowOpacity = 0
        let exporter = VideoExporter(timeline: edit,
                                     builder: SceneBuilder(videoSize: size),
                                     cursor: nil,
                                     videoURL: source,
                                     packageURL: nil,
                                     settings: settings)
        let destination = folder.appendingPathComponent(name)
        try await exporter.export(to: destination)
        return (folder, destination)
    }

    /// Reads the first frame and one well into the file, so a buffer the encoder reuses
    /// cannot hide last frame's pixels in the see-through area.
    private func expectSeeThrough(_ file: URL) async throws {
        for seconds in [0.0, 0.7] {
            let frame = try await DressingFixtures.frame(of: file, at: seconds)
            #expect(frame.width == Int(size.width))
            #expect(frame.alpha(2, 2) < 0.02, "the corner is see-through at \(seconds)s")
            #expect(frame.alpha(frame.width - 3, frame.height / 2) < 0.02)
            #expect(frame.alpha(frame.width / 2, frame.height / 2) > 0.98, "the picture is solid at \(seconds)s")
        }
    }

    @Test("ProRes 4444 keeps the background see-through", .timeLimit(.minutes(2)))
    func proRes4444KeepsAlpha() async throws {
        let (folder, file) = try await export(ExportSettings(format: .proRes4444, frameRate: 30, includesAudio: false),
                                              name: "clear.mov")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await expectSeeThrough(file)
    }

    @Test("HEVC with transparency keeps it too", .timeLimit(.minutes(2)))
    func hevcWithAlphaKeepsAlpha() async throws {
        let (folder, file) = try await export(ExportSettings(format: .mov, frameRate: 30, codec: .hevcWithAlpha,
                                                             includesAudio: false),
                                              name: "clear-hevc.mov")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await expectSeeThrough(file)
    }

    @Test("A format with no alpha writes black there, and the picture as it is", .timeLimit(.minutes(2)))
    func h264WritesBlack() async throws {
        let (folder, file) = try await export(ExportSettings(format: .mp4, frameRate: 30, includesAudio: false),
                                              name: "flat.mp4")
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = try await DressingFixtures.frame(of: file, at: 0)
        #expect(frame.alpha(2, 2) > 0.98)
        #expect(frame.isClose(2, 2, to: .black, within: 0.08), "black where the frame was see-through")
        #expect(!frame.isClose(frame.width / 2, frame.height / 2, to: .black, within: 0.2))
    }
}
