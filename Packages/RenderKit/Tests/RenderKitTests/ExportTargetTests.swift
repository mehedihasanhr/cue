import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Smaller File and size limits: what the settings work out to, and what a real encode of a
/// hard picture actually weighs.
@Suite("Exports made to a size")
struct ExportTargetTests {
    private let hd = CGSize(width: 1_920, height: 1_080)

    // MARK: - Smaller File

    @Test("Smaller File is HEVC in either container unless a codec was chosen by hand")
    func smallerIsHEVC() {
        #expect(ExportSettings(format: .mp4, quality: .smaller).videoCodec == .hevc)
        #expect(ExportSettings(format: .mov, quality: .smaller).videoCodec == .hevc)
        #expect(ExportSettings(format: .mp4, quality: .smaller, codec: .h264).videoCodec == .h264)
        #expect(ExportSettings(format: .mp4, quality: .good).videoCodec == .h264, "the other qualities are as they were")
        #expect(ExportSettings(format: .proRes422, quality: .smaller).videoCodec == .proRes422)
    }

    @Test("Smaller File is well under Good, for the bitrate and for the file")
    func smallerIsSmaller() {
        let pixels = Int(hd.width * hd.height)
        let smaller = ExportQuality.smaller.bitrate(forPixels: pixels, frameRate: 60)
        let good = ExportQuality.good.bitrate(forPixels: pixels, frameRate: 60)
        #expect(Double(smaller) < Double(good) * 0.5)
        #expect(ExportQuality.smaller.bitrate(forPixels: 100, frameRate: 1) == ExportSettings.minimumBitrate)
        let small = ExportSettings(format: .mp4, frameRate: 30, quality: .smaller).estimate(projectSize: hd, duration: 60)
        let usual = ExportSettings(format: .mp4, frameRate: 30, quality: .good).estimate(projectSize: hd, duration: 60)
        #expect(small.byteCount < usual.byteCount / 2)
        #expect(ExportQuality.allCases.first == .smaller, "first in the picker, where the smallest belongs")
    }

    /// The per-pixel figures are bits already. Divided by eight, as they once were, Good,
    /// Better and Best all landed on the 1 Mb/s floor at 1080p and looked the same.
    @Test("The qualities work out to real, distinct bitrates at 1080p")
    func qualityBitrates() {
        let pixels = Int(hd.width * hd.height)
        func mbps(_ quality: ExportQuality, _ rate: Int) -> Double {
            Double(quality.bitrate(forPixels: pixels, frameRate: rate)) / 1_000_000
        }
        #expect((2.5...3.0).contains(mbps(.smaller, 60)), "\(mbps(.smaller, 60))")
        #expect((6.0...6.5).contains(mbps(.good, 60)), "\(mbps(.good, 60))")
        #expect((11.0...11.5).contains(mbps(.better, 60)), "\(mbps(.better, 60))")
        #expect((18.5...19.0).contains(mbps(.best, 60)), "\(mbps(.best, 60))")
        #expect((3.0...3.2).contains(mbps(.good, 30)), "half the frames, half the bits: \(mbps(.good, 30))")
        // None of them is sitting on a floor at 1080p30, which is what the bug looked like.
        for quality in ExportQuality.allCases {
            #expect(quality.bitrate(forPixels: pixels, frameRate: 30) > 1_000_000, "\(quality)")
        }
        let rates = ExportQuality.allCases.map { $0.bitrate(forPixels: pixels, frameRate: 30) }
        #expect(rates == rates.sorted() && Set(rates).count == rates.count, "each quality above the last")
    }

    // MARK: - A size limit on a movie

    @Test("A limit lowers the bitrate until the file fits, sound and all")
    func limitFits() {
        var settings = ExportSettings(format: .mp4, frameRate: 60, quality: .best, maximumDimension: nil)
        settings.targetByteCount = 10_000_000
        let estimate = settings.estimate(projectSize: hd, duration: 60)
        #expect(estimate.byteCount <= 10_000_000)
        #expect(estimate.byteCount > 9_000_000, "and uses nearly all of it: \(estimate.byteCount)")
        let bitrate = settings.videoBitrate(forPixels: Int(hd.width * hd.height), frameRate: 60, duration: 60)
        // 10 MB less 60 s of 192 kbps sound, over 60 s: about 1.0 Mb/s of picture.
        #expect((900_000...1_100_000).contains(bitrate), "\(bitrate)")
    }

    @Test("A limit is a most: a short clip already under it is not made bigger")
    func limitNeverRaises() {
        var settings = ExportSettings(format: .mp4, frameRate: 30, quality: .good)
        let free = settings.videoBitrate(forPixels: Int(hd.width * hd.height), frameRate: 30, duration: 5)
        settings.targetByteCount = 100_000_000
        #expect(settings.videoBitrate(forPixels: Int(hd.width * hd.height), frameRate: 30, duration: 5) == free)
    }

