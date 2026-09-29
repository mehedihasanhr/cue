import Foundation

/// What to do to one source of sound, decided once before it plays.
///
/// Every number the chain needs that depends on the recording — how loud its hiss is,
/// how loud its speech is, how far to raise it — is measured beforehand and written here,
/// rather than worked out while playing. That is what lets the preview and the export
/// agree: a chain that learned the noise as it went would behave differently depending
/// on where playback started.
public struct VoiceRecipe: Equatable, Sendable {
    /// High-pass, expander and compressor.
    public var cleansVoice: Bool
    /// Decibels added before the limiter. Zero unless the volume is being evened out.
    public var gain: Double
    /// The source's hiss between words, dBFS (RMS of 20 ms). `nil` leaves the expander off,
    /// because a threshold guessed without it would either do nothing or eat quiet words.
    public var noiseFloor: Double?
    /// How loud speech typically is, dBFS (RMS of 20 ms). Sets the compressor's threshold.
    public var speechLevel: Double?
    /// Keep every sample under `VoiceChain.ceiling`.
    public var limits: Bool

    public init(cleansVoice: Bool, gain: Double = 0, noiseFloor: Double? = nil,
                speechLevel: Double? = nil, limits: Bool = true) {
        self.cleansVoice = cleansVoice
        self.gain = gain
        self.noiseFloor = noiseFloor
        self.speechLevel = speechLevel
        self.limits = limits
    }
}

/// One second-order filter section, transposed direct form II.
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// The cookbook high-pass.
    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosine = cos(w0)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + cosine) / 2 / a0, b1: -(1 + cosine) / a0, b2: (1 + cosine) / 2 / a0,
                      a1: -2 * cosine / a0, a2: (1 - alpha) / a0)
    }

    /// The two sections of a fourth-order Butterworth high-pass: 24 dB an octave, so the
    /// rumble at 40–60 Hz goes and a man's voice at 100 Hz and up is left alone.
    static func rumbleFilter(sampleRate: Double) -> [Biquad] {
        [highPass(frequency: VoiceChain.rumbleCutoff, q: 0.541_196, sampleRate: sampleRate),
         highPass(frequency: VoiceChain.rumbleCutoff, q: 1.306_563, sampleRate: sampleRate)]
    }
}

/// A voice, cleaned up and levelled, a sample at a time.
///
/// In order: a high-pass for rumble; a downward expander that turns the hiss between
/// words down by up to `expanderRange`; a light compressor over the loudest syllables;
/// the levelling gain; and a peak limiter. No look-ahead anywhere, because look-ahead is
/// delay, and a tap cannot tell the mixer its sound is late — the voice would slip behind
/// the lips by however long the limiter looked ahead.
///
/// Everything is sample by sample, so how the caller slices the buffers makes no
/// difference to what comes out. The preview's player and the exporter's reader hand
/// over different amounts at a time; the samples are the same.
public struct VoiceChain {
    public static let rumbleCutoff = 80.0
    /// The limiter's ceiling: −1 dBFS, leaving room for the encoder's own overshoot.
    public static let ceiling = pow(10, -1.0 / 20)
    /// How far above the hiss the expander opens.
    static let expanderAbove = 10.0
    /// Never closer to speech than this, so a noisy room does not get its quiet words cut.
    static let expanderBelowSpeech = 15.0
    static let expanderRatio = 3.0
    static let expanderRange = 18.0
    /// The compressor starts this far above typical speech.
    static let compressorAbove = 3.0
    static let compressorRatio = 3.0
    static let compressorKnee = 6.0

    public let recipe: VoiceRecipe
    public let sampleRate: Double
    public let channels: Int

    private var filters: [[Biquad]]
    private var power = 0.0
    private var expanderCut = 0.0
    private var compressorCut = 0.0
    private var hold = 0
    private var limiter = 1.0
    private var inputs: [Double]

