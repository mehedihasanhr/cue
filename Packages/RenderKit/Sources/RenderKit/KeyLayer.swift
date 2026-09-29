import CoreGraphics
import CoreMedia
import Foundation
import TimelineKit

/// The keys being pressed, drawn in the finished frame.
///
/// Placed by the renderer rather than carrying a rectangle, for the reason a caption is:
/// the keys sit in the same place every time and take the width the shortcut needs.
/// Everything here is normalised or a name, so the layer needs nothing done to it when
/// the preview describes a smaller frame — see `SceneDescriptor.scaled(by:)`.
public struct KeyLayer: Equatable, Sendable {
    /// What is printed on each key, in reading order: "⌘", "⇧", "K".
    public var caps: [String]
    /// How many times in a row it was pressed. Drawn only when more than once.
    public var count: Int
    public var look: KeyStyle.Look
    public var position: KeyStyle.Position
    /// The height of a key, as a fraction of the shorter side of the output.
    public var size: Double
    public var opacity: Double
    /// How big the keys are drawn, 1 being their own size. Other than 1 only while they
    /// are arriving.
    public var scale: Double
    /// The lines of caption that are on screen at some point while these keys are, on
    /// the same edge.
    ///
    /// The renderer keeps the keys clear of every one of them for the whole time the keys
    /// are up — not only of the line showing at this instant — so the keys do not jump
    /// when a line arrives or goes under them.
    public var clears: [CaptionLayer]

    public init(caps: [String],
                count: Int = 1,
                look: KeyStyle.Look = .keycaps,
                position: KeyStyle.Position = .bottomCenter,
                size: Double = 0.07,
                opacity: Double = 1,
                scale: Double = 1,
                clears: [CaptionLayer] = []) {
        self.caps = caps
        self.count = count
        self.look = look
        self.position = position
        self.size = size
        self.opacity = opacity
        self.scale = scale
        self.clears = clears
    }
}

extension SceneBuilder {
    /// The keys on screen at this moment, if any are.
    ///
    /// `Timeline.keyCue(at:)` decides which press is showing — hidden ones, named keys the
    /// style has switched off and overlaps are all its business — so the preview and the
    /// export cannot disagree about it. What is left here is how far it has arrived, and
    /// which captions it has to stay clear of.
    func keyLayer(_ timeline: Timeline, at time: CMTime) -> KeyLayer? {
        guard let cue = timeline.keyCue(at: time) else { return nil }
        let style = timeline.keyStyle.sanitised
        let length = cue.duration.seconds
        let elapsed = max(0, min(length, (time - cue.start).seconds))
        let pose = Self.keyPose(elapsed: elapsed, remaining: length - elapsed, length: length)
        guard pose.opacity > 0.001 else { return nil }

        return KeyLayer(caps: cue.caps,
                        count: cue.count,
                        look: style.look,
                        position: style.position,
                        size: style.size,
                        opacity: max(0, min(1, pose.opacity)),
                        scale: pose.scale,
                        clears: captionsSharingTheEdge(timeline, with: cue, position: style.position))
    }

    /// How the keys are drawn a moment after they arrive and a moment before they go.
    ///
    /// The same shape as `captionPose`, so the two overlays move alike: a short fade at
    /// each end, and on the way in a little small and settling to size. Nothing on the
    /// way out but the fade — see `captionPose` for why.
    static func keyPose(elapsed: Double, remaining: Double, length: Double) -> (opacity: Double, scale: Double) {
        let fade = min(0.12, length / 4)
        let opacity = fade > 0 ? min(1, min(elapsed, remaining) / fade) : 1
        let arrival = min(0.18, length / 3)
        let arrived = arrival > 0 ? min(1, max(0, elapsed / arrival)) : 1
        let eased = 1 - pow(1 - arrived, 3)
        return (opacity, 0.9 + 0.1 * eased)
    }

    /// The captions the keys have to stay clear of: the ones on the same edge that are on
    /// screen at any point while this press is.
    ///
    /// Judged over the press's whole span rather than at this frame, so the answer — and
    /// so the keys' place — is the same for every frame of the press.
    private func captionsSharingTheEdge(_ timeline: Timeline, with cue: KeyCue,
                                        position: KeyStyle.Position) -> [CaptionLayer] {
        let style = timeline.captionStyle
        guard style.isVisible, (style.position == .top) == position.isTop else { return [] }
        return timeline.captions.compactMap { line in
            guard line.start < cue.end, cue.start < line.end,
                  !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CaptionLayer(text: line.text,
                                fontSize: style.fontSize,
                                color: style.color,
                                backgroundOpacity: style.backgroundOpacity,
                                position: style.position,
                                margin: style.margin,
                                typeface: style.typeface,
                                fontFamily: style.fontFamily)
        }
    }
}
