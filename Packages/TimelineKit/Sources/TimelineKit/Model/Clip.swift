import CoreMedia
import Foundation

/// One run of the source footage, at one speed.
///
/// The model that makes the awkward cases impossible rather than merely unlikely:
///
/// - A clip stores where it starts **in the source**, never where it sits on the
///   timeline. Its timeline position is its predecessors' lengths added up, so the
///   sequence is contiguous by construction — there is no such thing as a gap to
///   normalise away, and reordering cannot invent one.
/// - `speed` is source seconds consumed per timeline second, so a 2× clip plays half as
///   long. Deriving the timeline length from the source length (rather than storing
///   both) means they can never disagree.
public struct Clip: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    /// The in-point in the recording. Trimming, reordering and speed changes never
    /// re-derive this from a new timeline position — that is how an edit stays attached
    /// to the footage it was made against.
    public var sourceStart: CMTime
    /// How much source this clip consumes.
    public var sourceDuration: CMTime
    /// Source seconds per timeline second. 1 is normal, 2 is twice as fast.
    public var speed: Double

    public init(id: UUID = UUID(), sourceStart: CMTime, sourceDuration: CMTime, speed: Double = 1) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.speed = max(Clip.minimumSpeed, min(speed, Clip.maximumSpeed))
    }

    public static let minimumSpeed = 0.25
    public static let maximumSpeed = 8.0
    /// Shorter than this and a clip is a cut, not a clip. Also what a resize stops at.
    public static let minimumDuration = CMTime(value: 1, timescale: 10)

    /// How long this clip lasts on the timeline.
    public var duration: CMTime {
        CMTimeMultiplyByFloat64(sourceDuration, multiplier: 1 / speed)
    }

    public var sourceEnd: CMTime { sourceStart + sourceDuration }

    /// Where a timeline offset inside this clip lands in the source.
    public func sourceTime(atOffset offset: CMTime) -> CMTime {
        sourceStart + CMTimeMultiplyByFloat64(offset, multiplier: speed)
    }
}
