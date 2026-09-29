import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Freeze frames, titles and transitions, written to a file and heard in the sound.
/// Serialized and time-limited: these read and write real movies, and many decoders and
/// encoders at once — this suite in parallel with itself, beside other test runs — can
/// leave AVFoundation waiting for a frame that never comes. One at a time, and a stall
/// fails in minutes rather than hanging the run.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ClipExportTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let sourceSize = CGSize(width: 320, height: 180)

    /// The middle pixel of the frame at `seconds` of a movie, as 0…255 red, green, blue.
    private func middle(of url: URL, at seconds: Double) async throws -> (r: Int, g: Int, b: Int) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * (image.bitsPerPixel / 8)
        let info = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        // Little-endian 32-bit is BGRA in memory.
        if info == CGBitmapInfo.byteOrder32Little.rawValue {
            return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
        }
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func export(_ timeline: Timeline, from source: URL, to destination: URL) async throws {
        let exporter = VideoExporter(timeline: timeline,
                                     builder: SceneBuilder(videoSize: sourceSize),
                                     cursor: nil,
                                     videoURL: source,
                                     packageURL: nil,
                                     settings: ExportSettings(format: .mp4, frameRate: 30, includesAudio: false))
        try await exporter.export(to: destination)
    }

    /// A title first, then the recording: the title's frames carry none of the recording,
    /// and the recording's carry it, in one file written by the one exporter.
    @Test func aTitleIsWrittenWithoutTheRecordingAndTheRecordingAfterIt() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await ExportTests.writeVideoWithTone(to: source, size: sourceSize, frames: 30, frameRate: 30)

        var timeline = Timeline(sourceDuration: time(1))
        timeline.style.padding = 0
        timeline.style.background = .color(ColorValue(r: 1, g: 0, b: 0))
        _ = Commands.AddTitle(TitleCard(title: " "), at: .zero, for: time(1)).apply(to: &timeline)
        let destination = folder.appendingPathComponent("out.mp4")
        try await export(timeline, from: source, to: destination)

        let duration = try await AVURLAsset(url: destination).load(.duration)
        #expect(abs(duration.seconds - 2) < 0.1)
        let onTitle = try await middle(of: destination, at: 0.5)
        #expect(onTitle.r > 200 && onTitle.b < 60, "the background, not the recording")
        let onFootage = try await middle(of: destination, at: 1.5)
        #expect(onFootage.b > 180 && onFootage.r < 100, "the recording's blue")
    }

    /// A crossfade opens its own readers for the other side and still writes a file of the
    /// edit's length.
    @Test func aCrossfadeExportsAndIsTheLengthOfTheEdit() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await ExportTests.writeSilentVideo(to: source, size: sourceSize, frames: 60, frameRate: 30)

        var timeline = Timeline(sourceDuration: time(2))
        ClipSequence.split(&timeline, at: time(1))
        _ = ClipSequence.move(&timeline, from: 1, to: 0)
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id, to: ClipTransition(.crossfade))
        let destination = folder.appendingPathComponent("out.mp4")
        try await export(timeline, from: source, to: destination)

        let duration = try await AVURLAsset(url: destination).load(.duration)
        #expect(abs(duration.seconds - 2) < 0.1)
    }

    // MARK: - The sound

    private func tone(seconds: Double = 20) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            samples[frame] = Float(0.25 * sin(2 * Double.pi * 440 * Double(frame) / 44_100))
        }
        try file.write(from: buffer)
        return url
    }

    /// The recording's sound, as the attached track lays it, segment by segment.
    private func segments(_ result: AudioMixdown.Result, track index: Int = 0) async throws -> [AVCompositionTrackSegment] {
        let tracks = result.composition.tracks(withMediaType: .audio)
        let track = try #require(tracks.indices.contains(index) ? tracks[index] : nil)
        return track.segments
    }

    @Test func aFreezeFrameIsSilenceAndTheSoundPicksUpAfterIt() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }
        var timeline = Timeline(sourceDuration: time(20))
        ClipSequence.freeze(&timeline, at: time(5), for: time(2))

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        let segments = try await segments(result)
        let silent = segments.filter(\.isEmpty)
        #expect(silent.count == 1)
        let gap = try #require(silent.first).timeMapping.target
        #expect(abs(gap.start.seconds - 5) < 0.01)
        #expect(abs(gap.duration.seconds - 2) < 0.01)
        // After the hold, the recording carries on from five seconds in.
        let after = try #require(segments.first { !$0.isEmpty && abs($0.timeMapping.target.start.seconds - 7) < 0.01 })
        #expect(abs(after.timeMapping.source.start.seconds - 5) < 0.01)
    }

    /// Nothing is heard over a title at the end: the sound stops where the footage does.
    @Test func anEditEndingOnATitleHasNoSoundOverIt() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }
        var timeline = Timeline(sourceDuration: time(20))
        _ = Commands.AddTitle(at: timeline.duration).apply(to: &timeline)

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        let track = try #require(result.composition.tracks(withMediaType: .audio).first)
        let range = try await track.load(.timeRange)
        #expect(abs(range.end.seconds - 20) < 0.01)
    }

    /// A dip fades the sound to nothing at the cut and back.
    @Test func aDipTakesTheSoundDownAndBackUp() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }
        var timeline = Timeline(sourceDuration: time(20))
        ClipSequence.split(&timeline, at: time(10))
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id,
                                   to: ClipTransition(.dipToBlack, duration: time(1)))

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(result.composition.tracks(withMediaType: .audio).count == 1, "a dip needs no second track")
        let parameters = try #require(result.audioMix?.inputParameters.first)
        var start: Float = -1, end: Float = -1
        var range = CMTimeRange.zero
        #expect(parameters.getVolumeRamp(for: time(9.75), startVolume: &start, endVolume: &end, timeRange: &range))
        #expect(start == 1 && end == 0)
        #expect(abs(range.start.seconds - 9.5) < 0.01 && abs(range.end.seconds - 10) < 0.01)
        #expect(parameters.getVolumeRamp(for: time(10.25), startVolume: &start, endVolume: &end, timeRange: &range))
        #expect(start == 0 && end == 1)
    }

    /// A crossfade overlaps the two sides' sound: the recording just before the incoming
    /// clip, laid before the cut, and just after the outgoing one, laid after it.
    @Test func aCrossfadeOverlapsTheSoundEitherSideOfTheCut() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }
        var timeline = Timeline(sourceDuration: time(20))
        ClipSequence.split(&timeline, at: time(5))
        ClipSequence.split(&timeline, at: time(10))
        timeline.clips.remove(at: 1)                                        // 0–5, then 10–20
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id,
                                   to: ClipTransition(.crossfade, duration: time(1)))

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(result.composition.tracks(withMediaType: .audio).count == 2)
        let lent = try await segments(result, track: 1).filter { !$0.isEmpty }
        #expect(lent.count == 2)
        let before = try #require(lent.first)
        #expect(abs(before.timeMapping.target.start.seconds - 4.5) < 0.01)
        #expect(abs(before.timeMapping.source.start.seconds - 9.5) < 0.01, "from just before the incoming clip")
        let after = try #require(lent.last)
        #expect(abs(after.timeMapping.target.start.seconds - 5) < 0.01)
        #expect(abs(after.timeMapping.source.start.seconds - 5) < 0.01, "from just after the outgoing clip")

        let levels = try #require(result.audioMix?.inputParameters)
        #expect(levels.count == 2)
        var start: Float = -1, end: Float = -1
        var range = CMTimeRange.zero
        #expect(levels[0].getVolumeRamp(for: time(4.75), startVolume: &start, endVolume: &end, timeRange: &range))
        #expect(start == 1 && end == 0.5, "the outgoing sound fades to half at the cut")
        #expect(levels[1].getVolumeRamp(for: time(4.75), startVolume: &start, endVolume: &end, timeRange: &range))
        #expect(start == 0 && end == 0.5, "while the incoming rises to meet it")
    }

    /// Detached, the sound is the lane's, and a transition on the picture leaves it alone.
    @Test func aDetachedLaneIgnoresTheTransitions() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }
        var timeline = Timeline(sourceDuration: time(20))
        ClipSequence.split(&timeline, at: time(10))
        ClipSequence.setTransition(&timeline, clipID: timeline.clips[1].id, to: ClipTransition(.dipToBlack))
        ClipSequence.detachSound(&timeline)

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(result.audioMix == nil)
    }
}
