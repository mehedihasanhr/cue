import AVFoundation
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The edited sound.
///
/// Worth testing now for a reason it was not before: this is no longer only what gets
/// written at the end, it is what the editor plays and what the playhead follows. A
/// mixdown that is the wrong length no longer produces a slightly odd file — it produces
/// a preview whose picture and sound disagree.
struct AudioMixdownTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Four seconds of tone, as a file with an audio track and nothing else.
    ///
    /// `AudioMixdown` reads audio tracks from the recording's URL and does not care
    /// whether a picture came with them, so a bare audio file is a faithful stand-in and
    /// far less machinery than encoding video nobody looks at.
    private func tone(seconds: Double = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-\(UUID().uuidString).m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ])

        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            let phase: Double = 2 * Double.pi * 440 * Double(frame) / 44_100
            samples[frame] = Float(0.25 * sin(phase))
        }
        try file.write(from: buffer)
        return url
    }

    private func duration(of result: AudioMixdown.Result) async throws -> Double {
        let track = try #require(result.composition.tracks(withMediaType: .audio).first)
        return try await track.load(.timeRange).duration.seconds
    }

    @Test func theSoundIsAsLongAsTheEdit() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        let timeline = Timeline(sourceDuration: time(4))
        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)

        #expect(!result.isEmpty)
        #expect(result.composition.tracks(withMediaType: .audio).count == 1)
        #expect(abs(try await duration(of: result) - 4) < 0.1)
    }

    @Test func cuttingTheEditShortensTheSound() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        ClipSequence.split(&timeline, at: time(2))
        timeline.clips.removeLast()

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(abs(timeline.duration.seconds - 2) < 0.01, "the fixture, not the mixdown")
        #expect(abs(try await duration(of: result) - 2) < 0.1)
    }

    /// The case the preview would betray first: sped-up footage whose sound was left at
    /// its original length would run past the end of the picture.
    @Test func speedingTheEditUpShortensTheSoundToMatch() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        timeline.clips[0].speed = 2

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(abs(timeline.duration.seconds - 2) < 0.01, "the fixture, not the mixdown")
        #expect(abs(try await duration(of: result) - 2) < 0.1)
    }

    /// Timeline time is composition time, which is what lets the player's clock be read
    /// as a playhead without any mapping in between. A reordered edit is where that would
    /// break if the two were ever allowed to diverge.
    @Test func theSoundFollowsTheOrderTheClipsAreIn() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        ClipSequence.split(&timeline, at: time(1))
        timeline.clips.reverse()

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(abs(try await duration(of: result) - 4) < 0.1)
    }

    // MARK: - The recording's own level

    /// Muting must reach the exported file, not just the preview. A mute that only
    /// silenced playback would be the worst kind of bug: invisible until somebody
    /// published the video.
    @Test func mutingTheRecordingLeavesNoSoundInTheExport() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        timeline.sound.isMuted = true

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(result.isEmpty, "a muted recording should have no audio track at all")
    }

    @Test func turningTheRecordingDownIsCarriedByTheMix() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        var timeline = Timeline(sourceDuration: time(4))
        timeline.sound.gain = 0.5

        let result = await AudioMixdown.build(timeline: timeline, videoURL: url, packageURL: nil)
        #expect(!result.isEmpty)
        let mix = try #require(result.audioMix, "a level other than 1 needs a mix to carry it")
        #expect(mix.inputParameters.count == 1)
    }

    /// The ordinary case must not pay for the feature: sound left as recorded needs no
    /// mix at all, and asking AVFoundation for one would be work for nothing.
    @Test func soundLeftAloneNeedsNoMix() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await AudioMixdown.build(timeline: Timeline(sourceDuration: time(4)),
                                              videoURL: url, packageURL: nil)
        #expect(result.audioMix == nil)
    }

    /// The premise the editor's playhead now rests on: this asset can be handed to an
    /// `AVPlayer`, and the time it reports back is timeline time, moving forward.
    ///
    /// Played at zero volume, because a test suite has no business making a noise.
    @MainActor
    @Test func thePlayersClockRunsInTimelineTime() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await AudioMixdown.build(timeline: Timeline(sourceDuration: time(4)),
                                              videoURL: url, packageURL: nil)
        let item = AVPlayerItem(asset: result.composition)
        item.audioMix = result.audioMix
        let player = AVPlayer(playerItem: item)
        player.volume = 0

        player.play()
        try await Task.sleep(for: .milliseconds(700))
        let reached = player.currentTime().seconds
        player.pause()

        #expect(player.currentItem?.status == .readyToPlay)
        // Generous on both sides: the point is that it moves, and that it moves in
        // seconds of the edit rather than in some internal scale of its own.
        #expect(reached > 0.1, "the clock did not advance")
        #expect(reached < 2, "the clock advanced far faster than real time")
    }

    @Test func aSilentRecordingHasNoSoundRatherThanAnEmptyTrack() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ExportTests.writeSilentVideo(to: url, size: CGSize(width: 64, height: 64),
                                               frames: 4, frameRate: 4)

        let result = await AudioMixdown.build(timeline: Timeline(sourceDuration: time(1)),
                                              videoURL: url, packageURL: nil)
        #expect(result.isEmpty)
        #expect(result.audioMix == nil)
    }

    // MARK: - Narration laid over the edit

    /// A project package with one take in its `Audio` folder, which is where a voiceover
    /// is copied to and where the mixdown looks for it.
    private func package(holdingTakeOf seconds: Double) throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("package-\(UUID().uuidString)", isDirectory: true)
        let folder = package.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let take = try tone(seconds: seconds)
        try FileManager.default.moveItem(at: take, to: folder.appendingPathComponent("voice.m4a"))
        return package
    }

    /// Where a voiceover ends up, measured rather than assumed.
    ///
    /// This is the seam a punch-in can lie at: the region says it begins two seconds in,
    /// the editor draws it two seconds in, the document saves it two seconds in — and if
    /// the mixdown laid it at zero, everything would look right and sound wrong. The
    /// recording's own sound is muted so the only track in the composition is the take.
    @Test func aVoiceoverLandsWhereItWasPunchedIn() async throws {
        let recording = try tone()
        let package = try package(holdingTakeOf: 1)
        defer {
            try? FileManager.default.removeItem(at: recording)
            try? FileManager.default.removeItem(at: package)
        }

        var timeline = Timeline(sourceDuration: time(4))
        timeline.sound.isMuted = true
        timeline.audio = [AudioRegion(start: time(2), duration: time(1), path: "Audio/voice.m4a")]

        let result = await AudioMixdown.build(timeline: timeline, videoURL: recording, packageURL: package)
        let track = try #require(result.composition.tracks(withMediaType: .audio).first)
        let segments = try await track.load(.segments)
        let filled = try #require(segments.first { !$0.isEmpty }, "the take reached no part of the composition")
        #expect(abs(filled.timeMapping.target.start.seconds - 2) < 0.05)
        #expect(abs(filled.timeMapping.target.duration.seconds - 1) < 0.1)
    }

    /// A take that outran the edit is cut at the edit's end, and the edit does not grow to
    /// hold the rest. The arithmetic for that lives in `TimelineKit`; this is the other
    /// half of the same promise, in the asset that is actually played and written.
    @Test func aTakeTrimmedAtTheEndDoesNotLengthenTheSound() async throws {
        let recording = try tone()
        let package = try package(holdingTakeOf: 4)
        defer {
            try? FileManager.default.removeItem(at: recording)
            try? FileManager.default.removeItem(at: package)
        }

        var timeline = Timeline(sourceDuration: time(4))
        let placement = try #require(timeline.voiceoverPlacement(punchedInAt: time(3), recorded: time(4)))
        #expect(placement.wasTrimmed)
        timeline.audio = [AudioRegion(start: placement.start, duration: placement.duration,
                                      path: "Audio/voice.m4a")]

        let result = await AudioMixdown.build(timeline: timeline, videoURL: recording, packageURL: package)
        for track in result.composition.tracks(withMediaType: .audio) {
            let range = try await track.load(.timeRange)
            #expect(range.end.seconds <= 4.1, "the sound runs past the end of the edit")
        }
    }
}
