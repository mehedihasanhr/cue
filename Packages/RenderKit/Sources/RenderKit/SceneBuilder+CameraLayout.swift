import CoreGraphics
import CoreMedia
import Foundation
import TimelineKit

/// Where the picture and the camera go in each camera layout, and how one becomes another.
///
/// Arithmetic on sizes, with no drawing in it, so it can be tested without a GPU — and so
/// the preview and the export, which both build their frames here, cannot place the camera
/// in two different places.
extension SceneBuilder {
    /// The picture and the camera in one layout.
    struct CameraArrangement: Equatable {
        /// Where the recording sits, in output pixels with Core Image's bottom-left origin —
        /// `SceneDescriptor.videoFrame`'s convention.
        var videoFrame: CGRect
        var videoOpacity: Double
        /// Where the camera sits, normalised to the output with a top-left origin —
        /// `WebcamLayer.rect`'s convention.
        var camera: CGRect
        /// In output pixels.
        var cameraCornerRadius: Double
        var cameraOpacity: Double

        /// Part of the way from this arrangement to another, every number on a straight
        /// line.
        ///
        /// The two ends are returned as they are rather than computed, so a layout that has
        /// fully arrived is the layout's own numbers to the last bit — a bubble with no
        /// camera lane in the project must be exactly the bubble it always was.
        func blended(with other: CameraArrangement, by progress: Double) -> CameraArrangement {
            if progress <= 0 { return self }
            if progress >= 1 { return other }
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
            func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
                CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY),
                       width: mix(a.width, b.width), height: mix(a.height, b.height))
            }
            return CameraArrangement(videoFrame: mix(videoFrame, other.videoFrame),
                                     videoOpacity: mix(videoOpacity, other.videoOpacity),
                                     camera: mix(camera, other.camera),
                                     cameraCornerRadius: mix(cameraCornerRadius, other.cameraCornerRadius),
                                     cameraOpacity: mix(cameraOpacity, other.cameraOpacity))
        }
    }

    /// The gap between the screen and the camera side by side, as a fraction of the
    /// shorter output side. Enough to read as two things.
    static let splitGap = 0.025
    /// The screen's share of the width (or, in a tall frame, the height) side by side. The
    /// screen is usually what is being explained, so it gets the larger part.
    static let splitScreenShare = 0.68
    /// How small the bubble goes as it fades out, so hiding it reads as it going away
    /// rather than as a dissolve.
    static let hiddenScale = 0.8

    /// The picture's frame, how much of it shows, and the camera, at one moment.
    ///
    /// With the camera off — or on, in a project with no camera lane — this is the picture
    /// where the padding put it and the bubble where its settings put it, untouched.
    func cameraStage(_ timeline: Timeline, at time: CMTime, output: CGSize, inset: Double,
                     source: CGSize, picture: CGRect,
                     zoom: Double) -> (videoFrame: CGRect, videoOpacity: Double, webcam: WebcamLayer?) {
        guard let bubble = webcamLayer(timeline, output: output, zoom: zoom) else {
            return (picture, 1, nil)
        }
        let state = timeline.cameraLayout(at: time)
        if state.isSteady, state.to == .bubble { return (picture, 1, bubble) }

        func arrangement(_ layout: CameraLayout) -> CameraArrangement {
            cameraArrangement(layout, bubble: bubble, picture: picture, output: output,
                              inset: inset, source: source, timeline: timeline)
        }
        let settled = state.isSteady
            ? arrangement(state.to)
            : arrangement(state.from).blended(with: arrangement(state.to), by: state.progress)

        var camera = bubble
        camera.rect = settled.camera
        camera.cornerRadius = settled.cameraCornerRadius
        camera.opacity = settled.cameraOpacity
        camera.isBubble = [.bubble, .hidden].contains(state.from) && [.bubble, .hidden].contains(state.to)
        // Gone is gone: no layer at all rather than a transparent one, for the reason
        // `cursorLayer` gives — and so a stretch with the camera hidden describes exactly
        // the frame a project with the camera off does.
        let webcam = settled.cameraOpacity > 0.001 ? camera : nil
        return (settled.videoFrame, settled.videoOpacity, webcam)
    }

    /// Where everything goes in one layout.
    func cameraArrangement(_ layout: CameraLayout, bubble: WebcamLayer, picture: CGRect,
                           output: CGSize, inset: Double, source: CGSize,
                           timeline: Timeline) -> CameraArrangement {
        let standard = CameraArrangement(videoFrame: picture, videoOpacity: 1,
                                         camera: bubble.rect, cameraCornerRadius: bubble.cornerRadius,
                                         cameraOpacity: 1)
        // The space inside the padding: what the picture is fitted into, and what the
        // other layouts divide up.
        let available = CGRect(x: inset, y: inset,
                               width: max(1, output.width - inset * 2),
                               height: max(1, output.height - inset * 2))
        let corners = timeline.style.cornerRadius

        switch layout {
        case .bubble:
            return standard

        case .hidden:
            var hidden = standard
            let shrunk = CGSize(width: bubble.rect.width * Self.hiddenScale,
                                height: bubble.rect.height * Self.hiddenScale)
            hidden.camera = CGRect(x: bubble.rect.midX - shrunk.width / 2,
                                   y: bubble.rect.midY - shrunk.height / 2,
                                   width: shrunk.width, height: shrunk.height)
            hidden.cameraCornerRadius = bubble.cornerRadius * Self.hiddenScale
            hidden.cameraOpacity = 0
            return hidden

        case .cameraOnly:
            // The camera takes the picture's place and the picture's style: inside the
            // padding, with the frame's corners. With no padding that is the whole frame.
            return CameraArrangement(videoFrame: picture, videoOpacity: 0,
                                     camera: normalised(available, in: output),
                                     cameraCornerRadius: Double(min(available.width, available.height)) * corners,
                                     cameraOpacity: 1)

        case .sideBySide:
            let split = sideBySide(available: available, output: output, source: source,
                                   cameraFirst: cameraGoesFirst(timeline.webcam, output: output),
                                   style: timeline.style)
            let radius = Double(min(split.screen.width, split.screen.height)) * corners
            return CameraArrangement(videoFrame: flipped(split.screen, in: output), videoOpacity: 1,
                                     camera: normalised(split.camera, in: output),
                                     cameraCornerRadius: radius,
                                     cameraOpacity: 1)
        }
    }

    /// The screen and the camera beside each other, in output pixels with a top-left
    /// origin.
    ///
    /// Across a wide frame, one above the other in a tall one. The screen is fitted into
    /// its share keeping its shape; the camera takes the rest of the row, as tall as the
    /// screen (or, stacked, as wide), and never wider than it is tall — a camera pane
    /// stretched into a letterbox is mostly wall. The pair is centred together.
    ///
    /// What is fitted is the screen *as it is framed*: the picture with a window's bar
    /// above it or a phone round it, as `framingDescriptor` fits it into the padding. The
    /// bare picture used to be fitted, and the dressing then spilled out of its share — a
    /// handset's bezel across the gap and under the camera beside it, a bar up into the
    /// camera stacked above it. The camera's pane lines up with the whole of it.
    func sideBySide(available: CGRect, output: CGSize, source: CGSize,
                    cameraFirst: Bool, style: FrameStyle? = nil) -> (screen: CGRect, camera: CGRect) {
        let shorter = min(output.width, output.height)
        let gap = shorter * Self.splitGap
        let source = CGSize(width: max(1, source.width), height: max(1, source.height))
        let dressing = style.map { Self.dressing(of: source, style: $0) }
            ?? (size: source, picture: CGRect(origin: .zero, size: source))
        let whole = CGSize(width: max(1, dressing.size.width), height: max(1, dressing.size.height))

        // The picture inside the framed screen's rectangle, both top-left origin.
        func placed(_ frame: CGRect, fit: Double) -> CGRect {
            CGRect(x: frame.minX + dressing.picture.minX * fit, y: frame.minY + dressing.picture.minY * fit,
                   width: dressing.picture.width * fit, height: dressing.picture.height * fit)
        }

        if available.width >= available.height {
            let budget = (available.width - gap) * Self.splitScreenShare
            let fit = min(budget / whole.width, available.height / whole.height)
            let screen = CGSize(width: whole.width * fit, height: whole.height * fit)
            let cameraWidth = max(1, min(available.width - gap - screen.width, screen.height))
            let total = screen.width + gap + cameraWidth
            let left = available.minX + (available.width - total) / 2
            let top = available.minY + (available.height - screen.height) / 2
            let screenX = cameraFirst ? left + cameraWidth + gap : left
            let cameraX = cameraFirst ? left : left + screen.width + gap
            return (placed(CGRect(x: screenX, y: top, width: screen.width, height: screen.height), fit: fit),
                    CGRect(x: cameraX, y: top, width: cameraWidth, height: screen.height))
        } else {
            let budget = (available.height - gap) * Self.splitScreenShare
            let fit = min(available.width / whole.width, budget / whole.height)
            let screen = CGSize(width: whole.width * fit, height: whole.height * fit)
            let cameraHeight = max(1, min(available.height - gap - screen.height, screen.width))
            let total = screen.height + gap + cameraHeight
            let top = available.minY + (available.height - total) / 2
            let left = available.minX + (available.width - screen.width) / 2
            let screenY = cameraFirst ? top + cameraHeight + gap : top
            let cameraY = cameraFirst ? top : top + screen.height + gap
            return (placed(CGRect(x: left, y: screenY, width: screen.width, height: screen.height), fit: fit),
                    CGRect(x: left, y: cameraY, width: screen.width, height: cameraHeight))
        }
    }

    /// A picture of `size` with what the style draws round it: the whole thing's size, and
    /// where the picture sits in it, top-left origin. The arithmetic `framingDescriptor`
    /// fits into the padding — a window's bar a fraction of the picture's shorter side
    /// above it, a handset centred on it — and linear in `size`.
    static func dressing(of size: CGSize, style: FrameStyle) -> (size: CGSize, picture: CGRect) {
        if let device = DeviceLayer(style.chrome, pictureSize: size) {
            let body = DeviceGeometry(device, around: CGRect(origin: .zero, size: size)).body
            // `body` is in Core Image's way up, round a picture at the origin.
            return (body.size, CGRect(x: -body.minX, y: body.maxY - size.height,
                                      width: size.width, height: size.height))
        }
        let bar = SceneRenderer.barFraction(for: style.chrome.kind) * min(size.width, size.height)
        return (CGSize(width: size.width, height: size.height + bar),
                CGRect(x: 0, y: bar, width: size.width, height: size.height))
    }

    /// Whether the camera takes the left (or top) side of a split: the side the bubble is
    /// parked on, so going side by side moves the face the short way.
    func cameraGoesFirst(_ webcam: WebcamSettings, output: CGSize) -> Bool {
        let wide = output.width >= output.height
        switch webcam.corner {
        case .topLeft: return true
        case .bottomLeft: return wide
        case .topRight: return !wide
        case .bottomRight: return false
        case .custom: return wide ? webcam.position.x < 0.5 : webcam.position.y < 0.5
        }
    }

    /// Output pixels, top-left origin, to a fraction of the output.
    private func normalised(_ rect: CGRect, in output: CGSize) -> CGRect {
        CGRect(x: rect.minX / output.width, y: rect.minY / output.height,
               width: rect.width / output.width, height: rect.height / output.height)
    }

    /// Top-left origin to Core Image's bottom-left, in output pixels.
    private func flipped(_ rect: CGRect, in output: CGSize) -> CGRect {
        CGRect(x: rect.minX, y: output.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The pointer and the click marks belong to the screen, and fade with it.
    func faded(_ cursor: CursorLayer?, by opacity: Double) -> CursorLayer? {
        guard opacity < 1 else { return cursor }
        guard var cursor, opacity > 0.001 else { return nil }
        cursor.opacity *= opacity
        return cursor.opacity > 0.001 ? cursor : nil
    }

    func faded(_ clicks: [ClickLayer], by opacity: Double) -> [ClickLayer] {
        guard opacity < 1 else { return clicks }
        guard opacity > 0.001 else { return [] }
        return clicks.map { click in
            var click = click
            click.color.a *= opacity
            return click
        }
    }
}
