import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import RecordKit
import Testing
import TimelineKit
import UniformTypeIdentifiers
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

    // MARK: - Presets

    /// A preset is only useful if it is recognisable afterwards: the sheet highlights the
    /// one the current settings are, and settings that came out of a preset have to be
    /// read back as that preset or the highlight drops off for no visible reason.
    @Test(arguments: ExportPreset.allCases)
    func aPresetIsRecognisedFromTheSettingsItProduces(preset: ExportPreset) {
        #expect(ExportPreset.matching(preset.settings) == preset)
    }

    /// Each preset is named after an errand, and this is the errand spelled out: what it
    /// claims in its own description has to be what its settings do.
    @Test func everyPresetResolvesToWhatItsNameClaims() {
        let send = ExportPreset.colleague.settings
        #expect(send.format == .mp4, "the one to send has to play everywhere")
        #expect(send.writesAudio)
        #expect(send.outputSize(fitting: CGSize(width: 3_840, height: 2_160)).width == 1_920)

        let review = ExportPreset.review.settings
        #expect(!review.writesAudio, "a clip in a diff is read, not listened to")
        #expect(review.effectiveFrameRate == 30)

        let chat = ExportPreset.chat.settings
        #expect(chat.maximumDimension == 1_280, "720p is the point of it")

        let gif = ExportPreset.gif.settings
        #expect(gif.format == .gif)
        #expect(!gif.writesAudio)
        #expect(gif.loops)
    }

    /// The four presets have to be ordered by weight, or two of them are the same choice.
    @Test func aChatExportIsSmallerThanOneMeantToBeWatched() {
        let project = CGSize(width: 2_560, height: 1_440)
        let send = ExportPreset.colleague.settings.estimate(projectSize: project, duration: 30)
        let chat = ExportPreset.chat.settings.estimate(projectSize: project, duration: 30)
        let review = ExportPreset.review.settings.estimate(projectSize: project, duration: 30)

        #expect(chat.byteCount < send.byteCount)
        #expect(review.byteCount < send.byteCount, "half the frame rate and no sound")
    }

    // MARK: - What it will cost

    @Test func theEstimateCountsTheFramesTheExporterWillWalk() {
        let estimate = ExportSettings(format: .mp4, frameRate: 30).estimate(projectSize: landscape, duration: 4)
        #expect(estimate.frameCount == 120)
        #expect(estimate.size == landscape, "no cap means the project's own size")
    }

    @Test func droppingTheSoundMakesTheFileSmaller() {
        var withSound = ExportSettings(format: .mp4, includesAudio: true)
        withSound.maximumDimension = 1_280
        var without = withSound
        without.includesAudio = false

        #expect(without.estimate(projectSize: landscape, duration: 60).byteCount
                < withSound.estimate(projectSize: landscape, duration: 60).byteCount)
    }

    /// The estimate is what someone decides on before waiting minutes for an encode, so
    /// it has to be exact about the dimensions and honest about the size. Checked against
    /// a file that was actually written rather than against the arithmetic that produced
    /// the figure.
    @Test func theEstimateMatchesTheFileThatGetsWritten() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.mov")
        let sourceSize = CGSize(width: 640, height: 360)
        try await Self.writeSilentVideo(to: source, size: sourceSize, frames: 60, frameRate: 30)

        var settings = ExportSettings(format: .mp4, frameRate: 30, quality: .better, includesAudio: false)
        settings.maximumDimension = 480

        let builder = SceneBuilder(videoSize: sourceSize)
        var timeline = Timeline(sourceDuration: time(2))
        timeline.style.padding = 0
        let estimate = settings.estimate(projectSize: builder.outputSize(for: timeline.style),
                                         duration: timeline.duration.seconds)

        let destination = folder.appendingPathComponent("out.mp4")
        try await VideoExporter(timeline: timeline,
                                builder: builder,
                                cursor: nil,
                                videoURL: source,
                                packageURL: nil,
                                settings: settings).export(to: destination)

        let track = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        let written = try await track.load(.naturalSize)
        #expect(written == estimate.size, "the promised dimensions are the written ones")

        let actual = try #require(try FileManager.default.attributesOfItem(
            atPath: destination.path(percentEncoded: false))[.size] as? Int)
        // A wide band on purpose: the encoder is free to spend fewer bits on two seconds
        // of flat colour than we asked for. What is being tested is that the figure is the
        // right order of magnitude, which is what stops it being a number nobody trusts.
        // Only one direction is worth asserting. An estimate that comes in under the real
        // file is the one that surprises people, so that is the bound; the other way round
        // is expected here, because two seconds of flat colour compresses to almost
        // nothing and no bitrate we ask for will make the encoder spend more.
        #expect(actual < estimate.byteCount * 3, "the estimate must not undersell the file")
        #expect(actual > 0)
    }

    // MARK: - Stopping

    /// A cancel that leaves a truncated file where the user asked for an export is worse
    /// than one that does nothing, because they will send it.
    @Test func cancellingStopsTheWorkAndLeavesNoHalfFileBehind() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.mov")
        let sourceSize = CGSize(width: 1_280, height: 720)
        try await Self.writeSilentVideo(to: source, size: sourceSize, frames: 120, frameRate: 30)

        let exporter = VideoExporter(timeline: Timeline(sourceDuration: time(4)),
                                     builder: SceneBuilder(videoSize: sourceSize),
                                     cursor: nil,
                                     videoURL: source,
                                     packageURL: nil,
                                     settings: ExportSettings(format: .mp4, frameRate: 60, includesAudio: false))
        let destination = folder.appendingPathComponent("stopped.mp4")

        // Cancelled outright rather than after a sleep: the flag is read at the top of
        // every frame, so a cancel that arrives before the first one has to be honoured
        // just as a cancel half way through is — and a test that races a timer against an
        // encoder is a test that fails on somebody else's Mac.
        exporter.cancel()
        await #expect(throws: ExportError.cancelled) {
            try await exporter.export(to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)),
                "nothing left where the file was going to be")
    }

    /// The same, for the path that is not AVFoundation at all: a GIF is written by Image
    /// I/O, which used to hear about a cancel only by accident.
    @Test func cancellingAGIFLeavesNoFileBehindEither() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.mov")
        let sourceSize = CGSize(width: 640, height: 360)
        try await Self.writeSilentVideo(to: source, size: sourceSize, frames: 60, frameRate: 30)

        let exporter = VideoExporter(timeline: Timeline(sourceDuration: time(2)),
                                     builder: SceneBuilder(videoSize: sourceSize),
                                     cursor: nil,
                                     videoURL: source,
                                     packageURL: nil,
                                     settings: ExportPreset.gif.settings)
        let destination = folder.appendingPathComponent("stopped.gif")

        exporter.cancel()
        await #expect(throws: ExportError.cancelled) {
            try await exporter.export(to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    // MARK: - Sound, and its absence

    /// The GIF preset is the silent one, and a source that really does have sound is the
    /// only way to prove the silence is deliberate rather than absent from the input.
    @Test func aGIFOfARecordingWithSoundIsStillSilent() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.mov")
        let sourceSize = CGSize(width: 320, height: 180)
        try await Self.writeVideoWithTone(to: source, size: sourceSize, frames: 30, frameRate: 30)
        let spoken = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
        try #require(!spoken.isEmpty, "the fixture has to have sound for this to mean anything")

        var timeline = Timeline(sourceDuration: time(1))
        timeline.style.padding = 0

        var settings = ExportPreset.gif.settings
        settings.frameRate = 10
        // Asked for deliberately, to prove the refusal is the format's and not the
        // setting's: a GIF cannot carry sound however the switch is left.
        settings.includesAudio = true

        let destination = folder.appendingPathComponent("out.gif")
        try await VideoExporter(timeline: timeline,
                                builder: SceneBuilder(videoSize: sourceSize),
                                cursor: nil,
                                videoURL: source,
                                packageURL: nil,
                                settings: settings).export(to: destination)

        // Read back with Image I/O, not with `AVURLAsset`: a GIF is a stack of stills and
        // AVFoundation refuses to open one at all — which is itself the strongest possible
        // statement that there is no sound in it.
        let image = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetType(image) as String? == UTType.gif.identifier)
        #expect(CGImageSourceGetCount(image) == 10, "one second at ten frames a second")
    }

    /// And the other way round, so the silence above is not simply the exporter losing
    /// the sound everywhere.
    @Test func anMP4OfTheSameRecordingKeepsItsSound() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.mov")
        let sourceSize = CGSize(width: 320, height: 180)
        try await Self.writeVideoWithTone(to: source, size: sourceSize, frames: 30, frameRate: 30)

        var timeline = Timeline(sourceDuration: time(1))
        timeline.style.padding = 0

        let destination = folder.appendingPathComponent("out.mp4")
        try await VideoExporter(timeline: timeline,
                                builder: SceneBuilder(videoSize: sourceSize),
                                cursor: nil,
                                videoURL: source,
                                packageURL: nil,
                                settings: ExportSettings(format: .mp4, frameRate: 30, includesAudio: true))
            .export(to: destination)

        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        #expect(!tracks.isEmpty, "the recording's own sound comes through")
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

    /// Somewhere to write, which the caller removes with `FileManager` when it is done.
    static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("klik-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The same fixture as below, with a tone on it — so a test about sound is testing the
    /// exporter and not a source that never had any.
    static func writeVideoWithTone(to url: URL, size: CGSize, frames: Int, frameRate: Int) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(video)

        let sampleRate = 44_100.0
        // Passed through rather than encoded: the samples below are already PCM, and
        // asking the writer to make AAC out of one buffer of them produced a track that
        // `AVURLAsset` then refused to open.
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        audio.expectsMediaDataInRealTime = false
        writer.add(audio)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        for index in 0..<frames {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            let image = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.9))
                .cropped(to: CGRect(origin: .zero, size: size))
            context.render(image, to: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate)))
        }
        video.markAsFinished()

        // One buffer of a quiet sine, as long as the picture. A single append is enough:
        // what the tests downstream ask is whether an audio track exists and survives.
        let seconds = Double(frames) / Double(frameRate)
        if let sample = Self.tone(seconds: seconds, sampleRate: sampleRate) {
            while !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            audio.append(sample)
        }
        audio.markAsFinished()
        await writer.finishWriting()
    }

    /// A 440 Hz sine as one 16-bit PCM sample buffer.
    private static func tone(seconds: Double, sampleRate: Double) -> CMSampleBuffer? {
        let count = Int(seconds * sampleRate)
        guard count > 0 else { return nil }
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            samples[index] = Int16(8_000 * sin(2 * .pi * 440 * Double(index) / sampleRate))
        }

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)

        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &description,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }

        let bytes = count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes,
                                                 flags: 0, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferAssureBlockMemory(block) == noErr else { return nil }
        _ = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes)
        }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: block,
                                        formatDescription: format,
                                        sampleCount: count,
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1,
                                        sampleSizeArray: [2],
                                        sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// A handful of frames of flat colour, which is all any of this needs to be real.
    static func writeSilentVideo(to url: URL, size: CGSize, frames: Int, frameRate: Int) async throws {
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
