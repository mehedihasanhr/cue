import CoreGraphics
import CoreMedia
import Foundation
import TimelineKit

/// The picture darkened except for a soft circle round the pointer.
///
/// In the finished frame rather than in the recording's pixels, unlike the spotlight a
/// mask draws: the circle follows the pointer, and the pointer is drawn against the
/// finished frame. The centre is normalised to the picture the way the pointer's is, so
/// it moves with the camera; the radius is a share of the frame, so it does not.
public struct PointerSpotlightLayer: Equatable, Sendable {
    /// Normalised to the video, top-left origin — the pointer's own convention.
    public var center: CGPoint
    /// The clear circle's radius, as a fraction of the shorter side of the output.
    public var radius: Double
    /// How dark the rest becomes, already faded by the pointer's own fading.
    public var dimming: Double

    public init(center: CGPoint, radius: Double, dimming: Double) {
        self.center = center
        self.radius = radius
        self.dimming = dimming
    }
}

/// A round, magnified view of the recording round the pointer.
public struct PointerMagnifierLayer: Equatable, Sendable {
    /// The pointer, normalised to the video, top-left origin. The lens is centred on it
    /// unless that would put it over the edge of the frame.
    public var center: CGPoint
    /// How much bigger things are inside the lens than in the picture round it.
    public var factor: Double
    /// The lens's width, as a fraction of the shorter side of the output.
    public var diameter: Double
    /// The whole lens, faded as the pointer is.
    public var opacity: Double

    public init(center: CGPoint, factor: Double, diameter: Double, opacity: Double = 1) {
        self.center = center
        self.factor = factor
        self.diameter = diameter
        self.opacity = opacity
    }
}

extension SceneBuilder {
    /// Lays the project's pointer style, spotlight and magnifier on a described frame.
    ///
    /// After the frame is built rather than inside `cursorLayer`, so every rule that
    /// decides whether and where the pointer is drawn — hidden stretches, holds, hiding
    /// while still, the crop — is decided once, there, and this only changes what is
    /// drawn. A project with the pointer as recorded and neither effect on comes out of
    /// here untouched.
    func dressingPointer(_ scene: SceneDescriptor,
                         _ timeline: Timeline,
                         at time: CMTime,
                         sourceTime: CMTime,
                         track: CursorTrack?,
                         crop: CGRect) -> SceneDescriptor {
        var scene = scene
        let style = timeline.cursor

        if style.appearance != .asRecorded, var cursor = scene.cursor {
            if style.appearance.drawsPointer {
                cursor.appearance = style.appearance
                cursor.dotColor = style.dotColor
                // One drawing whatever the pointer turned into: the recorded picture and
                // the recorded shape are both what "as recorded" means.
                cursor.artwork = nil
                cursor.shape = .arrow
                scene.cursor = cursor
            } else {
                // No pointer; the clicks were decided separately and stay.
                scene.cursor = nil
            }
        }

        guard style.isVisible, let track, !track.isEmpty else { return scene }
        let wanted = timeline.pointerEffectPresence(at: time)
        guard wanted.spotlight > 0 || wanted.magnifier > 0 else { return scene }

        // Faded as the pointer is, so a spotlight does not go on lighting a spot the
        // pointer has left, and comes back with it. Not gated on the style: "Invisible but
        // clicks" with a spotlight is a spotlight with no pointer in it, which is a look.
        var shown = 1 - min(1, max(0, timeline.cursorOverride(at: time).hiding))
        if style.hidesWhenIdle {
            shown *= track.idleOpacity(at: sourceTime.seconds, after: style.idleDelay)
        }
        guard shown > 0.001,
              let point = pointerPoint(timeline, at: time, sourceTime: sourceTime,
                                       track: track, override: timeline.cursorOverride(at: time))
        else { return scene }
        // Held to the picture rather than dropped when the pointer leaves it, so the
        // circle waits at the edge it left by instead of vanishing and coming back.
        let position = normalisedClamped(point, crop: crop)

        let spotlight = style.spotlight
        if wanted.spotlight * shown > 0.001 {
            scene.pointerSpotlight = PointerSpotlightLayer(center: position,
                                                           radius: spotlight.radius,
                                                           dimming: spotlight.dimming * wanted.spotlight * shown)
        }
        let magnifier = style.magnifier
        if wanted.magnifier * shown > 0.001 {
            scene.pointerMagnifier = PointerMagnifierLayer(center: position,
                                                           factor: magnifier.factor,
                                                           diameter: magnifier.diameter,
                                                           opacity: wanted.magnifier * shown)
        }
        return scene
    }
}
