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
    /// Where a resized window's picture sat inside the recorded frame over the take — see
    /// `PictureTrack` and `pictureCrop(at:)`. Empty for every other recording, which leaves
    /// every frame exactly as it was built before this existed.
    public let picture: PictureTrack

    public init(videoSize: CGSize,
                displayScale: Double = 2,
                backgrounds: any BackgroundResolving = DefaultBackgroundResolver(),
                packageURL: URL? = nil,
                cursorArtwork: CursorArtworkIndex = CursorArtworkIndex(),
                picture: PictureTrack = PictureTrack()) {
        self.videoSize = videoSize
        self.displayScale = max(0.1, displayScale)
        self.backgrounds = backgrounds
        self.packageURL = packageURL
        self.cursorArtwork = cursorArtwork
        self.picture = picture
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
                            cursorArtwork: cursorArtwork,
                            picture: picture)
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
        // A device goes all the way round instead. The handset is a fixed multiple of the
        // picture's size, so the scale that fits it is one division too — and the picture
        // sits in the middle of its screen, so centring the picture centres the device.
        let device = DeviceLayer(style.chrome, pictureSize: source)
        let whole = device.map { DeviceGeometry.bodySize($0, picture: source) }
            ?? CGSize(width: source.width, height: source.height + bar * min(source.width, source.height))
        let fit = min(available.width / whole.width, available.height / whole.height)
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
        //
        // And the crop is taken of the part of the recording that is picture at this moment.
        // For a window resized after recording began that is less than the whole frame —
        // see `pictureCrop(at:)` — and folding it in here, into the one rectangle every
        // layer below already measures itself against, is what keeps them all on the
        // picture: the renderer crops the source by it, and the pointer, its clicks, the
        // camera's following and the pointer's dressing are all normalised through it, so
        // they are moved and scaled by exactly what the picture was. A zoom's centre and the
        // crop tool's rectangle are fractions of the picture as it is shown, and stay so.
        // Masks and blurs are applied to the whole recording before the crop, so they stay
        // on the footage they were drawn over; a still one is stored as a fraction of the
        // picture and carried through a resize's rescale by `blurLayers` — see
        // `BlurRegion.recordingRect(at:source:picture:frame:)`.
        let sourceTime = moment?.time ?? .zero
        let crop = isImported
            ? Self.unitRect
            : Self.composed(style.crop?.rect ?? Self.unitRect, within: pictureCrop(at: sourceTime))
        let camera = self.camera(for: timeline, at: time, cursor: track, crop: crop)
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
                               blurs: blurLayers(timeline, at: time, sourceSeconds: isImported ? nil : sourceTime.seconds),
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

    // MARK: - The picture inside the frame

    /// The part of the recording that is picture at a moment of it, as a fraction of the
    /// recording, top-left origin — the whole of it unless a window was resized while it
    /// was recorded.
    ///
    /// A window's file is sized before the countdown; resized afterwards, the window is
    /// scaled to fit and the rest of the frame is black. `PictureTrack` knows where the
    /// picture went and cuts it to the frame's own shape, so this rectangle scaled to the
    /// output fills it with no black and no stretching.
    ///
    /// Measured in the recording's pixels, and rounded *inwards* to whole ones before it is
    /// cut to shape: a picture that ends two-fifths of the way across a pixel shares that
    /// pixel with the black beside it, and a crop that kept it would draw a faint dark line
    /// down the edge. The frame's points are the pointer's — `displayScale` over
    /// `videoSize`, the arithmetic `normalised(_:crop:)` uses — so a pointer and the picture
    /// under it are put through one conversion, not two that could disagree.
    /// The recording's size in the points the pointer and `picture` are measured in.
    public var pointFrame: CGSize {
        displayScale > 0 ? CGSize(width: videoSize.width / displayScale, height: videoSize.height / displayScale)
                         : videoSize
    }

    func pictureCrop(at sourceTime: CMTime) -> CGRect {
        guard !picture.isEmpty, videoSize.width > 0, videoSize.height > 0,
              let points = picture.picture(at: sourceTime.seconds),
              // Filling the frame give or take rounding is filling it — see `fillsFrame`.
              !PictureTrack.fillsFrame(points, frame: pointFrame) else { return Self.unitRect }
        let pixels = CGRect(x: points.minX * displayScale, y: points.minY * displayScale,
                            width: points.width * displayScale, height: points.height * displayScale)
        // A hundredth of a pixel's grace, so a corner that is at zero give or take the
        // floating point is not rounded a whole pixel in.
        let minX = (pixels.minX - 0.01).rounded(.up), minY = (pixels.minY - 0.01).rounded(.up)
        let maxX = (pixels.maxX + 0.01).rounded(.down), maxY = (pixels.maxY + 0.01).rounded(.down)
        let kept = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(CGRect(origin: .zero, size: videoSize))
        // Within a pixel of the whole frame is the whole frame: the ordinary take, built
        // exactly as it always was.
        guard !kept.isNull, kept.width >= 1, kept.height >= 1,
              kept.width < videoSize.width - 1 || kept.height < videoSize.height - 1
        else { return Self.unitRect }
        let shown = PictureTrack.filling(kept, frame: videoSize)
        return CGRect(x: shown.minX / videoSize.width, y: shown.minY / videoSize.height,
                      width: shown.width / videoSize.width, height: shown.height / videoSize.height)
    }

    /// A crop taken of a part of the recording, as a crop of the whole of it.
    ///
    /// The style's crop is a fraction of the picture as it is shown; the picture is a
    /// fraction of the recording. Composed, the renderer and everything that normalises a
    /// point go on working with one rectangle, as they always have.
    static func composed(_ crop: CGRect, within part: CGRect) -> CGRect {
        guard part != unitRect else { return crop }
        return CGRect(x: part.minX + crop.minX * part.width,
                      y: part.minY + crop.minY * part.height,
                      width: crop.width * part.width,
                      height: crop.height * part.height)
    }

    // MARK: - Camera

    /// How far in the camera is, and about what.
    ///
    /// Zooms do not stack: the strongest one at this moment wins. Two overlapping zooms
    /// multiplying into 4× is never what the user drew, and the timeline already merges
    /// suggestions for the same reason. "Strongest" is the furthest from 1× in doublings,
    /// so a pull back to 0.5× holds its own against a push in to 2× — see
    /// `ZoomRegion.strength(ofScale:)`.
    ///
    /// The shot at this moment, brought home to the first frame's over the last moments of
    /// a video that loops — see `PointerLoop.bringsCameraBack`.
    ///
    /// The journey is the pointer's own, the same eased blend over the same stretch, so the
    /// pointer and the picture under it arrive together: the last frame of the video is
    /// the first frame's shot with the first frame's pointer in it, and the seam of the
    /// loop has nothing in it to jump. Blended from the two shots rather than steered, so
    /// it is a function of the time like every other framing rule.
    func camera(for timeline: Timeline, at time: CMTime, cursor track: CursorTrack?,
                crop: CGRect) -> (zoom: Double, center: CGPoint) {
        let shot = framedCamera(for: timeline, at: time, cursor: track, crop: crop)
        guard timeline.cursor.loop.bringsCameraBack else { return shot }
        let home = timeline.pointerLoopBlend(at: time)
        guard home > 0 else { return shot }
        let first = framedCamera(for: timeline, at: .zero, cursor: track, crop: crop)
        let zoom = shot.zoom + (first.zoom - shot.zoom) * home
        let center = CGPoint(x: shot.center.x + (first.center.x - shot.center.x) * home,
                             y: shot.center.y + (first.center.y - shot.center.y) * home)
        // Kept on the picture at the blended scale: two shots that each are may still put
        // the blend a hair over the edge, because the room a centre has shrinks faster than
        // the scale grows.
        return (zoom, ZoomFraming.cameraCenter(center, scale: zoom))
    }

    /// The shot the zooms — and the whole-video zoom, when there is one — ask for at this
    /// moment, before a loop brings it home.
    ///
    /// - Parameter held: a zoom to frame as if it were fully in right now, whatever the
    ///   time says — the shot it *would* be holding. What a glide asks of each of its two
    ///   ends; see `ZoomGlide`. Left `nil`, the strongest zoom at this moment decides.
    /// - Parameter following: how much of the pointer's pull on the shot to allow, 0…1 —
    ///   faded across a glide so its ends do not slide about under the move.
    func framedCamera(for timeline: Timeline, at time: CMTime, cursor track: CursorTrack?, crop: CGRect,
                      holding held: ZoomRegion? = nil, following: Double = 1) -> (zoom: Double, center: CGPoint) {
        // The level the whole video is held at: 1 for every project that does not ask,
        // which leaves every line below doing exactly what it always did.
        let base = timeline.camera.sanitised.wholeVideoZoom

        // Between two zooms that are close together the camera travels straight from one
        // shot to the other rather than out to the whole picture and back. Each end of
        // the path is the shot that zoom would be holding at this very moment, pointer
        // following included, so the path joins what came before and what comes after
        // without a step. `ZoomGlide` is the rule; this is only the blend.
        //
        // The pointer's pull on each end fades across the move: in full on the shot being
        // left as the glide sets off, in full on the shot being arrived at as it lands, and
        // weak on both in between. Pulled in full throughout, the ends slid about under the
        // move while the hand crossed the screen towards the next thing, and the pan
        // stalled and lurched on its way — measured, a step twice its neighbours' and then
        // a near stop. Faded, the move is one clean eased travel that still joins the
        // following camera exactly at either end, and each end is still worked out at this
        // moment — so an excerpt that starts mid-glide shows the same frames the whole
        // video does. The pointer is kept in shot on the way by the clamp every shot ends
        // with.
        if held == nil, let glide = timeline.zoomGlide(at: time) {
            let progress = glide.progress(at: time)
            let leaving = framedCamera(for: timeline, at: time, cursor: track, crop: crop, holding: glide.from,
                                       following: 1 - progress)
            let arriving = framedCamera(for: timeline, at: time, cursor: track, crop: crop, holding: glide.to,
                                        following: progress)
            let scale = glide.scale(at: time) * base
            // Straight from one shot to the other — see `ZoomFraming.dolly`: between two
            // zooms of different depth one point holds still while the picture grows or
            // shrinks round it; between two of the same depth it is a pan.
            let center = ZoomFraming.dolly(from: (glide.from.scale * base, leaving.center),
                                           to: (glide.to.scale * base, arriving.center),
                                           atScale: scale, progress: progress)
            return settled(center, scale: scale, timeline: timeline,
                           at: time, cursor: track, crop: crop)
        }

        var best: (scale: Double, region: ZoomRegion)? = held.map { ($0.scale, $0) }
        for region in timeline.zooms where held == nil {
            let scale = region.scale(at: time)
            guard scale != 1 else { continue }
            if best == nil || ZoomRegion.strength(ofScale: scale) > ZoomRegion.strength(ofScale: best!.scale) {
                best = (scale, region)
            }
        }
        guard let best else {
            guard base > 1 else { return (1, CGPoint(x: 0.5, y: 0.5)) }
            let center = heldShot(timeline, at: time, cursor: track, crop: crop, scale: base)
            return settled(center, scale: base, timeline: timeline, at: time, cursor: track, crop: crop)
        }

        // Read once, and clamped: a project is a file, and a file can ask for a safe area
        // of 40 or a negative window.
        let camera = timeline.camera.sanitised

        // Inside a video held zoomed in, a zoom goes further in from there rather than
        // starting again from the whole picture.
        let scale = best.scale * base
        // Where this zoom is going: its own depth, all the way in.
        let target = best.region.scale * base
        // How far it has got there, 0 at the start of its ramp in (and the end of its ramp
        // out) and 1 while it holds. What lets the pointer steer only once it has arrived.
        let arrived = abs(target - base) > 0.000_1 ? min(1, max(0, (scale - base) / (target - base))) : 1

        // Where this zoom was aimed, and where the camera stays unless the pointer makes
        // it move — worked out for the shot it is going to, at its full depth.
        var center = best.region.center
        let half = ZoomFraming.halfSide(forScale: target)
        let override = timeline.cursorOverride(at: time)

        // Following the pointer is a *dead zone*, not a leash.
        //
        // It used to be a leash: the centre was blended straight onto the pointer's
        // averaged position, so the picture slid continuously for every movement of the
        // hand — including all the movement that happens *inside* the shot, which is most
        // of it. So the camera holds the shot it was given and moves only when the pointer
        // would otherwise leave it, and then only by as much as it has to. Work inside the
        // shot costs no movement at all; walking out of it brings the camera along.
        //
        // And only once the zoom has arrived. It used to steer from the first frame of the
        // ramp, while the shot was still the whole picture shrinking towards the zoom's:
        // every movement of the hand in those frames pushed the camera sideways, and the
        // zoom arrived by way of a wobble. Now the pointer's claim grows with `arrived`, so
        // the camera goes straight in and takes up the pointer as it lands — and lets go of
        // it the same way on the way out.
        //
        // A pointer nobody can see has no claim on the framing: keeping a hidden cursor in
        // shot would drag the camera for something the viewer is not being shown. Faded
        // with the region rather than switched off at its edge, so the camera does not
        // lurch as the pointer goes. Only while pushed in: pulled back, the whole
        // recording is in shot and there is nothing for the pointer to leave.
        if target > 1, best.region.followsCursor, camera.follow > 0, timeline.cursor.isVisible,
           override.hiding < 1, let track, !track.isEmpty,
           let sourceTime = timeline.sourceTime(at: time) {
            let claim = (1 - override.hiding) * camera.follow * arrived * min(1, max(0, following))

            // The dead zone itself, measured on the *averaged* pointer: a twitch of the
            // hand at the boundary would otherwise nudge the picture, and `steadiness` is
            // the dial that says how much of a twitch to ignore.
            if let averaged = track.averagePosition(at: sourceTime.seconds, window: camera.steadiness)
                .flatMap({ normalised($0, crop: crop) }) {
                center = nudged(center, toKeep: averaged, within: half * camera.safeArea, by: claim)
            }

            // And the same limit on the pointer as it is actually *drawn*, which is what
            // makes `safeArea` mean what it says — the same point `cursorLayer` uses.
            // Both clamps, not one: the averaged one is the calmer and leads on the way
            // back; this one keeps the comfortable framing honest.
            if let live = drawnPointer(timeline, at: time, sourceTime: sourceTime,
                                       track: track, override: override, crop: crop) {
                center = nudged(center, toKeep: live, within: half * camera.safeArea, by: claim)
            }
        }
        // The shot it is going to, kept on the picture at its own depth.
        let aim = ZoomFraming.cameraCenter(center, scale: target)

        // Pulled back below 1× the whole recording is in shot, and where the camera looks
        // is only where the shrunken picture sits: straight to the aim.
        guard scale >= 1, target >= 1 else {
            return settled(aim, scale: scale, timeline: timeline, at: time, cursor: track, crop: crop)
        }

        // From the shot before the zoom — the whole picture, or the held camera's inside a
        // video held zoomed in — straight to this one: see `ZoomFraming.dolly`.
        let before = base > 1
            ? (scale: base, center: ZoomFraming.cameraCenter(heldShot(timeline, at: time, cursor: track,
                                                                      crop: crop, scale: base),
                                                             scale: base))
            : (scale: 1.0, center: CGPoint(x: 0.5, y: 0.5))
        center = ZoomFraming.dolly(from: before, to: (target, aim), atScale: scale, progress: arrived)

        return settled(center, scale: scale, timeline: timeline, at: time, cursor: track, crop: crop)
    }

    /// Where the camera looks while the whole video is held zoomed in and no zoom is
    /// deciding the shot.
    ///
    /// A zoom has a shot it was aimed at, and follows the pointer out of a dead zone round
    /// it. A held video has no shot of its own — the level is for the whole take — so what
    /// it aims at is where the pointer has *been* over the last second and a half, averaged
    /// with a kernel that falls to nothing at its far end. That is a camera operator
    /// panning after the action, a beat behind it, and it is continuous by construction:
    /// every term is a position on the path at a fixed distance behind now, and the ones
    /// leaving the window leave with no weight. Then the dead zone, exactly as a following
    /// zoom has it, so a fast pointer is kept in shot while the aim catches up.
    ///
    /// The same dials as a zoom's: `follow` scales how much the pointer may move the
    /// camera, `steadiness` how calm the aim is, `safeArea` how far the pointer may stray.
    /// A pointer nobody can see has no claim on the shot, so a hidden one leaves the
    /// camera in the middle.
    func heldShot(_ timeline: Timeline, at time: CMTime, cursor track: CursorTrack?,
                  crop: CGRect, scale: Double) -> CGPoint {
        let middle = CGPoint(x: 0.5, y: 0.5)
        let camera = timeline.camera.sanitised
        let override = timeline.cursorOverride(at: time)
        guard scale > 1, camera.follow > 0, timeline.cursor.isVisible, override.hiding < 1,
              let track, !track.isEmpty,
              let sourceTime = timeline.sourceTime(at: time) else { return middle }
        let claim = (1 - override.hiding) * camera.follow
        let half = ZoomFraming.halfSide(forScale: scale)

        var center = middle
        let window = max(Self.heldAimWindow, camera.steadiness * 2)
        var total = CGPoint.zero
        var weights = 0.0
        var age = 0.0
        while age < window {
            if let point = track.position(at: sourceTime.seconds - age) {
                let clamped = normalisedClamped(point, crop: crop)
                let weight = (1 - age / window) * (1 - age / window)
                total.x += clamped.x * weight
                total.y += clamped.y * weight
                weights += weight
            }
            age += Self.heldAimStep
        }
        if weights > 0 {
            let aim = CGPoint(x: total.x / weights, y: total.y / weights)
            center = CGPoint(x: middle.x + (aim.x - middle.x) * claim,
                             y: middle.y + (aim.y - middle.y) * claim)
        }

        if let averaged = track.averagePosition(at: sourceTime.seconds, window: camera.steadiness)
            .flatMap({ normalised($0, crop: crop) }) {
            center = nudged(center, toKeep: averaged, within: half * camera.safeArea, by: claim)
        }
        if let live = drawnPointer(timeline, at: time, sourceTime: sourceTime,
                                   track: track, override: override, crop: crop) {
            center = nudged(center, toKeep: live, within: half * camera.safeArea, by: claim)
        }
        return center
    }

    /// How far back a held camera looks for where to aim, in seconds, at the least.
    static let heldAimWindow = 1.5
    /// How finely it reads the path over that stretch.
    static let heldAimStep = 1.0 / 60

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
        //
        // Not below 1×, where the whole recording is on screen and no pointer can leave it.
        // The clamp would still move the centre there — and a pulled-back picture moves
        // with its centre — so it has to be skipped, not merely trusted to do nothing.
        if scale > 1, camera.follow > 0, timeline.cursor.isVisible, override.hiding < 1,
           let track, !track.isEmpty,
           let sourceTime = timeline.sourceTime(at: time),
           let live = pointerPoint(timeline, at: time, sourceTime: sourceTime,
                                   track: track, override: override)
               .map({ normalisedClamped($0, crop: crop) }) {
            // In full even on the way in. It binds only when the pointer would otherwise be
            // cut off — a pointer inside the shot costs the straight move nothing — and a
            // move bent for a frame is a better fault than a pointer that vanishes.
            center = nudged(center, toKeep: live, within: half * 0.98, by: 1 - override.hiding)
        }

        // Keep the camera inside the picture. Last, so it always wins — a pointer in the
        // corner is kept in shot by the frame reaching the corner, not by the frame sliding
        // off the picture to centre on it. Through `ZoomFraming`, which is also what the
        // framing box on the preview is drawn from, so the two cannot disagree. Below 1×
        // the same function keeps the shrunken picture inside the hole instead — see
        // `ZoomFraming.cameraCenter(_:scale:)`.
        return (scale, ZoomFraming.cameraCenter(center, scale: scale))
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

    private func blurLayers(_ timeline: Timeline, at time: CMTime, sourceSeconds: Double?) -> [BlurLayer] {
        let frame = pointFrame
        return timeline.blurs
            .filter { $0.contains(time) }
            // Where the mask is at this moment: a following mask moves, a still one is its
            // `rect` — carried with the picture when a resized window's content moved.
            // Asked here so the preview and the export cannot disagree about it.
            .map { BlurLayer(rect: $0.recordingRect(at: time, source: sourceSeconds, picture: picture, frame: frame),
                             style: $0.style, radius: $0.radius,
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
    ///
    /// A video that loops brings the pointer home over its last moments — see
    /// `PointerLoop` — and that is decided here too, so the pointer, the camera keeping it
    /// in shot and its motion blur all see the pointer travelling home rather than one of
    /// them seeing the recorded hand.
    func pointerPoint(_ timeline: Timeline,
                      at time: CMTime,
                      sourceTime: CMTime,
                      track: CursorTrack,
                      override: CursorOverride) -> CGPoint? {
        guard let point = recordedPointerPoint(timeline, at: time, sourceTime: sourceTime,
                                               track: track, override: override) else { return nil }
        let home = timeline.pointerLoopBlend(at: time)
        guard home > 0, let first = loopHome(timeline, track: track) else { return point }
        return CGPoint(x: point.x + (first.x - point.x) * home,
                       y: point.y + (first.y - point.y) * home)
    }

    /// Where the pointer is drawn on the video's first frame: where a loop brings it back
    /// to. `nil` when the video does not open on the recording — a title, or somebody
    /// else's footage — and there is no pointer to go back to.
    func loopHome(_ timeline: Timeline, track: CursorTrack) -> CGPoint? {
        guard let moment = timeline.mediaTime(at: .zero), moment.source == nil,
              let source = timeline.sourceTime(at: .zero) else { return nil }
        return recordedPointerPoint(timeline, at: .zero, sourceTime: source, track: track,
                                    override: timeline.cursorOverride(at: .zero))
    }

    /// The pointer as the recording and the Pointer lane put it, before a loop has any say.
    private func recordedPointerPoint(_ timeline: Timeline,
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
        var opacity = pointerOpacity(timeline, at: time, sourceTime: sourceTime, track: track)
        // A looping video brings the pointer's *presence* home as well as its place: a
        // pointer resting out of sight on the first frame and in view on the last would
        // blink at the seam however carefully it was walked back.
        let home = timeline.pointerLoopBlend(at: time)
        let firstSource = home > 0 && loopHome(timeline, track: track) != nil
            ? timeline.sourceTime(at: .zero) : nil
        if let firstSource {
            let first = pointerOpacity(timeline, at: .zero, sourceTime: firstSource, track: track)
            opacity += (first - opacity) * home
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
        // Past halfway home, the shape it will be on the first frame, for the reason the
        // opacity above is blended: the seam must not change what the pointer is.
        let shapeTime = firstSource.map { home >= 0.5 ? $0 : sourceTime } ?? sourceTime
        let shape = pointerShape(timeline.cursor, at: shapeTime.seconds, track: track)
        var layer = CursorLayer(position: position,
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
        if leans(timeline.cursor.appearance, shape: shape) {
            layer.tilt = swayTilt(timeline, at: time, track: track, crop: crop)
        }
        return layer
    }

    /// How much of the pointer is shown at a moment, before a loop has its say: faded by a
    /// stretch that hides it, and by resting, when the project asks for that.
    ///
    /// Multiplied rather than chosen between, so a stretch that hides the pointer and a
    /// pointer that has gone to rest cannot argue about which of them is in charge.
    private func pointerOpacity(_ timeline: Timeline, at time: CMTime, sourceTime: CMTime,
                                track: CursorTrack) -> Double {
        var opacity = 1 - min(1, max(0, timeline.cursorOverride(at: time).hiding))
        if timeline.cursor.hidesWhenIdle {
            opacity *= track.idleOpacity(at: sourceTime.seconds, after: timeline.cursor.idleDelay)
        }
        return opacity
    }

    /// Whether the pointer being drawn is one that can lean.
    ///
    /// An arrow and a hand are things with a point and a body, and leaning reads on them.
    /// An I-beam or a crosshair is a mark on the page; tilted, it looks like a different
    /// mark. The dot is round, and there is nothing to lean.
    private func leans(_ appearance: CursorStyle.Appearance, shape: CursorShape) -> Bool {
        switch appearance {
        case .largeArrow, .minimal, .dart, .dartBlack, .dartColour: true
        case .dot, .clicksOnly: false
        case .asRecorded, .macOS26, .macOS14, .macOS26White, .macOS14White, .macOS26Colour,
             .gradient, .neon, .frost, .classicKlik:
            CursorShapeKind(shape) == .arrow || CursorShapeKind(shape) == .pointingHand
        }
    }

    /// How far the arrow leans at this moment — see `PointerSway`.
    ///
    /// Read off the pointer *as drawn*, through `pointerPoint`, at moments of the edited
    /// video rather than of the recording: a hold stands the arrow up, a loop's journey
    /// home leans it, and a cut in the footage — a jump on the path — is recognised by
    /// `PointerSway` as a jump rather than as a flick. Timed to the microsecond, because
    /// the sway measures speed over steps of a 120th of a second and rounding each end of
    /// a step to a 600th would put a tenth of it in error.
    private func swayTilt(_ timeline: Timeline, at time: CMTime, track: CursorTrack, crop: CGRect) -> Double {
        let sway = timeline.cursor.sway
        guard sway.isEnabled, videoSize.width > 0 else { return 0 }
        let width = videoSize.width / displayScale * crop.width
        return sway.angle(at: time.seconds, position: { seconds in
            guard seconds >= 0 else { return nil }
            let moment = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
            guard let source = timeline.sourceTime(at: moment) else { return nil }
            return pointerPoint(timeline, at: moment, sourceTime: source, track: track,
                                override: timeline.cursorOverride(at: moment))
        }, frameWidth: width)
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
