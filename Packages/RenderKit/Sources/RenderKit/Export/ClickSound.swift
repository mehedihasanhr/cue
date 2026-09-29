import AVFoundation
import Foundation
import TimelineKit

/// The sound of a click, made rather than recorded.
///
/// Synthesised, so it is the same on every Mac, in the preview and in every export, and
/// there is no sample file to ship or license. Each is a few tens of milliseconds: a tick
/// of filtered noise for the contact and a damped tone or two for the body, faded in over
/// half a millisecond so the start does not itself click, and faded out at the end.
public enum ClickSound {
    static let sampleRate = 48_000.0

    /// The samples, mono, peaking at about −5 dBFS.
    ///
    /// The same numbers every time: the noise is from a fixed seed, so a file made today
    /// and one made next week are the same file.
    static func samples(_ kind: CursorStyle.ClickSound) -> [Float] {
        var noise = Noise(seed: kind == .soft ? 0x5EED_0001 : 0x5EED_0002)
        let length: Double
        let parts: [(Double) -> Double]
        switch kind {
        case .soft:
            length = 0.07
            var smoothed = 0.0
            let tick: [Double] = (0..<Int(length * sampleRate)).map { _ in
                // One-pole low-pass: a thud of noise rather than a hiss.
                smoothed += 0.35 * (noise.next() - smoothed)
                return smoothed
            }
            parts = [
                { t in tick[min(tick.count - 1, Int(t * sampleRate))] * 0.9 * exp(-t / 0.003) },
                { t in 0.35 * sin(2 * .pi * 1_100 * t) * exp(-t / 0.009) },
                { t in 0.45 * sin(2 * .pi * 170 * t) * exp(-t / 0.014) },
            ]
        case .crisp:
            length = 0.05
            var previous = 0.0
            let tick: [Double] = (0..<Int(length * sampleRate)).map { _ in
                // A first difference: the noise with its low end taken out, which is the
                // snap of a plastic button rather than the thud of a trackpad.
                let value = noise.next()
                defer { previous = value }
                return (value - previous) * 0.5
            }
            parts = [
                { t in tick[min(tick.count - 1, Int(t * sampleRate))] * 1.1 * exp(-t / 0.0018) },
                { t in 0.35 * sin(2 * .pi * 3_400 * t) * exp(-t / 0.004) },
                { t in 0.25 * sin(2 * .pi * 1_900 * t) * exp(-t / 0.006) },
                // The button coming back up, quieter, a moment later.
                { t in
                    let after = t - 0.022
                    guard after >= 0 else { return 0 }
                    return tick[min(tick.count - 1, Int(t * sampleRate))] * 0.45 * exp(-after / 0.0012)
                },
            ]
        }

        let count = Int(length * sampleRate)
        let attack = 0.000_6 * sampleRate
        let release = 0.005 * sampleRate
        var raw = (0..<count).map { index -> Double in
            let t = Double(index) / sampleRate
            let value = parts.reduce(0) { $0 + $1(t) }
            let fadeIn = min(1, Double(index) / attack)
            let fadeOut = min(1, Double(count - 1 - index) / release)
            return value * fadeIn * fadeOut
        }
        let peak = raw.map(abs).max() ?? 1
        let target = 0.56
        if peak > 0 { raw = raw.map { $0 / peak * target } }
        return raw.map(Float.init)
    }

    /// Where the sounds are kept once made. Anywhere temporary will do: they are made
    /// again in a few milliseconds if the system clears it.
    public static var defaultFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KlikStudio-ClickSounds", isDirectory: true)
    }

    /// A file holding one of the sounds, made the first time it is asked for.
    ///
    /// The version in the name is the version of the recipe: change `samples(_:)` and it
    /// must go up, or a Mac that made the old sound goes on playing it.
    public static func file(for kind: CursorStyle.ClickSound, in folder: URL = defaultFolder) throws -> URL {
        let url = folder.appendingPathComponent("\(kind.rawValue)-v1.caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Written beside it and moved into place, so the preview and an export asking at
        // the same moment can never read a file that is half written.
        let draft = folder.appendingPathComponent("\(kind.rawValue)-\(UUID().uuidString).caf")
        let samples = samples(kind)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        do {
            let file = try AVAudioFile(forWriting: draft, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        do {
            try FileManager.default.moveItem(at: draft, to: url)
        } catch {
            // Somebody else got there first, with the same bytes.
            try? FileManager.default.removeItem(at: draft)
            guard FileManager.default.fileExists(atPath: url.path) else { throw error }
        }
        return url
    }

    /// A small, fast, repeatable source of noise between −1 and 1.
    private struct Noise {
        var state: UInt32

        init(seed: UInt32) { state = seed == 0 ? 1 : seed }

        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Double(state) / Double(UInt32.max) * 2 - 1
        }
    }
}
