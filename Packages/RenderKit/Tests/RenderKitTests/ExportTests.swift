import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// Turning an edit into a file: what size it comes out, and that it comes out at all.
struct ExportTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - Sizing

    private let landscape = CGSize(width: 2_560, height: 1_440)

    @Test func withoutACapTheProjectSizeIsKept() {
        let settings = ExportSettings()
        #expect(settings.outputSize(fitting: landscape) == landscape)
    }

    @Test func aCapBringsTheLongerSideDownAndKeepsTheShape() {
        var settings = ExportSettings()
        settings.maximumDimension = 1_920
        let size = settings.outputSize(fitting: landscape)

        #expect(size.width == 1_920)
        #expect(abs(size.width / size.height - landscape.width / landscape.height) < 0.01)
    }

    /// The cap is measured against the longer side whichever way round the frame is, so
    /// "1080p" means the same thing for a vertical export as for a wide one.
    @Test func aCapOnAVerticalFrameLimitsItsHeight() {
        var settings = ExportSettings()
        settings.maximumDimension = 1_280
        let size = settings.outputSize(fitting: CGSize(width: 1_080, height: 1_920))

        #expect(size.height == 1_280)
        #expect(size.width < size.height)
    }

    @Test func anExportNeverUpscales() {
        var settings = ExportSettings()
        settings.maximumDimension = 3_840
        #expect(settings.outputSize(fitting: CGSize(width: 1_280, height: 720)) == CGSize(width: 1_280, height: 720),
                "a 4K file of a 720p recording is four times the size and not one pixel sharper")
    }

    @Test func everyExportSizeIsEven() {
        var settings = ExportSettings()
        settings.maximumDimension = 1_001
        let size = settings.outputSize(fitting: CGSize(width: 1_999, height: 1_333))
        #expect(Int(size.width) % 2 == 0, "encoders reject odd dimensions")
        #expect(Int(size.height) % 2 == 0)
    }

    // MARK: - Format

    @Test func aGIFIsNeverWrittenAtSixtyFramesASecond() {
        var settings = ExportSettings(format: .gif, frameRate: 60)
        #expect(settings.effectiveFrameRate == ExportSettings.maximumGIFFrameRate)

        settings.format = .mp4
        #expect(settings.effectiveFrameRate == 60, "a movie is left alone")
    }

    @Test func aGIFCarriesNoSound() {
        let settings = ExportSettings(format: .gif, includesAudio: true)
        #expect(!settings.writesAudio)
    }

    /// An MP4 full of HEVC is exactly the file that will not open on someone's PC.
    @Test func automaticPicksTheSafeCodecForTheContainer() {
        #expect(ExportCodec.automatic.resolved(for: .mp4) == .h264)
        #expect(ExportCodec.automatic.resolved(for: .mov) == .hevc)
        #expect(ExportCodec.hevc.resolved(for: .mp4) == .hevc, "an explicit choice is honoured")
    }

    @Test func aHigherFrameRateAsksForMoreBitrate() {
        let pixels = 1_920 * 1_080
        let thirty = ExportQuality.better.bitrate(forPixels: pixels, frameRate: 30)
        let sixty = ExportQuality.better.bitrate(forPixels: pixels, frameRate: 60)
        #expect(sixty > thirty)
        #expect(ExportQuality.best.bitrate(forPixels: pixels, frameRate: 60) > sixty)
    }

    // MARK: - End to end

    /// Writes a short silent recording, exports it, and reads the result back.
    ///
    /// The one test that proves the pieces fit: the reader decodes, the builder
    /// describes, the renderer draws and the writer encodes, in that order, against a
    /// real file rather than a mock of one.
    @Test func aRecordingGoesInAndAVideoComesOut() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("klik-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.mov")
        let sourceSize = CGSize(width: 640, height: 360)
        try await Self.writeSilentVideo(to: source, size: sourceSize, frames: 30, frameRate: 30)

        var timeline = Timeline(sourceDuration: time(1))
        timeline.style.padding = 0.08
        timeline.style.background = .color(ColorValue(r: 0.1, g: 0.1, b: 0.2))
        timeline.zooms = [ZoomRegion(start: time(0.2), duration: time(0.5), scale: 1.6)]

        var settings = ExportSettings(format: .mp4, frameRate: 30, includesAudio: false)
        settings.maximumDimension = 320

        let exporter = VideoExporter(timeline: timeline,
                                     builder: SceneBuilder(videoSize: sourceSize),
                                     cursor: nil,
                                     videoURL: source,
                                     packageURL: nil,
                                     settings: settings)
        let destination = folder.appendingPathComponent("out.mp4")
        try await exporter.export(to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))

        let result = AVURLAsset(url: destination)
        let track = try #require(try await result.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == 320, "the cap was applied")
        #expect(size.height == 180)

        let duration = try await result.load(.duration)
        #expect(abs(duration.seconds - 1) < 0.2, "as long as the timeline says")
    }

    @Test func anEmptyTimelineIsRefusedRatherThanWrittenAsAnEmptyFile() async throws {
        let exporter = VideoExporter(timeline: Timeline(sourceDuration: .zero),
                                     builder: SceneBuilder(videoSize: CGSize(width: 640, height: 360)),
                                     cursor: nil,
                                     videoURL: FileManager.default.temporaryDirectory.appendingPathComponent("nothing.mov"),
                                     packageURL: nil,
                                     settings: ExportSettings())
        await #expect(throws: ExportError.emptyTimeline) {
            try await exporter.export(to: FileManager.default.temporaryDirectory.appendingPathComponent("out.mp4"))
        }
    }

    // MARK: - A recording to work on

    /// A handful of frames of flat colour, which is all any of this needs to be real.
    private static func writeSilentVideo(to url: URL, size: CGSize, frames: Int, frameRate: Int) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }

            // A colour that changes per frame, so a test that cares which frame it got
            // has something to tell them apart by.
            let shade = Double(index) / Double(frames)
            let image = CIImage(color: CIColor(red: shade, green: 0.4, blue: 1 - shade))
                .cropped(to: CGRect(origin: .zero, size: size))
            context.render(image, to: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate)))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