    @Test("A limit nothing can meet is said to be missed rather than met with mush")
    func limitTooSmall() {
        var settings = ExportSettings(format: .mp4, frameRate: 30, quality: .good)
        settings.targetByteCount = 1_000_000
        let estimate = settings.estimate(projectSize: hd, duration: 600)
        #expect(estimate.byteCount > 1_000_000, "ten minutes will not go into one megabyte")
        #expect(settings.videoBitrate(forPixels: Int(hd.width * hd.height), frameRate: 30, duration: 600)
                == ExportSettings.minimumBitrate)
    }

    @Test("ProRes cannot be given a size, and a limit on it changes nothing")
    func proResIgnoresLimit() {
        var settings = ExportSettings(format: .proRes422, frameRate: 30)
        let before = settings.estimate(projectSize: hd, duration: 10)
        settings.targetByteCount = 8_000_000
        #expect(!settings.offersTargetSize)
        #expect(settings.estimate(projectSize: hd, duration: 10) == before)
    }

    @Test("Settings with a limit are nobody's preset")
    func limitIsNotAPreset() {
        var settings = ExportPreset.chat.settings
        #expect(ExportPreset.matching(settings) == .chat)
        settings.targetByteCount = 8_000_000
        #expect(ExportPreset.matching(settings) == nil)
    }

    // MARK: - A size limit on a GIF

    @Test("A GIF is aimed at its limit by drawing it smaller, then with fewer frames")
    func gifAimed() {
        var settings = ExportPreset.gif.settings
        settings.maximumDimension = 1_280
        settings.targetByteCount = 5_000_000
        let aimed = settings.aimedAtTarget(projectSize: hd, duration: 10)
        #expect(aimed.targetByteCount == nil)
        #expect((aimed.maximumDimension ?? .infinity) < 1_280)
        #expect(aimed.estimate(projectSize: hd, duration: 10).byteCount <= 5_000_000)
        #expect(settings.estimate(projectSize: hd, duration: 10) == aimed.estimate(projectSize: hd, duration: 10),
                "the sheet quotes what will be written")

        var long = settings
        long.targetByteCount = 2_000_000
        let slower = long.aimedAtTarget(projectSize: hd, duration: 30)
        #expect(slower.effectiveFrameRate < settings.effectiveFrameRate, "fewer frames once 320 across is not enough")
    }

    @Test("A GIF already under its limit is left as it was")
    func gifUnderLimit() {
        var settings = ExportPreset.gif.settings
        settings.targetByteCount = 100_000_000
        let aimed = settings.aimedAtTarget(projectSize: hd, duration: 2)
        #expect(aimed.maximumDimension == settings.maximumDimension)
        #expect(aimed.frameRate == settings.frameRate)
    }

    // MARK: - Real files

    /// A picture that changes completely every frame, so the encoder has to spend every bit
    /// it is allowed — a flat colour would come in far under any bitrate and prove nothing.
    static func writeNoise(to url: URL, size: CGSize, frames: Int, frameRate: Int) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000],
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
        let noise = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: .gray)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            let image = noise
                .transformed(by: CGAffineTransform(translationX: Double(index * 37 % 500), y: Double(index * 53 % 500)))
                .cropped(to: CGRect(origin: .zero, size: size))
            context.render(image, to: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate)))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    private func export(_ settings: ExportSettings, seconds: Double, from source: URL, size: CGSize,
                        into folder: URL, named name: String) async throws -> URL {
        let timeline = Timeline(sourceDuration: CMTime(seconds: seconds, preferredTimescale: 600))
        let exporter = VideoExporter(timeline: timeline,
                                     builder: SceneBuilder(videoSize: size),
                                     cursor: nil,
                                     videoURL: source,
                                     packageURL: folder,
                                     settings: settings)
        let destination = folder.appendingPathComponent("\(name).\(settings.format.fileExtension)")
        try await exporter.export(to: destination)
        return destination
    }

    private func bytes(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int)
    }

    @Test("Smaller File writes HEVC, and a smaller file than Better does", .timeLimit(.minutes(3)))
    func smallerFileOnDisk() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let size = CGSize(width: 640, height: 360)
        let source = folder.appendingPathComponent("noise.mov")
        try await Self.writeNoise(to: source, size: size, frames: 90, frameRate: 30)

        let better = try await export(ExportSettings(format: .mp4, frameRate: 30, quality: .better, includesAudio: false),
                                      seconds: 3, from: source, size: size, into: folder, named: "better")
        let smaller = try await export(ExportSettings(format: .mp4, frameRate: 30, quality: .smaller, includesAudio: false),
                                       seconds: 3, from: source, size: size, into: folder, named: "smaller")

        let track = try #require(try await AVURLAsset(url: smaller).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        let small = try bytes(smaller), usual = try bytes(better)
        #expect(small < usual * 3 / 4, "smaller \(small), better \(usual)")
    }

    @Test("A movie with a size limit comes in under it, and not far under", .timeLimit(.minutes(3)))
    func limitOnDisk() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let size = CGSize(width: 640, height: 360)
        let source = folder.appendingPathComponent("noise.mov")
        let seconds = 4.0
        try await Self.writeNoise(to: source, size: size, frames: Int(seconds) * 30, frameRate: 30)

        for format in [ExportFormat.mp4, .mov] {
            var settings = ExportSettings(format: format, frameRate: 30, quality: .best, includesAudio: false)
            settings.targetByteCount = 400_000
            let file = try await export(settings, seconds: seconds, from: source, size: size,
                                        into: folder, named: "limited-\(format.rawValue)")
            let written = try bytes(file)
            #expect(written <= 400_000, "\(format): \(written) bytes against a limit of 400,000")
            #expect(written >= 250_000, "\(format): the limit was used, not thrown away: \(written) bytes")

            // What the encoder was asked for, against what the track says it holds.
            let asked = settings.videoBitrate(forPixels: Int(size.width * size.height), frameRate: 30, duration: seconds)
            let track = try #require(try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first)
            let rate = Double(try await track.load(.estimatedDataRate))
            #expect(abs(rate - Double(asked)) / Double(asked) < 0.3, "\(format): asked \(asked) b/s, wrote \(Int(rate)) b/s")
        }
    }
}
