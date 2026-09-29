import AVFoundation
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// An added sound's fades, as the mixer is told them.
struct SoundFadeMixTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A project folder holding six seconds of tone at `Audio/tone.m4a`.
    private func project() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fades-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Audio"),
                                                withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Audio/tone.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        let frames = AVAudioFrameCount(44_100 * 6)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = Float(0.25 * sin(2 * Double.pi * 440 * Double(frame) / 44_100))
        }
        try file.write(from: buffer)
        return folder
    }

    private func mix(fadeIn: Double, fadeOut: Double, gain: Double = 1) async throws -> AVAudioMixInputParameters? {
        let folder = try project()
        defer { try? FileManager.default.removeItem(at: folder) }
        var timeline = Timeline(sourceDuration: time(20))
        timeline.sound.isMuted = true
        timeline.audio = [AudioRegion(start: time(4), duration: time(6), path: "Audio/tone.m4a",
                                      gain: gain, fadeIn: fadeIn, fadeOut: fadeOut)]
        let result = await AudioMixdown.build(timeline: timeline,
                                              videoURL: URL(fileURLWithPath: "/nonexistent.mov"),
                                              packageURL: folder)
        return result.audioMix?.inputParameters.first
    }

    private func ramp(_ input: AVAudioMixInputParameters, at seconds: Double) -> (from: Float, to: Float, range: CMTimeRange)? {
        var from: Float = -1, to: Float = -1
        var range = CMTimeRange.zero
        guard input.getVolumeRamp(for: time(seconds), startVolume: &from, endVolume: &to, timeRange: &range) else {
            return nil
        }
        return (from, to, range)
    }

    @Test func aSoundWithoutFadesAtFullLevelNeedsNoMix() async throws {
        #expect(try await mix(fadeIn: 0, fadeOut: 0) == nil)
    }

    @Test func itRisesFromSilenceWhereItStarts() async throws {
        let input = try #require(try await mix(fadeIn: 2, fadeOut: 0, gain: 0.8))
        let rise = try #require(ramp(input, at: 5))
        #expect(rise.from == 0)
        #expect(abs(rise.to - 0.8) < 0.001)
        #expect(abs(rise.range.start.seconds - 4) < 0.001)
        #expect(abs(rise.range.duration.seconds - 2) < 0.001)
    }

    @Test func itFallsToSilenceWhereItEnds() async throws {
        let input = try #require(try await mix(fadeIn: 0, fadeOut: 3))
        let fall = try #require(ramp(input, at: 8))
        #expect(fall.from == 1)
        #expect(fall.to == 0)
        #expect(abs(fall.range.start.seconds - 7) < 0.001)
        #expect(abs(fall.range.end.seconds - 10) < 0.001)
    }

    @Test func fadesLongerThanTheSoundAreFittedToIt() async throws {
        let input = try #require(try await mix(fadeIn: 5, fadeOut: 5))
        let rise = try #require(ramp(input, at: 5))
        let fall = try #require(ramp(input, at: 9.5))
        #expect(abs(rise.range.duration.seconds - 5) < 0.001)
        #expect(abs(fall.range.start.seconds - 9) < 0.001, "the fall starts where the rise ends")
    }
}
