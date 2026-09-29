import Foundation

/// Integrated loudness, the way broadcasters and streaming services measure it
/// (ITU-R BS.1770): K-weighted, in 400 ms blocks, with the silences gated out.
///
/// The gating is what makes it a measure of *speech*: the absolute gate drops the
/// silence, and the relative gate drops everything more than 10 LU under the average of
/// what is left — the breaths and the room between sentences — so a talk with long pauses
/// measures as loud as the talking in it, not as loud as the talking and the pauses
/// averaged together.
public struct LoudnessMeter {
    public let sampleRate: Double
    public let channels: Int

    private var weighting: [[Biquad]]
    /// Sum over channels of the mean square, per 100 ms.
    private var quarters: [Double] = []
    private var running = 0.0
    private var filled = 0
    private let quarterLength: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        // The two stages of the K filter, designed for the rate in hand rather than the
        // standard's 48 kHz table, so a 44.1 kHz file is weighted the same way.
        weighting = Array(repeating: Self.kWeighting(sampleRate: sampleRate), count: max(1, channels))
        quarterLength = max(1, Int((sampleRate * 0.1).rounded()))
    }

    /// The standard's two stages, from their analogue prototypes: the same derivation
    /// libebur128 uses, which reproduces the standard's 48 kHz table exactly.
    static func kWeighting(sampleRate: Double) -> [Biquad] {
        var shelf = Biquad()
        do {
            let f0 = 1_681.974_450_955_533, gain = 3.999_843_853_973_347, q = 0.707_175_236_955_419_6
            let k = tan(Double.pi * f0 / sampleRate)
            let vh = pow(10, gain / 20)
            let vb = pow(vh, 0.499_666_774_154_541_6)
            let a0 = 1 + k / q + k * k
            shelf.b0 = (vh + vb * k / q + k * k) / a0
            shelf.b1 = 2 * (k * k - vh) / a0
            shelf.b2 = (vh - vb * k / q + k * k) / a0
            shelf.a1 = 2 * (k * k - 1) / a0
            shelf.a2 = (1 - k / q + k * k) / a0
        }
        var high = Biquad()
        do {
            let f0 = 38.135_470_876_024_44, q = 0.500_327_037_323_877_3
            let k = tan(Double.pi * f0 / sampleRate)
            let a0 = 1 + k / q + k * k
            high.b0 = 1
            high.b1 = -2
            high.b2 = 1
            high.a1 = 2 * (k * k - 1) / a0
            high.a2 = (1 - k / q + k * k) / a0
        }
        return [shelf, high]
    }

    /// Adds interleaved samples.
    public mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        let frames = samples.count / channels
        for i in 0..<frames {
            for c in 0..<channels {
                let y = weighting[c][1].process(weighting[c][0].process(Double(samples[i * channels + c])))
                running += y * y
            }
            filled += 1
            if filled == quarterLength {
                quarters.append(running / Double(quarterLength))
                running = 0
                filled = 0
            }
        }
    }

    /// LUFS, or `nil` when there was nothing above the absolute gate: a silent file has
    /// no loudness to bring anywhere.
    public var integrated: Double? {
        guard quarters.count >= 4 else { return nil }
        let blocks = (0...(quarters.count - 4)).map { start in
            (quarters[start] + quarters[start + 1] + quarters[start + 2] + quarters[start + 3]) / 4
        }
        func loudness(_ power: Double) -> Double { -0.691 + 10 * log10(power) }
        let audible = blocks.filter { $0 > 0 && loudness($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relative = loudness(audible.reduce(0, +) / Double(audible.count)) - 10
        let kept = audible.filter { loudness($0) > relative }
        guard !kept.isEmpty else { return nil }
        return loudness(kept.reduce(0, +) / Double(kept.count))
    }
}

/// Where "Even out volume" takes a source, and how far it may push to get there.
public enum Levelling {
    /// LUFS. Where spoken podcasts and most streaming services sit; YouTube turns down
    /// anything louder than −14, so this leaves a little room under that.
    public static let target = -16.0
    /// A source that measures very quiet is mostly noise, and raising it 40 dB would
    /// make that obvious. Past this it is only brought part of the way.
    public static let range = -20.0...24.0

    /// The gain, in decibels, that brings a source measured at `loudness` to the target.
    public static func gain(from loudness: Double?) -> Double {
        guard let loudness, loudness.isFinite else { return 0 }
        return min(max(target - loudness, range.lowerBound), range.upperBound)
    }

    /// Loudness as the finished stereo mix hears a source with `channels` channels.
    ///
    /// A mono source is played in both speakers at full level, and BS.1770 adds the
    /// channels up, so the same voice measures 3 dB louder in the video than in its file.
    public static func asHeard(_ loudness: Double?, channels: Int) -> Double? {
        guard let loudness else { return nil }
        return channels == 1 ? loudness + 10 * log10(2) : loudness
    }
}
