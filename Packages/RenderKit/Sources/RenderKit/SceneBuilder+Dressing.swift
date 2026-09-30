import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import TimelineKit

extension SceneBuilder {
    /// Everything about one frame of the finished video.
    ///
    /// The frame `framingDescriptor(for:at:cursor:)` describes, dressed: the window drawn
    /// round the picture, sized to the room that framing already made for it, and the
    /// smear of the camera's movement, read off the same camera path the frame is framed
    /// by. Both are worked out from the described frame rather than alongside it, so
    /// neither can disagree with where the picture actually is.
    ///
    /// - Parameter track: the recorded pointer, **already smoothed** — see
    ///   `framingDescriptor(for:at:cursor:)`.
    func dressedDescriptor(for timeline: Timeline,
                           at time: CMTime,
                           cursor track: CursorTrack? = nil) -> SceneDescriptor {
        var scene = framingDescriptor(for: timeline, at: time, cursor: track)
        let picture = min(scene.videoFrame.width, scene.videoFrame.height)
        scene.chrome = chromeLayer(timeline.style,
                                   barHeight: SceneRenderer.barFraction(for: timeline.style.chrome.kind) * picture)
        // Held the way the framing held it — against the recording's cropped shape, not
        // this frame's picture — so a clip imported at another shape sits in the same
        // handset rather than turning it on its side mid-video.
        scene.device = DeviceLayer(timeline.style.chrome, pictureSize: croppedVideoSize(for: timeline.style))
        if scene.device != nil {
            // The handset is the frame. A line drawn inside the picture's edge, inside the
            // screen, would be a second frame round nothing.
            scene.border = nil
        }
        scene.cameraMotion = cameraMotion(timeline, at: time, cursor: track, crop: scene.sourceCrop,
                                          current: (scene.zoom, scene.zoomCenter),
                                          videoFrame: scene.videoFrame, output: scene.outputSize)
        // The perspective, the colour and a moving background's moment — see
        // `dressingLook(_:_:at:)`.
        return dressingLook(scene, timeline, at: time)
    }

    /// The window round the picture, or `nil` when the style has none.
    ///
    /// `barHeight` is the room `framingDescriptor(for:at:cursor:)` has already made above
    /// the picture, so the bar is drawn into exactly that space.
    func chromeLayer(_ style: FrameStyle, barHeight: Double) -> ChromeLayer? {
        guard style.chrome.isVisible, !style.chrome.kind.isDevice, barHeight > 0 else { return nil }
        return ChromeLayer(kind: style.chrome.kind, appearance: style.chrome.appearance, barHeight: barHeight)
    }

    // MARK: - Camera motion

    /// How long the shutter is taken to be open, in seconds.
    ///
    /// Half a frame at 60 fps — what a film camera's usual half-open shutter gives. Enough
    /// to be felt in a fast push-in and to vanish in a slow one, which is the point: the
    /// blur should read as the camera moving, never as the picture going soft.
    static let shutter = 1.0 / 120

    /// How far either side of the frame the camera is looked at to find its speed.
    ///
    /// A `CMTime` rather than seconds, so the moments either side are exact: an excerpt's
    /// frame and the same frame of the whole video must be framed identically, and a
    /// probe that went through floating point landed a hair apart in the two.
    static let motionProbe = CMTime(value: 1, timescale: 240)

    /// The most the picture is streaked, however fast the camera goes: a fraction of the
    /// frame's shorter side for a pan, and of the picture's size for a push. Past these a
    /// flick of the camera would smear the picture beyond reading.
    static let maximumTravel = 0.03
    static let maximumGrowth = 0.03

