import CoreGraphics
import Foundation
import TimelineKit

/// A moving background at one moment.
///
/// The moment is part of the layer, so a frame's background is described completely by
/// its descriptor like everything else in it: nothing is carried from the frame before,
/// and a frame scrubbed to is drawn exactly as the same frame played to.
public struct AnimatedBackgroundLayer: Equatable, Hashable, Sendable {
    public var kind: AnimatedBackground.Kind
    public var colors: [ColorValue]
    public var speed: Double
    /// Seconds into the finished video.
    public var time: Double

    public init(kind: AnimatedBackground.Kind, colors: [ColorValue], speed: Double, time: Double) {
        self.kind = kind
        self.colors = colors
        self.speed = speed
        self.time = time
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(speed)
        hasher.combine(time)
        for colour in colors {
            hasher.combine(colour.r); hasher.combine(colour.g); hasher.combine(colour.b); hasher.combine(colour.a)
        }
    }
}

public extension BackgroundLayer {
    /// Whether this background is different on every frame, which is what decides both
    /// that it is stamped with the moment and that it is not kept between frames.
    var moves: Bool {
        switch self {
        case .animated, .video: true
        default: false
        }
    }

    /// The same background at a moment of the finished video. Every other kind of
    /// background is the same at every moment and comes back as it is.
    func at(time seconds: Double) -> BackgroundLayer {
        switch self {
        case .animated(var layer):
            layer.time = seconds
            return .animated(layer)
        case .video(let url, _):
            return .video(url: url, time: seconds)
        default:
            return self
        }
    }
}
