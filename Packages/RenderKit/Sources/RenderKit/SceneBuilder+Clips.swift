import CoreGraphics
import CoreMedia
import Foundation
import TimelineKit

/// What a frame looks like because of the clip it is in: a freeze frame, a title slide,
/// or the transition between two clips.
///
/// Kept apart from the builder's layers because none of it is a layer of its own: each is
/// a statement about which of the ordinary layers a frame has, and how two frames are
/// mixed. Everything is still decided here, in the one pure function both the preview and
/// the export call, so a title or a crossfade cannot look one way on screen and another in
/// the file.
extension SceneBuilder {
    /// Everything about one frame of the finished video.
    ///
    /// - Parameter track: the recorded pointer, **already smoothed**. See
    ///   `framingDescriptor(for:at:cursor:)`.
    public func descriptor(for timeline: Timeline,
                           at time: CMTime,
                           cursor track: CursorTrack? = nil) -> SceneDescriptor {
        var scene = clipDescriptor(for: timeline, at: time, cursor: track)
        guard let moment = timeline.transition(at: time) else { return scene }

        switch moment.style {
        case .dipToBlack:
            scene.blend = .dip(amount: moment.dip, toBackground: false)
        case .dipToBackground:
            scene.blend = .dip(amount: moment.dip, toBackground: true)
        case .crossfade:
            // The other side lends the frame at its edge — see `ClipTransition` for why.
            // Before the cut that is the incoming clip's first frame; after it, the
            // outgoing clip's last, a millisecond inside it so it is a frame the clip
            // shows rather than the first one it does not.
            let other = moment.isAfterCut
                ? moment.cut - CMTime(value: 1, timescale: 1_000)
                : moment.cut
            var lent = clipDescriptor(for: timeline, at: other, cursor: track)
            // The notes on the picture are this moment's, on both sides. Mixing is linear,
            // so two frames carrying the same annotation, caption and keys mix into those
            // same marks over the mixed picture — rather than a caption that arrives
            // halfway through the transition fading up from its other side.
            lent.annotations = scene.annotations
            lent.caption = scene.caption
            lent.keys = scene.keys
            scene.blend = .crossfade(lent, amount: moment.isAfterCut ? 1 - moment.progress : moment.progress)
        }
        return scene
    }

    /// The frame as its own clip draws it, before any transition mixes it with another.
    func clipDescriptor(for timeline: Timeline,
                        at time: CMTime,
                        cursor track: CursorTrack? = nil) -> SceneDescriptor {
        var scene = shapedForClip(dressedDescriptor(for: timeline, at: time, cursor: track), timeline: timeline, at: time)
        // A title holds the camera still, so nothing on it is moving to be blurred.
        if scene.title != nil { scene.cameraMotion = nil }
        return scene
    }

    /// The frame as the clip under `time` changes it.
    ///
    /// - A **freeze frame** is a photograph of the screen: the pointer stands where it
    ///   was, unsmeared, and no click is caught mid-ring — a ring frozen half-spread reads
    ///   as a rendering fault, not as a click.
    /// - A **title** shows no recording: no picture, no pointer, no clicks, no masks over
    ///   footage that is not there, no camera bubble, and the camera does not move — the
    ///   words are laid out in the frame the picture would occupy, and a zoom over them
    ///   would crop the title it was never placed on. The notes on top — annotations,
    ///   captions, keys — are the timeline's, and stay.
    func shapedForClip(_ scene: SceneDescriptor, timeline: Timeline, at time: CMTime) -> SceneDescriptor {
        guard let (_, clip, offset) = timeline.clip(at: time), !clip.isFootage else { return scene }
        var scene = scene
        scene.clicks = []
        scene.cursor?.velocity = .zero
        guard let card = clip.title else { return scene }

        scene.title = TitleLayer(card, elapsed: offset.seconds)
        scene.cursor = nil
        scene.blurs = []
        scene.webcam = nil
        scene.zoom = 1
        scene.zoomCenter = CGPoint(x: 0.5, y: 0.5)
        return scene
    }
}