    /// How the camera is moving at `time`, as the smear a shutter would catch, or `nil`
    /// when motion blur is off or the camera is still.
    ///
    /// Read off the camera's own path a moment either side of this frame — the same
    /// `camera(for:at:)` the frame itself is framed by, so the blur follows exactly the
    /// movement that is drawn, pointer following and glides included. Nothing is carried
    /// from one frame to the next, so a frame scrubbed to is blurred exactly as the same
    /// frame played to.
    ///
    /// A cut is not a movement. An instant zoom jumps between two frames, and so does a
    /// camera following the pointer across a cut in the footage; measured across the jump
    /// either looks like the fastest move there is. A real movement changes smoothly, so
    /// the picture moves about as far just before this frame as just after it — a side on
    /// which it leaps several times further than on the other is a jump, and is left out.
    func cameraMotion(_ timeline: Timeline,
                      at time: CMTime,
                      cursor track: CursorTrack?,
                      crop: CGRect,
                      current: (zoom: Double, center: CGPoint),
                      videoFrame: CGRect,
                      output: CGSize) -> CameraMotionLayer? {
        guard timeline.camera.motionBlur, videoFrame.width > 0, videoFrame.height > 0 else { return nil }
        let earlier = max(.zero, time - Self.motionProbe)
        let later = min(timeline.duration, time + Self.motionProbe)
        // Only near a zoom, or while the whole video is held zoomed in and the camera pans
        // throughout, or while a loop is bringing the camera home: everywhere else the
        // camera is at rest by definition, and this costs two more framings of the frame.
        let moves = timeline.camera.holdsWholeVideoZoomed
            || (timeline.cursor.loop.bringsCameraBack && timeline.pointerLoopBlend(at: later) > 0)
            || timeline.zooms.contains(where: { $0.start <= later && $0.end >= earlier })
        guard moves else { return nil }

        func frame(_ camera: (zoom: Double, center: CGPoint)) -> CGRect {
            let size = CGSize(width: videoFrame.width * camera.zoom, height: videoFrame.height * camera.zoom)
            return CGRect(x: videoFrame.midX - camera.center.x * size.width,
                          y: videoFrame.midY - (1 - camera.center.y) * size.height,
                          width: size.width, height: size.height)
        }
        func framed(at moment: CMTime) -> CGRect {
            frame(camera(for: timeline, at: moment, cursor: track, crop: crop))
        }
        let now = frame(current)
        let before = earlier < time ? framed(at: earlier) : now
        let after = later > time ? framed(at: later) : now

        // Each side's change: how far the middle moved and how much wider it got.
        func change(from a: CGRect, to b: CGRect) -> (dx: Double, dy: Double, dw: Double) {
            (b.midX - a.midX, b.midY - a.midY, b.width - a.width)
        }
        let shorter = min(output.width, output.height)
        func size(_ step: (dx: Double, dy: Double, dw: Double)) -> Double {
            max(abs(step.dx), abs(step.dy), abs(step.dw))
        }
        let leading = change(from: before, to: now)
        let trailing = change(from: now, to: after)
        let leadingTime = (time - earlier).seconds
        let trailingTime = (later - time).seconds
        // Over a hundredth of the frame in a 240th of a second, and four times what the
        // other side moved: not a movement anybody made.
        func isJump(_ step: (dx: Double, dy: Double, dw: Double), beside other: (dx: Double, dy: Double, dw: Double)) -> Bool {
            size(step) > shorter * 0.01 && size(step) > size(other) * 4
        }

        var steps: [(dx: Double, dy: Double, dw: Double)] = []
        var span = 0.0
        if leadingTime > 0, !isJump(leading, beside: trailing) { steps.append(leading); span += leadingTime }
        if trailingTime > 0, !isJump(trailing, beside: leading) { steps.append(trailing); span += trailingTime }
        guard span > 0 else { return nil }
        let rate = (dx: steps.map(\.dx).reduce(0, +) / span,
                    dy: steps.map(\.dy).reduce(0, +) / span,
                    dw: steps.map(\.dw).reduce(0, +) / span)

        let shutter = Self.shutter
        var travel = CGVector(dx: rate.dx * shutter, dy: rate.dy * shutter)
        let travelled = hypot(travel.dx, travel.dy)
        let travelCap = shorter * Self.maximumTravel
        if travelled > travelCap {
            travel = CGVector(dx: travel.dx * travelCap / travelled, dy: travel.dy * travelCap / travelled)
        }
        let growth = min(max(rate.dw * shutter / now.width, -Self.maximumGrowth), Self.maximumGrowth)

        // Under a pixel of smear anywhere in the frame is nothing anybody could see, and
        // drawing it would only cost a blur pass.
        let reach = hypot(now.width, now.height) / 2
        guard hypot(travel.dx, travel.dy) >= 0.75 || abs(growth) * reach >= 0.75 else { return nil }
        return CameraMotionLayer(travel: travel, growth: growth, center: CGPoint(x: now.midX, y: now.midY))
    }
}
