import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import TimelineKit

/// Turns an edit and a moment into a description of one frame.
///
/// A pure function, which is the point: the preview calls it on a display refresh, the
/// exporter calls it per output frame, and neither can drift from the other because
/// there is nothing here to get out of step — no state, no clock, no side effects.
public struct SceneBuilder: Sendable {
    /// The recording's own size in pixels.
    public let videoSize: CGSize
    /// Points-to-pixels of the recorded display, so cursor samples (points) line up with
    /// frames (pixels).
    public let displayScale: Double
    /// Turns a stored background into a drawable one.
    ///
    /// Injected rather than looked up, so the preview and the exporter resolve the same
    /// way by construction rather than by two call sites agreeing.
    public let backgrounds: any BackgroundResolving
    /// The project, for backgrounds stored relative to it.
    public let packageURL: URL?

    public init(videoSize: CGSize,
                displayScale: Double = 2,
                backgrounds: any BackgroundResolving = DefaultBackgroundResolver(),
                packageURL: URL? = nil) {
        self.videoSize = videoSize
        self.displayScale = max(0.1, displayScale)
        self.backgrounds = backgrounds
        self.packageURL = packageURL
    }

    /// The same builder, measured against a different source size.
    ///
    /// The manifest records what the recorder *asked* for; the file says what it got,
    /// and they differ by a pixel often enough to matter. The editor already rebuilds
    /// itself once the real size is known, and the exporter has to do the same or the
    /// picture lands a pixel off in the file and nowhere else.
    public func resized(to videoSize: CGSize) -> SceneBuilder {
        guard videoSize != self.videoSize, videoSize.width > 0, videoSize.height > 0 else { return self }
        return SceneBuilder(videoSize: videoSize,
                            displayScale: displayScale,
                            backgrounds: backgrounds,
                            packageURL: packageURL)
    }

    /// How big the picture is once the crop has been taken off it.
    public func croppedVideoSize(for style: FrameStyle) -> CGSize {
        guard let crop = style.crop else { return videoSize }
        return crop.pixels(in: videoSize)
    }

    /// The output frame for a style: the recording's shape, or the chosen aspect.
    ///
    /// Sized to fit inside the recording's pixel count rather than upscaling it, so a
    /// vertical export of a landscape recording gets sharper, not blurrier. Measured
    /// against the *cropped* picture, because once cropped that is the recording's real
    /// pixel count — preserving the uncropped area would upscale a quarter-frame crop by
    /// two, which is exactly the blur this rule exists to prevent.
    public func outputSize(for style: FrameStyle) -> CGSize {
        let source = croppedVideoSize(for: style)
        guard let ratio = style.aspect.ratio else { return source }
        let area = source.width * source.height
        var width = (area * ratio).squareRoot()
        var height = width / ratio
        width = max(2, (width / 2).rounded() * 2)
        height = max(2, (height / 2).rounded() * 2)
        return CGSize(width: width, height: height)
    }

    /// Everything about one frame of the finished video.
    ///
    /// - Parameter track: the recorded pointer, **already smoothed**. Smoothing runs a
    ///   two-pass filter over every sample in the recording — 150,000 of them in a long
    ///   take — so doing it here would repeat that work on every frame of the preview
    ///   and again on every frame of an export. Callers smooth once, when the setting
    ///   changes, and pass the result in.
    public func descriptor(for timeline: Timeline,
                           at time: CMTime,
                           cursor track: CursorTrack? = nil) -> SceneDescriptor {
        let output = outputSize(for: timeline.style)
        let style = timeline.style

        // Padding is a fraction of the shorter side so a 16:9 and a 9:16 export get the
        // same-looking margin rather than the same number of pixels.
        let shorter = min(output.width, output.height)
        let inset = shorter * style.padding
        let available = CGSize(width: max(1, output.width - inset * 2),
                               height: max(1, output.height - inset * 2))
        let source = croppedVideoSize(for: style)
        let fit = min(available.width / source.width, available.height / source.height)
        let frame = CGSize(width: source.width * fit, height: source.height * fit)
        let videoFrame = CGRect(x: (output.width - frame.width) / 2,
                                y: (output.height - frame.height) / 2,
                                width: frame.width,
                                height: frame.height)

        let crop = style.crop?.rect ?? Self.unitRect
        let camera = self.camera(for: timeline, at: time, cursor: track, crop: crop)
        let sourceTime = timeline.sourceTime(at: time) ?? .zero

        return SceneDescriptor(outputSize: output,
                               background: backgrounds.layer(for: style.background, packageURL: packageURL),
                               // A fraction of the shorter side, like every other
                               // measurement here, so the same setting reads the same at
                               // 1080p and at 4K.
                               backgroundBlur: Double(shorter) * style.backgroundBlur,
                               videoFrame: videoFrame,
                               cornerRadius: Double(min(frame.width, frame.height)) * style.cornerRadius,
                               shadowRadius: Double(shorter) * style.shadowRadius,
                               shadowOpacity: style.shadowOpacity,
                               zoom: camera.zoom,
                               zoomCenter: camera.center,
                               blurs: blurLayers(timeline, at: time),
                               cursor: cursorLayer(timeline, at: time, sourceTime: sourceTime, track: track, crop: crop),
                               annotations: annotationLayers(timeline, at: time),
                               caption: captionLayer(timeline, at: time),
                               sourceTime: sourceTime,
                               sourceCrop: crop)
    }

