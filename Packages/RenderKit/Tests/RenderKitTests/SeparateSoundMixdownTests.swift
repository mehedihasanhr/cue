import AVFoundation
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The edit's sound when the recording captured its sources separately.
///
/// The bug this feature exists to fix is one mix: turning the screen's sound down took the
/// voiceover with it, because both were one undifferentiated soundtrack. These pin down
/// that a level set on one source reaches that source's file and no other — and that a
/// recording made before the separation still sounds exactly as it did.
struct SeparateSoundMixdownTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A throwaway package with some tones in it, standing in for a `.klikrec`.
    ///
    /// The mixdown only ever resolves `packageURL + track.path` and opens the result, so a
    /// folder of audio files is a faithful stand-in and far less machinery than a real
    /// recording.
    private func package(files: [String], seconds: Double = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("media"),
                                                withIntermediateDirectories: true)
        for file in files {
            try writeTone(to: url.appendingPathComponent(file), seconds: seconds)
        }
        return url
    }

    private func writeTone(to url: URL, seconds: Double) throws {
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
            samples[frame] = Float(0.25 * sin(2 * Double.pi * 440 * Double(frame) / 44_100))
        }
        try file.write(from: buffer)
    }

    private func timeline(_ tracks: [SoundTrack]) -> Timeline {
        Timeline(sourceDuration: time(4), soundTracks: tracks)
    }

    private func screen(_ style: SoundStyle = SoundStyle()) -> SoundTrack {
        SoundTrack(source: .systemAudio, path: "media/system-audio.m4a", style: style)
    }

    private func voice(_ style: SoundStyle = SoundStyle()) -> SoundTrack {
        SoundTrack(source: .microphone, name: "Shure MV7", path: "media/microphone-1.m4a", style: style)
    }

    private let files = ["media/system-audio.m4a", "media/microphone-1.m4a"]

    /// The volume the mix will play one composition track at, or `nil` when it was left
    /// at its recorded level.
    private func volumes(_ result: AudioMixdown.Result) -> [Float] {
        (result.audioMix?.inputParameters ?? []).compactMap { parameters in
            var start: Float = 0
            var end: Float = 0
            var range = CMTimeRange.zero
            guard parameters.getVolumeRamp(for: .zero, startVolume: &start,
                                           endVolume: &end, timeRange: &range) else { return nil }
            return start
        }
    }

    // MARK: -

    @Test func everySourceGetsItsOwnTrackInTheMix() async throws {
        let url = try package(files: files)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await AudioMixdown.build(timeline: timeline([screen(), voice()]),
                                              videoURL: url.appendingPathComponent("media/screen.mov"),
                                              packageURL: url)

        #expect(result.composition.tracks(withMediaType: .audio).count == 2)
        #expect(result.audioMix == nil, "nothing was re-levelled, so there is nothing to mix")
    }

    /// The whole feature, as one assertion: the screen goes quiet and the voice does not.
    @Test func mutingOneSourceLeavesTheOtherInTheMix() async throws {
        let url = try package(files: files)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await AudioMixdown.build(
            timeline: timeline([screen(SoundStyle(isMuted: true)), voice()]),
            videoURL: url.appendingPathComponent("media/screen.mov"),
            packageURL: url)

        #expect(result.composition.tracks(withMediaType: .audio).count == 1,
                "a muted source costs no decoding and no space")
        #expect(abs(try await length(of: result) - 4) < 0.1, "and the voice is all of it")
    }

    @Test func eachSourceIsPlayedAtItsOwnLevel() async throws {
        let url = try package(files: files)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await AudioMixdown.build(
            timeline: timeline([screen(SoundStyle(gain: 0.25)), voice(SoundStyle(gain: 1.5))]),
            videoURL: url.appendingPathComponent("media/screen.mov"),
            packageURL: url)

        #expect(volumes(result).sorted() == [0.25, 1.5])
    }

    /// The master still means what it always meant.
    @Test func theMasterLevelMultipliesEverySource() async throws {
        let url = try package(files: files)
        defer { try? FileManager.default.removeItem(at: url) }

        var edit = timeline([screen(SoundStyle(gain: 0.5)), voice()])
        edit.sound.gain = 0.5
        let result = await AudioMixdown.build(timeline: edit,
                                              videoURL: url.appendingPathComponent("media/screen.mov"),
                                              packageURL: url)

        #expect(volumes(result).sorted() == [0.25, 0.5])
    }

    @Test func mutingTheRecordingSilencesEverySource() async throws {
        let url = try package(files: files)
        defer { try? FileManager.default.removeItem(at: url) }

        var edit = timeline([screen(), voice()])
        edit.sound.isMuted = true
        let result = await AudioMixdown.build(timeline: edit,
                                              videoURL: url.appendingPathComponent("media/screen.mov"),
                                              packageURL: url)
        #expect(result.isEmpty)
    }

    /// A source whose file has been deleted out of the package costs that lane and nothing
    /// else — the export is not failed over it.
    @Test func aMissingSourceFileLosesOnlyItsOwnLane() async throws {
        let url = try package(files: ["media/microphone-1.m4a"])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await AudioMixdown.build(timeline: timeline([screen(), voice()]),
                                              videoURL: url.appendingPathComponent("media/screen.mov"),
                                              packageURL: url)
        #expect(result.composition.tracks(withMediaType: .audio).count == 1)
    }

    /// Cuts still cut every source together, because they are one take on one clock.
    @Test func cuttingTheEditShortensEverySource() async throws {
        let url = try package(files: files)
        defer { try? FileManager.default.removeItem(at: url) }

        var edit = timeline([screen(), voice()])
        ClipSequence.split(&edit, at: time(2))
        edit.clips.removeLast()

        let result = await AudioMixdown.build(timeline: edit,
                                              videoURL: url.appendingPathComponent("media/screen.mov"),
                                              packageURL: url)
        #expect(result.composition.tracks(withMediaType: .audio).count == 2)
        for track in result.composition.tracks(withMediaType: .audio) {
            #expect(abs(try await track.load(.timeRange).duration.seconds - 2) < 0.1)
        }
    }

    /// The compatibility case: a recording whose sound is inside its video file names no
    /// sources, and every note of it is laid down from there as before.
    @Test func aRecordingWithNoSeparateSourcesStillPlaysFromItsVideoFile() async throws {
        // Named `.m4a` only because that is what the fixture can write; what matters is
        // that `videoURL` is where the sound is, which is what an older package looks like.
        let url = try package(files: ["media/screen.m4a"])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await AudioMixdown.build(timeline: timeline([]),
                                              videoURL: url.appendingPathComponent("media/screen.m4a"),
                                              packageURL: url)
        #expect(result.composition.tracks(withMediaType: .audio).count == 1)
    }

    private func length(of result: AudioMixdown.Result) async throws -> Double {
        let track = try #require(result.composition.tracks(withMediaType: .audio).first)
        return try await track.load(.timeRange).duration.seconds
    }
}
