import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// One frame as a picture: the right size, and something in it.
struct FrameStillTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 640, height: 360)

    private func timeline() -> Timeline {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.style.padding = 0.1
        timeline.style.background = .color(ColorValue(r: 0.9, g: 0.2, b: 0.1))
        return timeline
    }

    /// A flat blue frame, standing in for the recording.
    private var source: CIImage {
        CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.9)).cropped(to: CGRect(origin: .zero, size: videoSize))
    }

    /// The pixel at a point, as red, green, blue, alpha in 0…255.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8]? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (0..<4).map { bytes[offset + $0] }
    }

    @Test func theStillIsTheProjectsOwnSizeWhenNothingCapsIt() throws {
        let scene = SceneBuilder(videoSize: videoSize).descriptor(for: timeline(), at: time(1))
        let image = try #require(FrameStill.image(for: scene, source: source))
        #expect(image.width == 640)
        #expect(image.height == 360)
    }

    @Test func theStillIsTheExportsSizeWhenTheExportIsCapped() throws {
        let scene = SceneBuilder(videoSize: videoSize).descriptor(for: timeline(), at: time(1))
        var settings = ExportSettings()
        settings.maximumDimension = 320
        let image = try #require(FrameStill.image(for: scene, source: source, fitting: settings))
        #expect(image.width == 320, "the cap the export would apply")
        #expect(image.height == 180)
    }

    /// Not empty: the background where the padding is, the recording where the picture is.
    @Test func theStillHasThePictureInIt() throws {
        let scene = SceneBuilder(videoSize: videoSize).descriptor(for: timeline(), at: time(1))
        let image = try #require(FrameStill.image(for: scene, source: source))

        let corner = try #require(pixel(image, x: 2, y: 2))
        #expect(corner[0] > 180 && corner[2] < 80, "the red background in the padding")
        let middle = try #require(pixel(image, x: image.width / 2, y: image.height / 2))
        #expect(middle[2] > 180 && middle[0] < 80, "the blue recording in the middle")
        #expect(corner[3] == 255 && middle[3] == 255, "and nothing see-through")
    }

    @Test func aStillCanBeWrittenAsAPNG() throws {
        let scene = SceneBuilder(videoSize: videoSize).descriptor(for: timeline(), at: time(1))
        let image = try #require(FrameStill.image(for: scene, source: source))
        let data = try #require(FrameStill.pngData(of: image))
        #expect(data.count > 100)
        #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47], "a PNG signature")
    }

    /// The whole errand against a real file: the frame is read from the recording at the
    /// moment asked for, and comes out at the export's size.
    @Test func aFrameIsReadFromTheRecordingAndDrawnAtExportSize() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.mov")
        try await ExportTests.writeSilentVideo(to: url, size: videoSize, frames: 30, frameRate: 30)

        var timeline = Timeline(sourceDuration: time(1))
        timeline.style.padding = 0
        var settings = ExportSettings()
        settings.maximumDimension = 320

        let image = try await FrameStill.render(timeline, at: time(0.5),
                                                builder: SceneBuilder(videoSize: videoSize),
                                                cursor: nil, videoURL: url, fitting: settings)
        #expect(image.width == 320)
        #expect(image.height == 180)
        // The fixture's colour changes frame by frame; halfway through it is mid-way from
        // blue to red, so the middle is plainly neither black nor empty.
        let middle = try #require(pixel(image, x: 160, y: 90))
        #expect(middle[3] == 255)
        #expect(middle[0] > 60 && middle[2] > 60, "the frame from the middle of the file")
    }
}