    // MARK: - Camera

    /// How far in the camera is, and about what.
    ///
    /// Zooms do not stack: the strongest one at this moment wins. Two overlapping zooms
    /// multiplying into 4× is never what the user drew, and the timeline already merges
    /// suggestions for the same reason.
    private func camera(for timeline: Timeline, at time: CMTime, cursor track: CursorTrack?, crop: CGRect) -> (zoom: Double, center: CGPoint) {
        var best: (scale: Double, region: ZoomRegion)?
        for region in timeline.zooms {
            let scale = region.scale(at: time)
            guard scale > 1 else { continue }
            if best == nil || scale > best!.scale { best = (scale, region) }
        }
        guard let best else { return (1, CGPoint(x: 0.5, y: 0.5)) }

        // Read once, and clamped: a project is a file, and a file can ask for a safe area
        // of 40 or a negative window.
        let camera = timeline.camera.sanitised

        var center = best.region.center
        if best.region.followsCursor, camera.follow > 0, let track, !track.isEmpty,
           let sourceTime = timeline.sourceTime(at: time),
           // Averaged over a window, not the pointer's exact position: at 2× every
           // twitch of a hand is 2× on screen, and a camera welded to the mouse is what
           // makes a zoom unwatchable.
           let point = track.averagePosition(at: sourceTime.seconds, window: camera.steadiness),
           // A pointer outside the crop is not in this picture, so the camera holds the
           // centre the region was given rather than aiming at somewhere off-frame.
           let followed = normalised(point, crop: crop) {
            // Blended in as the zoom arrives. Cutting straight to the pointer would make
            // the camera lurch at the exact moment the zoom starts, and the clamp below
            // would drag the centre across the frame as the margin opens up — a slide
            // nobody asked for and the worst-looking part of the old behaviour.
            let span = max(0.0001, best.region.scale - 1)
            let progress = min(1, max(0, (best.scale - 1) / span)) * camera.follow
            center = CGPoint(x: center.x + (followed.x - center.x) * progress,
                             y: center.y + (followed.y - center.y) * progress)
        }
        // The frame may lag the pointer, but it may not lose it.
        //
        // Applied after the blend and before the picture clamp, and only as a limit: while
        // the pointer is anywhere near the middle of the frame this changes nothing, so a
        // resting hand still gets the calm averaged camera. It binds only when the pointer
        // is about to leave, and then only by as much as it has to.
        let half = 0.5 / best.scale
        if best.region.followsCursor, camera.follow > 0, timeline.cursor.isVisible, let track, !track.isEmpty,
           let sourceTime = timeline.sourceTime(at: time),
           // The pointer as it is *drawn* — the same smoothed track and the same
           // normalisation `cursorLayer` uses, so the two cannot disagree about where it
           // is and the frame cannot be right about a cursor that is somewhere else.
           let live = track.position(at: sourceTime.seconds).flatMap({ normalised($0, crop: crop) }) {
            let reach = half * camera.safeArea
            center.x = min(max(center.x, live.x - reach), live.x + reach)
            center.y = min(max(center.y, live.y - reach), live.y + reach)
        }

        // Keep the camera inside the picture: at 2× the centre can only travel between
        // 0.25 and 0.75 before the frame shows its own edge. Last, so it always wins — a
        // pointer in the corner is kept in shot by the frame reaching the corner, not by
        // the frame sliding off the picture to centre on it.
        return (best.scale, CGPoint(x: min(1 - half, max(half, center.x)),
                                    y: min(1 - half, max(half, center.y))))
    }

