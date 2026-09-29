import Foundation

/// What the bar's microphone meter shows, from the levels the microphone reports.
///
/// A raw level jumps about twenty times a second and reads as flicker; a meter that is
/// only smoothed hides the one thing somebody checking a microphone wants to see, which
/// is how loud the loudest word was. So it does what a mixing desk's meter does: it rises
/// at once, falls at a steady rate, and holds its peak for a moment before letting it go.
///
/// Pure arithmetic over (level, time) pairs, so every rule here is tested without a
/// microphone.
public struct LevelMeter: Equatable, Sendable {
    /// The quietest level the meter draws; anything below is an empty meter. Sixty
    /// decibels down is below a quiet room, so a working microphone never reads as nothing.
    public static let floor: Float = -60
    /// How fast the bar falls, in fractions of its length per second: from full to empty
    /// in about two thirds of a second, which reads as the end of a word rather than as a
    /// flicker.
    public static let fallRate = 1.5
    /// How long the peak mark stays where it is.
    public static let peakHold: TimeInterval = 1.2
    /// How fast it falls afterwards.
    public static let peakFallRate = 0.8

    /// Where the bar reaches, from 0 (silent) to 1 (full scale).
    public private(set) var level: Double = 0
    /// Where the peak mark sits, on the same scale.
    public private(set) var peak: Double = 0
    private var peakAt: TimeInterval?
    private var lastUpdate: TimeInterval?

    public init() {}

    /// The meter's scale: decibels to a length. Linear in decibels, which is how loudness
    /// is heard, with the floor at zero. A missing or impossible level is silence.
    public static func fraction(forDecibels decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        let clamped = min(0, max(floor, decibels))
        return Double((clamped - floor) / -floor)
    }

    /// Takes one reading.
    public mutating func update(decibels: Float?, at time: TimeInterval) {
        let target = decibels.map(Self.fraction(forDecibels:)) ?? 0
        let elapsed = max(0, time - (lastUpdate ?? time))
        lastUpdate = time

        // Up at once, down at a steady rate.
        level = target >= level ? target : max(target, level - Self.fallRate * elapsed)

        if level >= peak {
            peak = level
            peakAt = time
        } else if let peakAt, time - peakAt > Self.peakHold {
            // Falls from where it was held, and never below the bar.
            let falling = time - peakAt - Self.peakHold
            let dropped = max(level, peak - Self.peakFallRate * min(falling, elapsed))
            peak = dropped
        }
    }

    /// Back to empty, for a microphone that has just been changed or turned off.
    public mutating func reset() {
        self = LevelMeter()
    }

    /// Whether the level is close enough to full scale to be clipping.
    public var isHot: Bool { peak >= Self.fraction(forDecibels: -3) }
}
