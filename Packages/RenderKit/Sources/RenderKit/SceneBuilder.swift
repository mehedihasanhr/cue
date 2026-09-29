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
    /// What each pointer in this recording actually looked like. Empty for a recording
    /// that did not keep it, which is every recording made before it could.
    public let cursorArtwork: CursorArtworkIndex

    public init(videoSize: CGSize,
                displayScale: Double = 2,
                backgrounds: any BackgroundResolving = DefaultBackgroundResolver(),
                packageURL: URL? = nil,
                cursorArtwork: CursorArtworkIndex = CursorArtworkIndex()) {
        self.videoSize = videoSize
        self.displayScale = max(0.1, displayScale)
        self.backgrounds = backgrounds
        self.packageURL = packageURL
        self.cursorArtwork = cursorArtwork
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
                            packageURL: packageURL,
                            cursorArtwork: cursorArtwork)
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
        guard let ratio = style.aspectRatio else { return source }
        let area = source.width * source.height
        var width = (area * ratio).squareRoot()
        var height = width / ratio
        width = max(2, (width / 2).rounded() * 2)
        height = max(2, (height / 2).rounded() * 2)
        return CGSize(width: width, height: height)
    }

    /// Everything about one frame of the finished video but its dressing — the window
    /// round the picture and the camera's motion blur, which `descriptor(for:at:cursor:)`
    /// adds from what this has worked out.
    ///
    /// - Parameter track: the recorded pointer, **already smoothed**. Smoothing runs a
    ///   two-pass filter over every sample in the recording — 150,000 of them in a long
    ///   take — so doing it here would repeat that work on every frame of the preview
    ///   and again on every frame of an export. Callers smooth once, when the setting
    ///   changes, and pass the result in.
    func framingDescriptor(for timeline: Timeline,
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
        // A window's bar needs room above the picture, and it is a fraction of the
        // picture's own shorter side — so the picture and its bar are fitted together.
        // Zero without a window, which leaves this exactly the arithmetic it always was.
        let bar = SceneRenderer.barFraction(for: style.chrome.kind)
        let fit = min(available.width / source.width,
                      available.height / (source.height + bar * min(source.width, source.height)))
        let frame = CGSize(width: source.width * fit, height: source.height * fit)
        let barHeight = bar * min(frame.width, frame.height)
        // The window as a whole is centred, so the picture sits half a bar below the middle.
        let videoFrame = CGRect(x: (output.width - frame.width) / 2,
                                y: (output.height - frame.height - barHeight) / 2,
                                width: frame.width,
                                height: frame.height)

        // Over a clip imported from another file, the picture is that file's and nothing
        // measured against the recording belongs on it: no pointer, no clicks, no camera
        // chasing a pointer from a different take. Dropping the track here is what says so
        // to every layer below at once. The camera bubble goes too — it was filmed beside
        // the recording, and over somebody else's footage it would be a face from another
        // moment.
        let moment = timeline.mediaTime(at: time)
        let imported = moment?.source.flatMap { path in timeline.media.first { $0.path == path } }
        let isImported = moment?.source != nil
        let track = isImported ? nil : track
        // The recording's crop is a crop *of the recording*; an imported picture is shown
        // whole.
        let crop = isImported ? Self.unitRect : (style.crop?.rect ?? Self.unitRect)
        let camera = self.camera(for: timeline, at: time, cursor: track, crop: crop)
        let sourceTime = moment?.time ?? .zero
        // Where the picture and the camera go at this moment — the bubble, or a camera
        // layout moving them about. Everything below that is measured off the picture's
        // frame is measured off the one this decides, so the corners, the border, the
        // pointer and the zoom all follow the picture into its half of a split.
        var stage = cameraStage(timeline, at: time, output: output, inset: inset,
                                source: source, picture: videoFrame, zoom: camera.zoom)
        if isImported {
            // Fitted into the recording's place, its own shape kept, the background showing
            // round it — and framed as the recording is, corners, shadow and border
            // following the smaller picture. Decided here rather than by the renderer, so
            // the preview and the export fit it the same way by construction. Placed where
            // the recording sits with no camera layout in force: the layouts arrange the
            // recording and its camera, and this is neither.
            stage = (Self.fitted(imported?.pixelSize ?? .zero, into: videoFrame), 1, nil)
        }
        let shown = stage.videoFrame.size

        // The pointer's style, spotlight and lens are laid on afterwards, in their own file,
        // so the frame of a project that uses none of them is built exactly as before.
        return dressingPointer(SceneDescriptor(outputSize: output,
                               background: backgrounds.layer(for: style.background, packageURL: packageURL),
                               // A fraction of the shorter side, like every other
                               // measurement here, so the same setting reads the same at
                               // 1080p and at 4K.
                               backgroundBlur: Double(shorter) * style.backgroundBlur,
                               videoFrame: stage.videoFrame,
                               videoOpacity: stage.videoOpacity,
                               cornerRadius: Double(min(shown.width, shown.height)) * style.cornerRadius,
                               shadowRadius: Double(shorter) * style.shadowRadius,
                               shadowOpacity: style.shadowOpacity * stage.videoOpacity,
                               border: borderLayer(style, frame: shown),
                               zoom: camera.zoom,
                               zoomCenter: camera.center,
                               zoomsWholeFrame: timeline.camera.zoomsWholeFrame,
                               blurs: blurLayers(timeline, at: time),
                               cursor: faded(cursorLayer(timeline, at: time, sourceTime: sourceTime,
                                                         track: track, crop: crop),
                                             by: stage.videoOpacity),
                               clicks: faded(clickLayers(timeline, at: time, sourceTime: sourceTime,
                                                         track: track, crop: crop),
                                             by: stage.videoOpacity),
                               annotations: annotationLayers(timeline, at: time),
                               caption: captionLayer(timeline, at: time),
                               keys: keyLayer(timeline, at: time),
                               webcam: stage.webcam,
                               sourceTime: sourceTime,
                               sourceCrop: crop,
                               sourceMedia: moment?.source),
                               timeline, at: time, sourceTime: sourceTime, track: track, crop: crop)
    }

    /// A picture of `size`, as large as it fits inside `frame`, centred in it.
    ///
    /// An unknown size is no fit at all — the frame as it is — which is what a movie whose
    /// size was never measured gets, rather than a picture of no size.
    static func fitted(_ size: CGSize, into frame: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0 else { return frame }
        let scale = min(frame.width / size.width, frame.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: frame.midX - fitted.width / 2, y: frame.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    // MARK: - Camera

    /// How far in the camera is, and about what.
    ///
    /// Zooms do not stack: the strongest one at this moment wins. Two overlapping zooms
    /// multiplying into 4× is never what the user drew, and the timeline already merges
    /// suggestions for the same reason.
    ///
    /// - Parameter held: a zoom to frame as if it were fully in right now, whatever the
    ///   time says — the shot it *would* be holding. What a glide asks of each of its two
    ///   ends; see `ZoomGlide`. Left `nil`, the strongest zoom at this moment decides.
    func camera(for timeline: Timeline, at time: CMTime, cursor track: CursorTrack?, crop: CGRect,
                holding held: ZoomRegion? = nil) -> (zoom: Double, center: CGPoint) {
        // Between two zooms that are close together the camera travels straight from one
        // shot to the other rather than out to the whole picture and back. Each end of
        // the path is the shot that zoom would be holding at this very moment, pointer
        // following included, so the path joins what came before and what comes after
        // without a step. `ZoomGlide` is the rule; this is only the blend.
        if held == nil, let glide = timeline.zoomGlide(at: time) {
            let leaving = camera(for: timeline, at: time, cursor: track, crop: crop, holding: glide.from)
            let arriving = camera(for: timeline, at: time, cursor: track, crop: crop, holding: glide.to)
            let progress = glide.progress(at: time)
            let center = CGPoint(x: leaving.center.x + (arriving.center.x - leaving.center.x) * progress,
                                 y: leaving.center.y + (arriving.center.y - leaving.center.y) * progress)
            return settled(center, scale: glide.scale(at: time), timeline: timeline,
                           at: time, cursor: track, crop: crop)
        }

        var best: (scale: Double, region: ZoomRegion)? = held.map { ($0.scale, $0) }
        for region in timeline.zooms where held == nil {
            let scale = region.scale(at: time)
            guard scale > 1 else { continue }
            if best == nil || scale > best!.scale { best = (scale, region) }
        }
        guard let best else { return (1, CGPoint(x: 0.5, y: 0.5)) }

        // Read once, and clamped: a project is a file, and a file can ask for a safe area
        // of 40 or a negative window.
        let camera = timeline.camera.sanitised

        // Where this zoom was aimed, and where the camera stays unless the pointer makes
        // it move.
        var center = best.region.center
        let half = ZoomFraming.halfSide(forScale: best.scale)
        let override = timeline.cursorOverride(at: time)

        // Following the pointer is a *dead zone*, not a leash.
        //
        // It used to be a leash: the centre was blended straight onto the pointer's
        // averaged position, so the picture slid continuously for every movement of the
        // hand — including all the movement that happens *inside* the shot, which is most
        // of it. Clicking three things inside one zoomed area produced three slides to
        // frame things that were already framed, and the limit below, which exists exactly
        // to stop that, never got a chance to bind because the centre was already sitting
        // on the pointer.
        //
        // So the camera holds the shot it was given and moves only when the pointer would
        // otherwise leave it, and then only by as much as it has to. Work inside the shot
        // costs no movement at all; walking out of it brings the camera along.
        //
        // A pointer nobody can see has no claim on the framing: keeping a hidden cursor in
        // shot would drag the camera for something the viewer is not being shown, which is
        // the opposite of why the pointer was hidden. Faded with the region rather than
        // switched off at its edge, so the camera does not lurch as the pointer goes.
        if best.region.followsCursor, camera.follow > 0, timeline.cursor.isVisible,
           override.hiding < 1, let track, !track.isEmpty,
           let sourceTime = timeline.sourceTime(at: time) {
            let claim = (1 - override.hiding) * camera.follow

            // The dead zone itself, measured on the *averaged* pointer: a twitch of the
            // hand at the boundary would otherwise nudge the picture, and `steadiness` is
            // the dial that says how much of a twitch to ignore.
            if let averaged = track.averagePosition(at: sourceTime.seconds, window: camera.steadiness)
                .flatMap({ normalised($0, crop: crop) }) {
                center = nudged(center, toKeep: averaged, within: half * camera.safeArea, by: claim)
            }

            // And the same limit on the pointer as it is actually *drawn*, which is what
            // makes `safeArea` mean what it says: measured on `pointerPoint` — the same
            // point `cursorLayer` uses, held and smoothed the same way — so the frame
            // cannot be right about a cursor that is somewhere else.
            //
            // Both clamps, not one. The averaged one is the calmer of the two and leads on
            // the way back, so the camera does not snap home the instant a fast pointer
            // turns around; this one keeps the comfortable framing honest.
            if let live = drawnPointer(timeline, at: time, sourceTime: sourceTime,
                                       track: track, override: override, crop: crop) {
                center = nudged(center, toKeep: live, within: half * camera.safeArea, by: claim)
            }
        }

        return settled(center, scale: best.scale, timeline: timeline, at: time, cursor: track, crop: crop)
    }

    /// The two rules every shot ends with, whatever decided it: a drawn pointer stays in
    /// the shot, and the shot stays on the picture.
    ///
    /// One function because two things now decide a shot — a zoom on its own, and a glide
    /// blending two — and the blend of two shots that each keep the pointer in frame does
    /// not by itself keep it in frame: the blended shot is smaller than the average of the
    /// two, so the pointer can be a hair outside it. Both rules are run again on the
    /// result, and both are continuous, so the path stays continuous.
    private func settled(_ center: CGPoint, scale: Double, timeline: Timeline, at time: CMTime,
                         cursor track: CursorTrack?, crop: CGRect) -> (zoom: Double, center: CGPoint) {
        var center = center
        let half = ZoomFraming.halfSide(forScale: scale)
        let camera = timeline.camera.sanitised
        let override = timeline.cursorOverride(at: time)

        // For every zoom: a pointer that is being drawn may not be drawn outside the shot.
        //
        // Not gated on `followsCursor`, and that is the point. Aiming a zoom by hand turns
        // following off — you chose a shot, so the camera holds it — and focus and typing
        // zooms never follow, because a camera drifting after the mouse while somebody
        // types is seasickness. All correct, and all of it left the pointer free to walk
        // out of the shot, where it is clipped away and simply vanishes from the video. A
        // cursor that disappears mid-zoom is a rendering fault whatever the zoom's
        // settings say.
        //
        // At the very edge rather than at `safeArea`, so it binds only when the pointer
        // would genuinely be lost, and then by the least it can. For a zoom that already
        // follows, the comfortable clamp above has settled things long before this one has
        // anything to say.
        //
        // Clamped into the picture rather than abandoned when it leaves it. A pointer that
        // walks off the recorded area — onto a context menu clipped by the window being
        // filmed, onto the Dock, onto another screen — cannot be kept in shot, because it
        // is not in the recording at all. What the camera *can* do is go to the edge it
        // left by, so the viewer is looking at the part of the picture the action moved
        // towards. Holding the old framing instead leaves the shot pointed at whatever the
        // person has stopped doing.
        if camera.follow > 0, timeline.cursor.isVisible, override.hiding < 1,
           let track, !track.isEmpty,
           let sourceTime = timeline.sourceTime(at: time),
           let live = pointerPoint(timeline, at: time, sourceTime: sourceTime,
                                   track: track, override: override)
               .map({ normalisedClamped($0, crop: crop) }) {
            center = nudged(center, toKeep: live, within: half * 0.98, by: 1 - override.hiding)
        }

        // Keep the camera inside the picture. Last, so it always wins — a pointer in the
        // corner is kept in shot by the frame reaching the corner, not by the frame sliding
        // off the picture to centre on it. Through `ZoomFraming`, which is also what the
        // framing box on the preview is drawn from, so the two cannot disagree.
        return (scale, ZoomFraming.honoured(center: center, scale: scale))
    }

    /// A point in recorded points as a fraction of the cropped frame, held inside it.
    ///
    /// The forgiving twin of `normalised`, and the two are deliberately different. That one
    /// refuses a point outside the picture because the *pointer* must not be drawn on the
    /// padding beside it. This one is for the camera, which has to decide where to look
    /// even when the thing it is following has gone somewhere that was never filmed: the
    /// nearest edge is the honest answer, and holding still is not.
    func normalisedClamped(_ point: CGPoint, crop: CGRect) -> CGPoint {
        let pixels = CGPoint(x: point.x * displayScale, y: point.y * displayScale)
        guard videoSize.width > 0, videoSize.height > 0, crop.width > 0, crop.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let u = (pixels.x / videoSize.width - crop.minX) / crop.width
        let v = (pixels.y / videoSize.height - crop.minY) / crop.height
        return CGPoint(x: min(1, max(0, u)), y: min(1, max(0, v)))
    }

    /// The pointer as it is actually drawn, as a fraction of the cropped frame.
    ///
    /// The same point `cursorLayer` uses — held and smoothed the same way — so the framing
    /// cannot be right about a cursor that is somewhere else. `nil` when the pointer is
    /// outside the crop, which is when there is nothing drawn to keep in shot.
    private func drawnPointer(_ timeline: Timeline,
                              at time: CMTime,
                              sourceTime: CMTime,
                              track: CursorTrack,
                              override: CursorOverride,
                              crop: CGRect) -> CGPoint? {
        pointerPoint(timeline, at: time, sourceTime: sourceTime, track: track, override: override)
            .flatMap { normalised($0, crop: crop) }
    }

    /// Moves a camera centre only as far as it must to keep a point within `reach` of it.
    ///
    /// The whole of the dead zone, in four comparisons: inside the box, the answer is the
    /// centre it was given and nothing moves; outside, the centre travels exactly to the
    /// boundary and no further. `claim` scales how much of that movement is taken, which
    /// is what lets following fade out with a hidden pointer and what `CameraStyle.follow`
    /// turns down.
    ///
    /// Pure, and applied to the zoom's *stored* centre on every frame rather than to the
    /// last frame's answer — so there is no accumulated state, no drift, and a pointer that
    /// wanders out and comes back leaves the camera where the zoom was aimed rather than
    /// wherever the wandering happened to end.
    private func nudged(_ center: CGPoint, toKeep point: CGPoint,
                        within reach: Double, by claim: Double) -> CGPoint {
        let kept = CGPoint(x: min(max(center.x, point.x - reach), point.x + reach),
                           y: min(max(center.y, point.y - reach), point.y + reach))
        return CGPoint(x: center.x + (kept.x - center.x) * claim,
                       y: center.y + (kept.y - center.y) * claim)
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
            // Where the mask is at this moment: a following mask moves, a still one is its
            // `rect`. Asked here so the preview and the export cannot disagree about it.
            .map { BlurLayer(rect: $0.rect(at: time), style: $0.style, radius: $0.radius,
                             color: $0.color, dimming: $0.dimming, softness: $0.softness,
                             cornerRadius: $0.cornerRadius) }
    }

    /// Every annotation on screen at `time`, bottom of the stack first.
    ///
    /// The lane's order *is* the stack — see `AnnotationItem` — so this keeps it rather
    /// than sorting. Hidden ones are left out here, which is the one place both the preview
    /// and the export read, so "hidden" cannot mean one thing on screen and another in the
    /// file.
    private func annotationLayers(_ timeline: Timeline, at time: CMTime) -> [AnnotationLayer] {
        timeline.annotations.compactMap { item in
            guard !item.isHidden, item.contains(time) else { return nil }
            let pose = item.pose(atOffset: (time - item.start).seconds)
            guard pose.opacity > 0.001 else { return nil }
            // A picture is kept inside the project and named relative to it, so a project
            // can be moved; the renderer is handed where it is now.
            var kind = item.kind
            if case .image(let path) = kind, !path.hasPrefix("/"), let packageURL {
                kind = .image(path: packageURL.appendingPathComponent(path).path)
            }
            return AnnotationLayer(kind: kind,
                                   rect: item.rect,
                                   color: item.color,
                                   fontSize: item.fontSize,
                                   opacity: max(0, min(1, pose.opacity)),
                                   rotation: item.rotation,
                                   scale: pose.scale,
                                   offset: pose.offset,
                                   style: item.style)
        }
    }

    // MARK: - The camera bubble

    /// How far the bubble sits in from the edge it is parked against, as a fraction of the
    /// shorter output side.
    ///
    /// A constant rather than a setting, and deliberately so: the one thing anybody wants
    /// to change about where the bubble sits is *which* corner, and after that they want it
    /// somewhere specific — which is what `.custom` is for. A margin slider would be a
    /// third way of saying the same thing, with two of them able to disagree. Measured
    /// against the shorter side like the padding, so the inset reads the same at 1080p, at
    /// 4K and in a 9:16 reframe.
    private static let webcamMargin = 0.035

    /// The bubble for this frame, or `nil` when there isn't one — where it sits in the
    /// bubble layout, whatever layout is actually in force. `cameraStage` moves it from
    /// there.
    ///
    /// `nil` whenever the webcam is off, which is every project written before this
    /// existed: `WebcamSettings.isEnabled` defaults to `false` and decodes to `false`, so
    /// an old recording describes — and renders — exactly the frame it always did.
    ///
    /// Everything read out of the settings is clamped on the way through. A project is a
    /// file, and a file can ask for a bubble of size 40, a roundness of −3 or a position
    /// off the side of the frame; none of those should be able to produce a render nobody
    /// can explain.
    func webcamLayer(_ timeline: Timeline, output: CGSize, zoom: Double) -> WebcamLayer? {
        let webcam = timeline.webcam
        guard webcam.isEnabled, output.width > 0, output.height > 0 else { return nil }

        let shorter = min(output.width, output.height)
        // Grown a little while the camera is in, so the bubble keeps its weight in a frame
        // whose contents have just got bigger instead of appearing to shrink away from
        // them. Gently, and capped: the bubble tracking a 4× zoom one-for-one would end up
        // most of the picture, which is the opposite of the intent.
        let reaction = webcam.reactsToZoom ? 1 + min(0.3, max(0, zoom - 1) * 0.12) : 1
        let side = shorter * min(max(webcam.size, 0.05), 0.6) * reaction
        let margin = shorter * Self.webcamMargin

        // Normalised to the output, so the rect can be clamped and reasoned about in the
        // same space the layer stores it in.
        let width = side / output.width
        let height = side / output.height
        let insetX = margin / output.width
        let insetY = margin / output.height

        let origin: CGPoint = switch webcam.corner {
        case .topLeft: CGPoint(x: insetX, y: insetY)
        case .topRight: CGPoint(x: 1 - insetX - width, y: insetY)
        case .bottomLeft: CGPoint(x: insetX, y: 1 - insetY - height)
        case .bottomRight: CGPoint(x: 1 - insetX - width, y: 1 - insetY - height)
        case .custom:
            // `position` is the bubble's *centre*, which is what a drag on the preview
            // hands over and the only reading under which the default (0.85, 0.85) means
            // what the default corner — bottom right — means.
            CGPoint(x: webcam.position.x - width / 2, y: webcam.position.y - height / 2)
        }

        // Kept inside the frame whatever was asked for. A bubble half off the edge is not a
        // composition choice, it is a corrupt file or a drag that ran past the window.
        let rect = CGRect(x: min(max(origin.x, 0), max(0, 1 - width)),
                          y: min(max(origin.y, 0), max(0, 1 - height)),
                          width: min(width, 1),
                          height: min(height, 1))

        return WebcamLayer(rect: rect,
                           // Half the side is a circle, and `roundness` is the fraction of
                           // the way there — so the model's 0…1 needs no second convention.
                           cornerRadius: side / 2 * min(max(webcam.roundness, 0), 1),
                           isMirrored: webcam.isMirrored,
                           shadowOpacity: min(max(webcam.shadowOpacity, 0), 1),
                           crop: webcam.crop.sanitised,
                           border: webcamBorder(webcam, side: side),
                           background: webcam.background,
                           backgroundBlur: webcam.backgroundBlur.isFinite
                               ? min(max(webcam.backgroundBlur, 0), 1) : 0.5)
    }

    /// The bubble's border in output pixels, or `nil` for none.
    ///
    /// Measured against the bubble's side, so it keeps its weight as the bubble is resized;
    /// and resolved once, here, so a camera layout that grows the bubble into a pane keeps
    /// the same line rather than a line that swells with it.
    private func webcamBorder(_ webcam: WebcamSettings, side: Double) -> BorderLayer? {
        guard webcam.borderWidth.isFinite, webcam.borderColor.a > 0 else { return nil }
        let fraction = min(max(webcam.borderWidth, WebcamSettings.borderWidthRange.lowerBound),
                           WebcamSettings.borderWidthRange.upperBound)
        let width = side * fraction
        return width > 0 ? BorderLayer(width: width, color: webcam.borderColor) : nil
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

        let elapsed = cue.progress(at: time) * cue.duration.seconds
        let remaining = cue.duration.seconds - elapsed
        let pose = Self.captionPose(style.animation, elapsed: elapsed, remaining: remaining,
                                    length: cue.duration.seconds)

        return CaptionLayer(text: cue.text,
                            fontSize: style.fontSize,
                            color: style.color,
                            backgroundOpacity: style.backgroundOpacity,
                            position: style.position,
                            margin: style.margin,
                            opacity: max(0, min(1, pose.opacity)),
                            typeface: style.typeface,
                            spokenWord: style.highlightsWords ? cue.wordIndex(at: time) : nil,
                            highlightColor: style.highlightColor,
                            scale: pose.scale,
                            drop: pose.drop * style.fontSize,
                            fontFamily: style.fontFamily)
    }

    /// How a line is drawn a moment after it arrives and a moment before it goes.
    ///
    /// Every style leaves with the same short fade. An exit that moves pulls the eye to a
    /// line that is finished, at the moment the next one is starting; only the arrival is
    /// worth decorating. `drop` is in lines of text, so the rise is the same distance at
    /// any caption size.
    static func captionPose(_ animation: CaptionStyle.Animation,
                            elapsed: Double, remaining: Double,
                            length: Double) -> (opacity: Double, scale: Double, drop: Double) {
        guard animation != .none else { return (1, 1, 0) }
        // A short fade at each end, as annotations get, so a line appears rather than
        // snapping on — subtitles that blink are exhausting to read.
        let fade = min(0.12, length / 4)
        let opacity = fade > 0 ? min(1, min(elapsed, remaining) / fade) : 1

        let arrival = min(0.22, length / 3)
        let arrived = arrival > 0 ? min(1, max(0, elapsed / arrival)) : 1
        // Out fast and easing to rest: the shape of something settling, not of something
        // being moved at a constant speed.
        let eased = 1 - pow(1 - arrived, 3)

        switch animation {
        case .none, .fade:
            return (opacity, 1, 0)
        case .rise:
            return (opacity, 1, (1 - eased) * 0.6)
        case .pop:
            // A little small, a little past its size, and then its size.
            let overshoot = sin(arrived * .pi) * 0.05
            return (opacity, 0.92 + 0.08 * eased + overshoot, 0)
        }
    }

    /// Where the pointer is drawn at this moment, in recorded points.
    ///
    /// One answer, used by both the cursor layer and the camera's safe-area clamp: the two
    /// must not disagree about where the pointer is, or the frame is kept around a cursor
    /// that is somewhere else. With no cursor regions this is `track.position(at:)` and
    /// nothing more, so an old project gets exactly the pixels it always did.
    func pointerPoint(_ timeline: Timeline,
                              at time: CMTime,
                              sourceTime: CMTime,
                              track: CursorTrack,
                              override: CursorOverride) -> CGPoint? {
        guard var point = track.position(at: sourceTime.seconds) else { return nil }
        guard !override.isNothing else { return point }

        // Extra smoothing: blend towards where the pointer has *been* over a short window.
        // The same averaging the camera follows, for the same reason — it lags, and lag is
        // exactly what takes the snap out of a flick — and stateless, so scrubbing to this
        // frame gives the same point as playing to it. Blended by the window's own
        // strength rather than switched on, so the calm arrives over the region's ramp
        // instead of on one frame.
        if override.smoothingWindow > 0,
           let averaged = track.averagePosition(at: sourceTime.seconds, window: override.smoothingWindow) {
            let strength = min(1, override.smoothingWindow / CursorRegion.maximumSmoothingWindow)
            point = CGPoint(x: point.x + (averaged.x - point.x) * strength,
                            y: point.y + (averaged.y - point.y) * strength)
        }

        // A hold: ease from wherever the pointer is towards where it was when the region
        // began. Interpolated rather than assigned, so the pointer comes to rest over the
        // ramp and leaves again the same way — a hard freeze mid-movement is the one thing
        // that reads as a broken render rather than an edit.
        if override.holding > 0, let since = override.heldSince,
           let heldSource = timeline.sourceTime(at: since),
           let held = track.position(at: heldSource.seconds) {
            point = CGPoint(x: point.x + (held.x - point.x) * override.holding,
                            y: point.y + (held.y - point.y) * override.holding)
        }
        return point
    }

    /// The marks for clicks that are still showing.
    ///
    /// Drawn at the *recorded* place rather than at the drawn pointer's, and the difference
    /// is the point: smoothing moves the pointer a few pixels towards where it was going,
    /// so a ring centred on the smoothed position would sit slightly off the button that
    /// was actually pressed. The pointer may drift away from its own click over the next
    /// half second — it should, because the hand did.
    ///
    /// Hidden along with the pointer. A recording where the pointer has been faded out for
    /// a stretch is one where the viewer is being asked to look at something else, and a
    /// ring appearing over it would be the one thing on screen moving.
    ///
    /// That used to be only half done: the rule was written here and the code checked
    /// whether the pointer was switched off for the whole project, never whether a stretch
    /// had hidden it. A click inside a "Hide Pointer" stretch still sent out its ring.
    private func clickLayers(_ timeline: Timeline,
                             at time: CMTime,
                             sourceTime: CMTime,
                             track: CursorTrack?,
                             crop: CGRect) -> [ClickLayer] {
        let style = timeline.cursor
        guard style.isVisible, style.clickHighlight, let track, !track.clicks.isEmpty else { return [] }
        // Faded as the pointer is faded, so a ring does not outlast the pointer it
        // belongs to by the length of the fade.
        let shown = 1 - min(1, max(0, timeline.cursorOverride(at: time).hiding))
        guard shown > 0.001 else { return [] }
        var colour = style.clickColor
        colour.a *= shown

        return track.marks(at: sourceTime.seconds).compactMap { mark in
            guard let position = normalised(mark.click.point, crop: crop) else { return nil }
            return ClickLayer(position: position,
                              progress: mark.progress,
                              color: colour,
                              size: style.clickSize,
                              isSecondary: mark.click.isSecondary,
                              style: style.clickStyle)
        }
    }

    private func cursorLayer(_ timeline: Timeline,
                             at time: CMTime,
                             sourceTime: CMTime,
                             track: CursorTrack?,
                             crop: CGRect) -> CursorLayer? {
        guard timeline.cursor.isVisible, let track, !track.isEmpty else { return nil }

        let override = timeline.cursorOverride(at: time)
        // Fully faded out means no layer at all rather than a transparent one: everything
        // downstream — the renderer's filter chain, a test asking "is the pointer drawn?" —
        // should get one answer, and an invisible pointer is not drawn.
        var opacity = 1 - min(1, max(0, override.hiding))
        // Gone while it is left alone, when the project asks for that. Multiplied rather
        // than chosen between, so a stretch that hides the pointer and a pointer that has
        // gone to rest cannot argue about which of them is in charge.
        if timeline.cursor.hidesWhenIdle {
            opacity *= track.idleOpacity(at: sourceTime.seconds, after: timeline.cursor.idleDelay)
        }
        guard opacity > 0.001 else { return nil }

        guard let point = pointerPoint(timeline, at: time, sourceTime: sourceTime,
                                       track: track, override: override),
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
            ? pointerVelocity(timeline, at: time, sourceTime: sourceTime, track: track)
            : .zero
        let shape = pointerShape(timeline.cursor, at: sourceTime.seconds, track: track)
        return CursorLayer(position: position,
                           shape: CursorShapeKind(shape),
                           scale: scale,
                           opacity: opacity,
                           velocity: velocity,
                           sizeFollowsZoom: !timeline.cursor.sizeIsIndependentOfZoom,
                           // The real thing when the recording kept one and the project
                           // wants it. `nil` is the drawn pointer, which is what every
                           // recording made before this had.
                           artwork: timeline.cursor.usesRecordedArtwork
                               ? cursorArtwork.artwork(for: shape).map {
                                   RecordedCursor(url: $0.url, hotspot: $0.hotspot, aspect: $0.aspect)
                                 }
                               : nil)
    }

    /// What the pointer looks like at a moment, as the project wants it drawn.
    private func pointerShape(_ style: CursorStyle, at seconds: Double, track: CursorTrack) -> CursorShape {
        if style.alwaysArrow { return .arrow }
        return style.steadiesShape ? track.steadyShape(at: seconds) : track.shape(at: seconds)
    }

    /// How fast the pointer is moving *as drawn*.
    ///
    /// Differentiated from `pointerPoint` rather than read off the track, because inside a
    /// hold the pointer is standing still while the recorded hand is not: smearing it for
    /// travel it is no longer making would look like a rendering fault, which is the exact
    /// thing motion blur's direction is there to avoid. With no cursor region in force both
    /// samples are plain track positions, so this reduces to `track.velocity(at:)` and an
    /// old project's smear is unchanged to the last pixel.
    private func pointerVelocity(_ timeline: Timeline,
                                 at time: CMTime,
                                 sourceTime: CMTime,
                                 track: CursorTrack,
                                 window: Double = 1 / 30) -> CGVector {
        let before = time - CMTime(seconds: window, preferredTimescale: 600)
        guard let now = pointerPoint(timeline, at: time, sourceTime: sourceTime, track: track,
                                     override: timeline.cursorOverride(at: time)),
              let then = pointerPoint(timeline, at: before,
                                      sourceTime: sourceTime - CMTime(seconds: window, preferredTimescale: 600),
                                      track: track,
                                      override: timeline.cursorOverride(at: before))
        else { return .zero }
        return CGVector(dx: (now.x - then.x) / window, dy: (now.y - then.y) / window)
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
