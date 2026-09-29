import AVFoundation
import CoreMedia
import Foundation

/// What one source of sound is like, measured once from its file.
public struct SoundMeasurement: Equatable, Sendable {
    /// The hiss between words, dBFS: the quietest tenth of its 20 ms stretches, with the
    /// rumble filtered out and digital silence left out.
    public var noiseFloor: Double?
    /// How loud speech typically is, dBFS: the power average of the stretches well above
    /// the hiss.
    public var speechLevel: Double?
    /// When somebody is audibly there, in the file's own seconds.
    public var speech: [ClosedRange<Double>]
    public var channels: Int
    public var sampleRate: Double
}

/// The levelling of one source, as the Audio panel shows it.
public struct LevelReading: Equatable, Sendable {
    /// LUFS, as the finished stereo video would hear the source without levelling.
    public var measured: Double
    /// Decibels "Even out volume" adds (or takes away).
    public var gain: Double
}

/// Reads sources of sound and remembers what it found.
///
/// The mixdown asks this every time the sound is built, and the sound is built on every
/// edit that touches it, so the answer is kept: a long microphone file is decoded once per
/// session, not once per nudge of a slider. Kept by file, size and date, so a file that
/// changes on disk is measured again.
public actor SoundAnalyzer {
    public static let shared = SoundAnalyzer()

    private struct Key: Hashable {
        let path: String
        let track: Int
        let size: Int
        let modified: Date?
        let cleansVoice: Bool?
    }

    private var measurements: [Key: Task<SoundMeasurement?, Never>] = [:]
    private var loudnesses: [Key: Task<Double?, Never>] = [:]

    public init() {}

    private static func key(_ url: URL, track: Int, cleansVoice: Bool? = nil) -> Key {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Key(path: url.standardizedFileURL.path, track: track, size: values?.fileSize ?? -1,
                   modified: values?.contentModificationDate, cleansVoice: cleansVoice)
    }

    /// The noise, the speech level and when somebody speaks, for one audio track of a file.
    public func measurement(of url: URL, track: Int = 0) async -> SoundMeasurement? {
        let key = Self.key(url, track: track)
        if let task = measurements[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { await Self.measure(url, track: track) }
        measurements[key] = task
        return await task.value
    }

    /// The recipe the mixdown plays a source through, for these switches.
    public func recipe(for url: URL, track: Int = 0,
                       cleansVoice: Bool, evensVolume: Bool) async -> VoiceRecipe? {
        guard cleansVoice || evensVolume else { return nil }
        let measured = await measurement(of: url, track: track)
        var recipe = VoiceRecipe(cleansVoice: cleansVoice,
                                 noiseFloor: measured?.noiseFloor,
                                 speechLevel: measured?.speechLevel)
        if evensVolume {
            recipe.gain = await level(of: url, track: track, cleansVoice: cleansVoice)?.gain ?? 0
        }
        return recipe
    }

    /// How loud the source measures and what levelling does to it, `nil` for a silent one.
    ///
    /// Measured after the clean-up when that is on, because the clean-up changes the
    /// loudness a little and the target is for what is heard.
    public func level(of url: URL, track: Int = 0, cleansVoice: Bool) async -> LevelReading? {
        let measured = await measurement(of: url, track: track)
        let key = Self.key(url, track: track, cleansVoice: cleansVoice)
        let task: Task<Double?, Never>
        if let known = loudnesses[key] {
            task = known
        } else {
            let recipe = VoiceRecipe(cleansVoice: cleansVoice, noiseFloor: measured?.noiseFloor,
                                     speechLevel: measured?.speechLevel, limits: false)
            task = Task.detached(priority: .userInitiated) { await Self.loudness(url, track: track, recipe: recipe) }
            loudnesses[key] = task
        }
        guard let loudness = await task.value else { return nil }
        return LevelReading(measured: loudness, gain: Levelling.gain(from: loudness))
    }

    // MARK: - Reading

    /// Hands the file's samples, interleaved float, to `body` a buffer at a time.
    private static func read(_ url: URL, track index: Int,
                             _ body: (UnsafeBufferPointer<Float>, _ channels: Int, _ rate: Double) -> Void) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              tracks.indices.contains(index),
              let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }

        while let buffer = output.copyNextSampleBuffer() {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                body(UnsafeBufferPointer(start: floats, count: count),
                     Int(description.mChannelsPerFrame), description.mSampleRate)
            }
        }
        return reader.status == .completed
    }

    private static func measure(_ url: URL, track: Int) async -> SoundMeasurement? {
        var levels: [Double] = []
        var filters: [[Biquad]] = []
        var squares = 0.0
        var filled = 0
        var frameLength = 0
        var channels = 1
        var rate = 48_000.0

        let read = await read(url, track: track) { samples, count, sampleRate in
            if filters.isEmpty {
                channels = max(1, count)
                rate = sampleRate
                frameLength = max(1, Int(sampleRate * SpeechFinder.frame))
                filters = Array(repeating: Biquad.rumbleFilter(sampleRate: sampleRate), count: channels)
            }
            let frames = samples.count / channels
            for i in 0..<frames {
                for c in 0..<channels {
                    let y = filters[c][1].process(filters[c][0].process(Double(samples[i * channels + c])))
                    squares += y * y
                }
                filled += 1
                if filled == frameLength {
                    levels.append(10 * log10(squares / Double(frameLength * channels) + 1e-20))
                    squares = 0
                    filled = 0
                }
            }
        }
        guard read || !levels.isEmpty else { return nil }
        let found = SpeechFinder.find(levels)
        return SoundMeasurement(noiseFloor: found.noiseFloor, speechLevel: found.speechLevel,
                                speech: found.speech, channels: channels, sampleRate: rate)
    }

    private static func loudness(_ url: URL, track: Int, recipe: VoiceRecipe) async -> Double? {
        var meter: LoudnessMeter?
        var chain: VoiceChain?
        var scratch: [Float] = []
        _ = await read(url, track: track) { samples, channels, rate in
            if meter == nil {
                meter = LoudnessMeter(sampleRate: rate, channels: channels)
                chain = VoiceChain(recipe: recipe, sampleRate: rate, channels: channels)
            }
            scratch.removeAll(keepingCapacity: true)
            scratch.append(contentsOf: samples)
            scratch.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let pointers = (0..<channels).map { base + $0 }
                chain?.process(pointers, stride: channels, frames: buffer.count / channels)
                meter?.add(UnsafeBufferPointer(buffer))
            }
        }
        guard let meter else { return nil }
        return Levelling.asHeard(meter.integrated, channels: meter.channels)
    }
}

