import Foundation

/// Playing one annotation's animation on the paused picture, so a change to it can be seen
/// without playing the video.
///
/// The playhead does not move. Instead the annotation is drawn as it would be some way into
/// its own life — `offset(at:)` says how far, moment by moment — so its entrance comes in,
/// its exit goes out, or the whole chain runs, once, and then it is shown still again.
public struct AnnotationAnimationPreview: Equatable, Sendable {
    /// Which part of the chain to play.
    public enum Part: Equatable, Sendable {
        /// The way in, then a short hold at full strength.
        case entrance
        /// A short hold at full strength, then the way out, then a moment gone.
        case exit
        /// In, a hold, out, gone: the whole life of the annotation, its middle shortened.
        case chain
    }

    public let part: Part
    public let animation: AnnotationAnimation
    /// The annotation's length on the timeline, in seconds.
    public let duration: Double

    /// How long it stays at full strength between the parts.
    public static let hold = 0.5
    /// How long it stays gone after the way out, before it is shown again.
    public static let gone = 0.35

    public init(part: Part, animation: AnnotationAnimation, duration: Double) {
        self.part = part
        self.animation = animation
        self.duration = duration
    }

    /// The way in, as it is drawn: none at all, or no longer than half the annotation.
    public var inLength: Double {
        animation.entrance == .none || duration <= 0 ? 0 : min(animation.entranceDuration, duration / 2)
    }

    /// The way out, likewise.
    public var outLength: Double {
        animation.exit == .none || duration <= 0 ? 0 : min(animation.exitDuration, duration / 2)
    }

    /// Whether there is anything to play: a part that is "None" has nothing to show.
    public var hasMotion: Bool {
        switch part {
        case .entrance: inLength > 0
        case .exit: outLength > 0
        case .chain: inLength > 0 || outLength > 0
        }
    }

    /// How long the whole preview runs.
    public var length: Double {
        guard hasMotion else { return 0 }
        return switch part {
        case .entrance: inLength + Self.hold
        case .exit: Self.hold + outLength + Self.gone
        case .chain: inLength + Self.hold + outLength + Self.gone
        }
    }

    /// How far into the annotation's life to draw it, `elapsed` seconds into the preview.
    /// Nil once the preview is over.
    public func offset(at elapsed: Double) -> Double? {
        guard hasMotion, elapsed.isFinite, elapsed >= 0, elapsed < length else { return nil }
        // Where it is whole: past the way in and before the way out.
        let whole = min(inLength, duration - outLength)
        let outStart = duration - outLength
        switch part {
        case .entrance:
            return min(elapsed, whole)
        case .exit:
            return elapsed < Self.hold ? outStart : min(duration, outStart + (elapsed - Self.hold))
        case .chain:
            if elapsed < inLength { return elapsed }
            if elapsed < inLength + Self.hold { return whole }
            return min(duration, outStart + (elapsed - inLength - Self.hold))
        }
    }
}