    static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// A point in recorded points to a fraction of the *cropped* frame, or `nil` when it
    /// falls outside it.
    ///
    /// Nil rather than clamped, and that distinction matters: the renderer composites
    /// the pointer after the video and does not clip it to the video's frame, so a
    /// clamped out-of-crop pointer would be drawn floating on the background.
    private func normalised(_ point: CGPoint, crop: CGRect) -> CGPoint? {
        let pixels = CGPoint(x: point.x * displayScale, y: point.y * displayScale)
        let u = (pixels.x / videoSize.width - crop.minX) / crop.width
        let v = (pixels.y / videoSize.height - crop.minY) / crop.height
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u, y: v)
    }

    // MARK: - Layers

    private func blurLayers(_ timeline: Timeline, at time: CMTime) -> [BlurLayer] {
        timeline.blurs
            .filter { $0.contains(time) }
            .map { BlurLayer(rect: $0.rect, style: $0.style, radius: $0.radius) }
    }

    private func annotationLayers(_ timeline: Timeline, at time: CMTime) -> [AnnotationLayer] {
        timeline.annotations.compactMap { item in
            guard item.contains(time) else { return nil }
            // A short fade at each end, so an annotation appears rather than blinks.
            let fade = min(0.25, item.duration.seconds / 4)
            let progress = item.progress(at: time) * item.duration.seconds
            let remaining = item.duration.seconds - progress
            let opacity = fade > 0 ? min(1, min(progress, remaining) / fade) : 1
            return AnnotationLayer(kind: item.kind,
                                   rect: item.rect,
                                   color: item.color,
                                   fontSize: item.fontSize,
                                   opacity: max(0, min(1, opacity)))
        }
    }

    /// The line being spoken at this moment, if captions are on and there is one.
    ///
    /// Only one, even where two cues overlap: recognisers do produce overlapping
    /// segments, and two lines of subtitle stacked on top of each other is worse than
    /// briefly missing the tail of the first. The later cue wins, because that is the
    /// one being said now.
    private func captionLayer(_ timeline: Timeline, at time: CMTime) -> CaptionLayer? {
        let style = timeline.captionStyle
        guard style.isVisible else { return nil }
        guard let cue = timeline.captions.last(where: { $0.contains(time) }),
              !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // A short fade at each end, as annotations get, so a line appears rather than
        // snapping on — subtitles that blink are exhausting to read.
        let fade = min(0.12, cue.duration.seconds / 4)
        let elapsed = cue.progress(at: time) * cue.duration.seconds
        let remaining = cue.duration.seconds - elapsed
        let opacity = fade > 0 ? min(1, min(elapsed, remaining) / fade) : 1

        return CaptionLayer(text: cue.text,
                            fontSize: style.fontSize,
                            color: style.color,
                            backgroundOpacity: style.backgroundOpacity,
                            position: style.position,
                            margin: style.margin,
                            opacity: max(0, min(1, opacity)))
    }

    private func cursorLayer(_ timeline: Timeline,
                             at time: CMTime,
                             sourceTime: CMTime,
                             track: CursorTrack?,
                             crop: CGRect) -> CursorLayer? {
        guard timeline.cursor.isVisible, let track, !track.isEmpty else { return nil }
        guard let point = track.position(at: sourceTime.seconds),
              let position = normalised(point, crop: crop) else { return nil }

        var scale = timeline.cursor.scale
        if timeline.cursor.clickEffect {
            scale *= track.clickScale(at: sourceTime.seconds)
        }
        // Measured on the smoothed track, not the raw one: sampling at 120 Hz gives a
        // jitter that reads as speed, and smearing the pointer for it would be blur
        // applied to noise. `track` is the smoothed one — the caller smooths before
        // handing it over, which is what keeps that filter off the per-frame path.
        let velocity = timeline.cursor.motionBlur
            ? track.velocity(at: sourceTime.seconds)
            : .zero
        return CursorLayer(position: position,
                           shape: CursorShapeKind(track.shape(at: sourceTime.seconds)),
                           scale: scale,
                           velocity: velocity,
                           sizeFollowsZoom: !timeline.cursor.sizeIsIndependentOfZoom)
    }
}

extension CursorShapeKind {
    /// What the recorder saw, mapped to what the renderer can draw.
    ///
    /// Several recorded shapes collapse into one drawn one — an editor does not need to
    /// reproduce every system cursor, it needs the viewer to follow the pointer.
    public init(_ shape: CursorShape) {
        switch shape {
        case .iBeam: self = .iBeam
        case .pointingHand, .contextualMenu: self = .pointingHand
        case .openHand, .closedHand, .dragCopy, .dragLink: self = .openHand
        case .crosshair: self = .crosshair
        case .resizeLeftRight: self = .resizeHorizontal
        case .resizeUpDown: self = .resizeVertical
        default: self = .arrow
        }
    }
}