/// Where somebody is speaking, from how loud each 20 ms of a voice is.
///
/// Not speech recognition: a level well above the room's own hiss, held for long enough
/// to be a syllable. That is all ducking needs — music gets out of the way of a voice,
/// and a cough is short enough to be ignored.
public enum SpeechFinder {
    /// Seconds per level.
    public static let frame = 0.02
    /// How far above the hiss counts as a voice.
    static let above = 10.0
    /// Quieter than this is never a voice, however quiet the room.
    static let quietest = -60.0
    static let gap = 0.25
    static let shortest = 0.1

    public static func find(_ levels: [Double]) -> (noiseFloor: Double?, speechLevel: Double?,
                                                   speech: [ClosedRange<Double>]) {
        // Digital silence counts as the quietest a room can be rather than minus
        // infinity. A microphone that isolates the voice sends true silence between words,
        // and leaving that out made the words themselves the "floor", so nothing was ever
        // loud enough to be speech. A little padding at the start is under a tenth of the
        // file and does not move the percentile.
        let heard = levels.map { max($0, -96) }.sorted()
        guard !heard.isEmpty, heard.last ?? -96 > -96 else { return (nil, nil, []) }
        let floor = heard[min(heard.count - 1, heard.count / 10)]
        let threshold = max(floor + above, quietest)
        let loud = levels.filter { $0 >= threshold }
        let speechLevel: Double? = loud.isEmpty ? nil
            : 10 * log10(loud.map { pow(10, $0 / 10) }.reduce(0, +) / Double(loud.count))

        var stretches: [ClosedRange<Double>] = []
        var begun: Int?
        for (index, level) in levels.enumerated() {
            if level >= threshold {
                if begun == nil { begun = index }
            } else if let from = begun {
                stretches.append(Double(from) * frame...Double(index) * frame)
                begun = nil
            }
        }
        if let from = begun { stretches.append(Double(from) * frame...Double(levels.count) * frame) }

        var joined: [ClosedRange<Double>] = []
        for stretch in stretches {
            if let last = joined.last, stretch.lowerBound - last.upperBound < gap {
                joined[joined.count - 1] = last.lowerBound...stretch.upperBound
            } else {
                joined.append(stretch)
            }
        }
        return (floor, speechLevel, joined.filter { $0.upperBound - $0.lowerBound >= shortest })
    }
}
