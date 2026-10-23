import AVFoundation
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// An edit whose sound stops before its picture still exports, all of it.
/// Serialized and time-limited: these read and write real movies, and many decoders and
/// encoders at once — this suite in parallel with itself, beside other test runs — can
/// leave AVFoundation waiting for a frame that never comes. One at a time, and a stall
/// fails in minutes rather than hanging the run.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ExportSoundLengthTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Half a second of tone at `Audio/short.m4a` inside `folder`.
    private func shortSound(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Audio"),
                                                withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Audio/short.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        let frames = AVAudioFrameCount(22_050)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = Float(0.25 * sin(2 * Double.pi * 440 * Double(frame) / 44_100))
        }
        try file.write(from: buffer)
    }

    @Test(.timeLimit(.minutes(1)))
    func soundThatEndsEarlyDoesNotStopThePicture() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-short-sound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.mov")
        let size = CGSize(width: 320, height: 180)
        try await ExportTests.writeSilentVideo(to: source, size: size, frames: 90, frameRate: 30)
        try shortSound(in: folder)

        // Three seconds of picture; half a second of sound at the start of it.
        var timeline = Timeline(sourceDuration: time(3))
        timeline.audio = [AudioRegion(start: .zero, duration: time(0.5), path: "Audio/short.m4a")]
        let exporter = VideoExporter(timeline: timeline,
                                     builder: SceneBuilder(videoSize: size),
                                     cursor: nil,
                                     videoURL: source,
                                     packageURL: folder,
                                     settings: ExportSettings(format: .mp4, frameRate: 30, includesAudio: true))
        let destination = folder.appendingPathComponent("out.mp4")
        try await exporter.export(to: destination)

        let result = AVURLAsset(url: destination)
        let picture = try #require(try await result.loadTracks(withMediaType: .video).first)
        let sound = try #require(try await result.loadTracks(withMediaType: .audio).first)
        #expect(abs(try await picture.load(.timeRange).end.seconds - 3) < 0.05, "every frame was written")
        // The half second of sound, and then silence to the end, so the file's two tracks
        // are the same length. See `SoundTail`.
        #expect(abs(try await sound.load(.timeRange).end.seconds - 3) < 0.05, "and sound to the end")
    }
}
