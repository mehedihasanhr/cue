import AVFoundation
import CoreMedia
import Foundation
import TimelineKit
@testable import RenderKit

/// Sound made in code for the voice and ducking tests, and the means of measuring what
/// the mixdown makes of it. Nothing here touches a microphone or a speaker.
enum SynthesisedSound {
    static let rate = 48_000.0

    /// A word: a buzz at `pitch` with its first eight harmonics, rising and falling like a
    /// syllable. What a voice looks like to a level meter, without anybody talking.
    static func voice(_ samples: inout [Float], from: Double, to: Double, amplitude: Double,
                      pitch: Double = 150, syllables: Bool = true) {
        let first = max(0, Int(from * rate)), last = min(samples.count, Int(to * rate))
        guard last > first else { return }
        for i in first..<last {
            let t = Double(i) / rate
            let into = t - from, length = to - from
            // Rise and fall over the word, with a syllable's wobble on top.
            let edge = min(1, min(into, length - into) / 0.03)
            let wobble = syllables ? 0.75 + 0.25 * sin(2 * .pi * 4 * into) : 1
            var value = 0.0
            for harmonic in 1...8 {
                value += sin(2 * .pi * pitch * Double(harmonic) * t) / Double(harmonic)
            }
            samples[i] += Float(amplitude * edge * wobble * value / 2.2)
        }
    }

    static func tone(_ samples: inout [Float], frequency: Double, amplitude: Double,
                     from: Double = 0, to: Double = .infinity) {
        let first = max(0, Int(from * rate)), last = min(samples.count, Int(min(to, 1e6) * rate))
        guard last > first else { return }
        for i in first..<last {
            samples[i] += Float(amplitude * sin(2 * .pi * frequency * Double(i) / rate))
        }
    }

    /// White noise of a given RMS, the same every run.
    static func hiss(_ samples: inout [Float], rms: Double, seed: UInt64 = 0x5EED) {
        var state = seed
        let scale = rms * sqrt(3.0)
        for i in samples.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53) * 2 - 1
            samples[i] += Float(scale * unit)
        }
    }

    /// Mono 32-bit float WAV: exact samples and no encoder delay, so a time in the test is
    /// a time in the file.
    static func write(_ samples: [Float], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stereo 48 kHz float, interleaved, read exactly the way the exporter reads it.
    static func exported(_ result: AudioMixdown.Result) throws -> [Float] {
        guard let (_, reader, output) = try VideoExporter.audioPath(for: result) else { return [] }
        return drain(reader, output)
    }

    /// The same, read from the player item the preview plays.
    @MainActor
    static func previewed(_ result: AudioMixdown.Result) async throws -> [Float] {
        let item = result.playerItem()
        let reader = try AVAssetReader(asset: item.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: try await item.asset.loadTracks(withMediaType: .audio),
                                                 audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.audioMix = item.audioMix
        reader.add(output)
        return drain(reader, output)
    }

    private static func drain(_ reader: AVAssetReader, _ output: AVAssetReaderOutput) -> [Float] {
        guard reader.startReading() else { return [] }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: bytes.baseAddress!)
            }
            samples += chunk
        }
        return samples
    }

    /// The left channel between two times, from interleaved stereo.
    static func left(_ stereo: [Float], from: Double, to: Double) -> [Float] {
        let first = Int(from * rate), last = min(stereo.count / 2, Int(to * rate))
        guard last > first else { return [] }
        return (first..<last).map { stereo[$0 * 2] }
    }

    static func decibels(_ power: Double) -> Double { 10 * log10(max(power, 1e-20)) }

    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -200 }
        return decibels(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }

    /// The power at one frequency, in decibels: a Goertzel filter over the window.
    static func power(at frequency: Double, in samples: [Float]) -> Double {
        let k = 2 * cos(2 * .pi * frequency / rate)
        var s1 = 0.0, s2 = 0.0
        for sample in samples {
            let s0 = Double(sample) + k * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - k * s1 * s2
        return decibels(power / Double(max(1, samples.count * samples.count)))
    }

    static func loudness(ofStereo samples: [Float]) -> Double? {
        var meter = LoudnessMeter(sampleRate: rate, channels: 2)
        samples.withUnsafeBufferPointer { meter.add($0) }
        return meter.integrated
    }

    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
}