    private let expanderThreshold: Double?
    private let compressorThreshold: Double
    private let powerAttack: Double, powerRelease: Double
    private let opening: Double, closing: Double, holdLength: Int
    private let squeezing: Double, letting: Double
    private let recovering: Double
    private let gain: Double

    public init(recipe: VoiceRecipe, sampleRate: Double, channels: Int) {
        self.recipe = recipe
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        filters = recipe.cleansVoice
            ? Array(repeating: Biquad.rumbleFilter(sampleRate: sampleRate), count: max(1, channels))
            : Array(repeating: [], count: max(1, channels))
        inputs = Array(repeating: 0, count: max(1, channels))

        func coefficient(_ seconds: Double) -> Double { 1 - exp(-1 / (seconds * sampleRate)) }
        powerAttack = coefficient(0.005)
        powerRelease = coefficient(0.040)
        opening = coefficient(0.003)
        closing = coefficient(0.120)
        holdLength = Int(0.060 * sampleRate)
        squeezing = coefficient(0.010)
        letting = coefficient(0.150)
        recovering = coefficient(0.080)

        let speech = recipe.speechLevel ?? -26
        if let floor = recipe.noiseFloor, floor.isFinite {
            expanderThreshold = min(floor + Self.expanderAbove, speech - Self.expanderBelowSpeech)
        } else {
            expanderThreshold = nil
        }
        compressorThreshold = speech + Self.compressorAbove
        gain = pow(10, recipe.gain / 20)
    }

    /// Whether this chain changes anything at all.
    public var isIdentity: Bool { !recipe.cleansVoice && recipe.gain == 0 && !recipe.limits }

    /// Processes `frames` samples of every channel in place. Channel `c`'s sample `i` is
    /// at `channel[c][i * stride]`: stride 1 for separate buffers per channel, the channel
    /// count for one interleaved buffer.
    public mutating func process(_ channel: [UnsafeMutablePointer<Float>], stride: Int, frames: Int) {
        let count = min(channel.count, channels)
        guard count > 0, frames > 0 else { return }
        let cleans = recipe.cleansVoice
        let limits = recipe.limits
        for i in 0..<frames {
            var squares = 0.0
            for c in 0..<count {
                var x = Double(channel[c][i * stride])
                if cleans {
                    x = filters[c][0].process(x)
                    x = filters[c][1].process(x)
                }
                inputs[c] = x
                squares += x * x
            }

            var level = gain
            if cleans {
                let heard = squares / Double(count)
                power += (heard - power) * (heard > power ? powerAttack : powerRelease)
                let decibels = 10 * log10(power + 1e-20)

                if let threshold = expanderThreshold {
                    let wanted = decibels < threshold
                        ? min(Self.expanderRange, (threshold - decibels) * (Self.expanderRatio - 1))
                        : 0
                    if decibels >= threshold { hold = holdLength }
                    if wanted < expanderCut {
                        expanderCut += (wanted - expanderCut) * opening
                    } else if hold > 0 {
                        hold -= 1
                    } else {
                        expanderCut += (wanted - expanderCut) * closing
                    }
                }

                let over = decibels - compressorThreshold
                let slope = 1 - 1 / Self.compressorRatio
                let half = Self.compressorKnee / 2
                let wanted: Double
                if over <= -half {
                    wanted = 0
                } else if over >= half {
                    wanted = over * slope
                } else {
                    wanted = slope * (over + half) * (over + half) / (2 * Self.compressorKnee)
                }
                compressorCut += (wanted - compressorCut) * (wanted > compressorCut ? squeezing : letting)

                level *= pow(10, -(expanderCut + compressorCut) / 20)
            }

            if limits {
                var peak = 0.0
                for c in 0..<count { peak = max(peak, abs(inputs[c] * level)) }
                limiter += (1 - limiter) * recovering
                if peak * limiter > Self.ceiling { limiter = Self.ceiling / peak }
                level *= limiter
            }

            for c in 0..<count {
                channel[c][i * stride] = Float(inputs[c] * level)
            }
        }
    }
}
