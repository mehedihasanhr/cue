import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// Clips that play a movie brought into the project: how their frames are described, what
/// they look like, and what the export writes and sounds like.
///
/// One at a time: each writes movies, and a whole suite of encoders opened at once beside
/// every other suite's left all of them waiting on the hardware and none finishing.
@Suite(.serialized)
struct ImportedClipRenderTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - Describing the frame

    /// 1600 × 1000 at padding 0.1: the recording's frame is 1280 × 800, at (160, 100).
    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private let square = MediaFile(path: "Movies/square.mov", name: "square.mov",
                                   duration: CMTime(value: 4, timescale: 1),
                                   pixelSize: CGSize(width: 500, height: 500), hasSound: false)

    /// Ten seconds of recording with the square movie after it, from 10 s to 14 s.
    private func timeline() -> Timeline {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.style.padding = 0.1
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        timeline.cursor.smoothing = 0
        _ = Commands.AddMedia(square, at: time(10)).apply(to: &timeline)
        return timeline
    }

    /// A pointer that moves the whole time, and clicks at one second and at eleven.
    private func track() -> CursorTrack {
        let samples = stride(from: 0.0, through: 14.0, by: 0.02).map {
            CursorSample(t: $0, x: 100 + $0 * 20, y: 250, shape: .arrow)
        }
        return CursorTrack(samples: samples, input: [.mouseDown(t: 1, button: 0, x: 120, y: 250),
                                                     .mouseDown(t: 11, button: 0, x: 320, y: 250)])
    }

    @Test func aFrameOfAnImportedClipNamesItsFileAndItsMoment() {
        let builder = SceneBuilder(videoSize: videoSize)
        let scene = builder.descriptor(for: timeline(), at: time(11.5), cursor: track())
        #expect(scene.sourceMedia == square.path)
        #expect(scene.sourceTime == time(1.5))
        let recorded = builder.descriptor(for: timeline(), at: time(5), cursor: track())
        #expect(recorded.sourceMedia == nil)
        #expect(recorded.sourceTime == time(5))
    }

    /// The pointer, its clicks and the camera bubble belong to the recording. Over another
    /// file there is none of them — even at a moment whose number the pointer has samples
    /// and a click for.
    @Test func noPointerClickOrCameraIsDrawnOverAnImportedClip() {
        var timeline = timeline()
        timeline.cursor.clickHighlight = true
        timeline.webcam.isEnabled = true
        let builder = SceneBuilder(videoSize: videoSize, displayScale: 2)
        let over = builder.descriptor(for: timeline, at: time(11), cursor: track())
        #expect(over.cursor == nil)
        #expect(over.clicks.isEmpty)
        #expect(over.webcam == nil)
        let before = builder.descriptor(for: timeline, at: time(1), cursor: track())
        #expect(before.cursor != nil, "the recording still has its pointer")
        #expect(!before.clicks.isEmpty)
    }

    /// A square movie in a wide frame: as large as fits, centred, the background round it.
    @Test func anImportedPictureIsFittedIntoTheRecordingsFrame() {
        let scene = SceneBuilder(videoSize: videoSize).descriptor(for: timeline(), at: time(11))
        #expect(scene.videoFrame == CGRect(x: 400, y: 100, width: 800, height: 800))
        #expect(scene.sourceCrop == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The crop is a crop of the recording; the imported picture is shown whole, fitted into
    /// the cropped frame's place.
    @Test func theRecordingsCropIsNotAppliedToAnImportedPicture() {
        var timeline = timeline()
        timeline.style.crop = CropRect(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let builder = SceneBuilder(videoSize: videoSize)
        let recorded = builder.descriptor(for: timeline, at: time(1))
        #expect(recorded.sourceCrop.width == 0.5)
        let imported = builder.descriptor(for: timeline, at: time(11))
        #expect(imported.sourceCrop == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(abs(imported.videoFrame.width - imported.videoFrame.height) < 0.5, "still square")
    }

    @Test func aMovieOfUnknownSizeFillsTheFrameRatherThanVanishing() {
        var timeline = timeline()
        timeline.media[0].pixelSize = .zero
        let scene = SceneBuilder(videoSize: videoSize).descriptor(for: timeline, at: time(11))
        #expect(scene.videoFrame == CGRect(x: 160, y: 100, width: 1_280, height: 800))
    }

    /// Drawn by the one renderer: the picture inside its fitted frame, the background
    /// either side of it.
    @Test func theFittedPictureIsDrawnWithTheBackgroundBesideIt() throws {
        let scene = SceneBuilder(videoSize: videoSize).descriptor(for: timeline(), at: time(11))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 500, height: 500))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: red))
        let middle = try #require(pixel(image, x: 800, y: 500))
        #expect(middle.r > 200 && middle.b < 60, "the movie")
        let beside = try #require(pixel(image, x: 250, y: 500))
        #expect(beside.b > 200 && beside.r < 60, "the background, where the recording would be")
    }

    /// Each side of a crossfade names its own file.
    @Test func aCrossfadeIntoAnImportedClipLendsItsFrame() throws {
        var timeline = timeline()
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id, to: ClipTransition(.crossfade, duration: time(1)))
        let before = SceneBuilder(videoSize: videoSize).descriptor(for: timeline, at: time(9.8))
        #expect(before.sourceMedia == nil)
        let lent = try #require(before.blendedScene)
        #expect(lent.sourceMedia == square.path)
        #expect(lent.sourceTime == .zero)
    }

    private func pixel(_ image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int)? {
        let column = Int(x.rounded(.down)), row = image.height - 1 - Int(y.rounded(.down))
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              column >= 0, row >= 0, column < image.width, row < image.height else { return nil }
        let offset = row * image.bytesPerRow + column * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    // MARK: - Writing it out

    private let recordingSize = CGSize(width: 320, height: 180)
    private let moviePath = "Movies/portrait.mov"

    /// A folder standing in for a package: the recording (blue, a 440 Hz tone, one second)
    /// and a portrait movie inside it (red, 1 kHz, one second).
    private func package() async throws -> (folder: URL, recording: URL) {
        let folder = try ExportTests.scratch()
        let recording = folder.appendingPathComponent("screen.mov")
        try await ExportTests.writeVideoWithTone(to: recording, size: recordingSize, frames: 30, frameRate: 30)
        let movie = folder.appendingPathComponent(moviePath)
        try FileManager.default.createDirectory(at: movie.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await Self.writeMovie(to: movie, size: CGSize(width: 90, height: 160),
                                  colour: CIColor(red: 0.9, green: 0.1, blue: 0.1), seconds: 1, tone: 1_000)
        return (folder, recording)
    }

    private var portrait: MediaFile {
        MediaFile(path: moviePath, name: "portrait.mov", duration: time(1),
                  pixelSize: CGSize(width: 90, height: 160), hasSound: true)
    }

    /// The recording, then the movie: a green background, no padding.
    private func editWithMovieAtTheEnd() -> Timeline {
        var timeline = Timeline(sourceDuration: time(1))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.style.background = .color(ColorValue(r: 0, g: 1, b: 0))
        _ = Commands.AddMedia(portrait, at: time(1)).apply(to: &timeline)
        return timeline
    }

    private func export(_ timeline: Timeline, from recording: URL, package: URL?, to destination: URL,
                        audio: Bool = false) async throws {
        let exporter = VideoExporter(timeline: timeline,
                                     builder: SceneBuilder(videoSize: recordingSize),
                                     cursor: nil,
                                     videoURL: recording,
                                     packageURL: package,
                                     settings: ExportSettings(format: .mp4, frameRate: 30, includesAudio: audio))
        try await exporter.export(to: destination)
    }

    /// A pixel of a movie's frame, at fractions of its width and height from the top left.
    private func colour(of url: URL, at seconds: Double, x: Double = 0.5, y: Double = 0.5) async throws -> (r: Int, g: Int, b: Int) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        return try colour(of: image, x: x, y: y)
    }

    private func colour(of image: CGImage, x: Double, y: Double) throws -> (r: Int, g: Int, b: Int) {
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let column = min(image.width - 1, Int(Double(image.width) * x))
        let row = min(image.height - 1, Int(Double(image.height) * y))
        let offset = row * image.bytesPerRow + column * (image.bitsPerPixel / 8)
        let info = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        if info == CGBitmapInfo.byteOrder32Little.rawValue {
            return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
        }
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    @Test func theExportPlaysTheRecordingThenTheMovieFittedIntoItsFrame() async throws {
        let (folder, recording) = try await package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("out.mp4")
        try await export(editWithMovieAtTheEnd(), from: recording, package: folder, to: destination)

        let duration = try await AVURLAsset(url: destination).load(.duration)
        #expect(abs(duration.seconds - 2) < 0.1)
        let recorded = try await colour(of: destination, at: 0.5)
        #expect(recorded.b > 180 && recorded.r < 100, "the recording's blue")
        let movie = try await colour(of: destination, at: 1.5)
        #expect(movie.r > 180 && movie.b < 80, "the movie's red")
        // 90 × 160 fitted into 320 × 180 is about 101 wide, centred: a tenth of the way in
        // is the background.
        let beside = try await colour(of: destination, at: 1.5, x: 0.1)
        #expect(beside.g > 180 && beside.r < 80 && beside.b < 80, "the background beside the portrait movie")
    }

    /// A freeze of the imported clip holds the movie's frame, not the recording's.
    @Test func aFreezeFrameOfTheMovieExportsTheMoviesFrame() async throws {
        let (folder, recording) = try await package()
        defer { try? FileManager.default.removeItem(at: folder) }
        var timeline = editWithMovieAtTheEnd()
        #expect(ClipSequence.freeze(&timeline, at: time(1.5), for: time(1)))
        let destination = folder.appendingPathComponent("out.mp4")
        try await export(timeline, from: recording, package: folder, to: destination)

        let held = try await colour(of: destination, at: 2)
        #expect(held.r > 180 && held.b < 80, "the movie, held")
    }

    /// The still of Copy Frame and Save Frame As, in the middle of a crossfade from the
    /// recording into the movie: both pictures, mixed.
    @Test func aFrameStillInACrossfadeMixesTheRecordingWithTheMovie() async throws {
        let (folder, recording) = try await package()
        defer { try? FileManager.default.removeItem(at: folder) }
        var timeline = editWithMovieAtTheEnd()
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id, to: ClipTransition(.crossfade, duration: time(0.8)))
        let still = try await FrameStill.render(timeline, at: time(0.999), builder: SceneBuilder(videoSize: recordingSize),
                                                cursor: nil, videoURL: recording, packageURL: folder)
        let mixed = try colour(of: still, x: 0.5, y: 0.5)
        #expect(mixed.r > 70 && mixed.b > 70, "red and blue together, not one of them")
        let over = try await FrameStill.render(timeline, at: time(1.6), builder: SceneBuilder(videoSize: recordingSize),
                                               cursor: nil, videoURL: recording, packageURL: folder)
        let movie = try colour(of: over, x: 0.5, y: 0.5)
        #expect(movie.r > 180 && movie.b < 80)
    }

    @Test func aMovieMissingFromThePackageFailsTheExportAndSaysWhich() async throws {
        let (folder, recording) = try await package()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(moviePath))
        let destination = folder.appendingPathComponent("out.mp4")
        await #expect(throws: ExportError.unreadableSource("“portrait.mov” is missing from the project.")) {
            try await export(editWithMovieAtTheEnd(), from: recording, package: folder, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    // MARK: - The sound

    private let rate = SynthesisedSound.rate

    /// The recording's tone under the recording, the movie's under the movie.
    @Test func eachClipIsHeardWithItsOwnFilesSound() async throws {
        let (folder, recording) = try await package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = await AudioMixdown.build(timeline: editWithMovieAtTheEnd(), videoURL: recording, packageURL: folder)
        let mixed = try SynthesisedSound.exported(result)
        let first = SynthesisedSound.left(mixed, from: 0.2, to: 0.8)
        let second = SynthesisedSound.left(mixed, from: 1.2, to: 1.8)
        #expect(SynthesisedSound.power(at: 440, in: first) > SynthesisedSound.power(at: 1_000, in: first) + 20)
        #expect(SynthesisedSound.power(at: 1_000, in: second) > SynthesisedSound.power(at: 440, in: second) + 20,
                "the movie's own tone, and not the recording's after the cut")
    }

    /// Detaching the recording's sound leaves the movie's sound with its picture.
    @Test func aDetachedLaneLeavesTheMovieSoundingUnderItsClip() async throws {
        let (folder, recording) = try await package()
        defer { try? FileManager.default.removeItem(at: folder) }
        var timeline = editWithMovieAtTheEnd()
        ClipSequence.detachSound(&timeline)
        let result = await AudioMixdown.build(timeline: timeline, videoURL: recording, packageURL: folder)
        let mixed = try SynthesisedSound.exported(result)
        let second = SynthesisedSound.left(mixed, from: 1.2, to: 1.8)
        #expect(SynthesisedSound.rms(second) > -40)
        #expect(SynthesisedSound.power(at: 1_000, in: second) > SynthesisedSound.power(at: 440, in: second) + 20)
    }

    /// Muting the recording silences the movies in it too.
    @Test func muteSilencesTheMovieAsWell() async throws {
        let (folder, recording) = try await package()
        defer { try? FileManager.default.removeItem(at: folder) }
        var timeline = editWithMovieAtTheEnd()
        timeline.sound.isMuted = true
        let result = await AudioMixdown.build(timeline: timeline, videoURL: recording, packageURL: folder)
        #expect(result.isEmpty)
    }

    /// Sped up with its clip: two seconds of the movie's sound in one of the edit.
    @Test func theMoviesSoundIsCutAndSpedWithItsClip() async throws {
        let (folder, recording) = try await package()
        defer { try? FileManager.default.removeItem(at: folder) }
        var timeline = editWithMovieAtTheEnd()
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(1), duration: time(1)), speed: 2)
        let result = await AudioMixdown.build(timeline: timeline, videoURL: recording, packageURL: folder)
        let tracks = result.composition.tracks(withMediaType: .audio)
        let segments = tracks.flatMap(\.segments).filter { !$0.isEmpty }
        let movie = try #require(segments.first { abs($0.timeMapping.target.start.seconds - 1) < 0.01 })
        #expect(abs(movie.timeMapping.target.duration.seconds - 0.5) < 0.01)
        #expect(abs(movie.timeMapping.source.duration.seconds - 1) < 0.01)
    }

    @Test func theExportCarriesTheMoviesSound() async throws {
        let (folder, recording) = try await package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("out.mp4")
        try await export(editWithMovieAtTheEnd(), from: recording, package: folder, to: destination, audio: true)
        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        let track = try #require(tracks.first)
        let range = try await track.load(.timeRange)
        #expect(range.end.seconds > 1.8, "the sound runs on under the movie")
    }

    // MARK: - A movie to bring in

    /// A flat colour with a sine under it, which is all these need a movie to be.
    static func writeMovie(to url: URL, size: CGSize, colour: CIColor, seconds: Double,
                           frameRate: Int = 30, tone frequency: Double) async throws {
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
        // Passed through as PCM, as `ExportTests` writes its tone and for its reason.
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        audio.expectsMediaDataInRealTime = false
        writer.add(audio)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        let frames = Int(seconds * Double(frameRate))
        for index in 0..<frames {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            context.render(CIImage(color: colour).cropped(to: CGRect(origin: .zero, size: size)), to: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate)))
        }
        video.markAsFinished()

        if let sample = tone(frequency, seconds: seconds, sampleRate: 44_100) {
            while !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            audio.append(sample)
        }
        audio.markAsFinished()
        await writer.finishWriting()
    }

    private static func tone(_ frequency: Double, seconds: Double, sampleRate: Double) -> CMSampleBuffer? {
        let count = Int(seconds * sampleRate)
        guard count > 0 else { return nil }
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            samples[index] = Int16(8_000 * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        let bytes = count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr,
              let block, CMBlockBufferAssureBlockMemory(block) == noErr else { return nil }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: [2],
                                        sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
