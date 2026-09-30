import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Zooming out, as the renderer draws it: the framed recording shrinks inside the frame,
/// corners, shadow and all, and the background shows round it.
///
/// Stills only — nothing here writes a movie — so the suite runs alongside the others.
struct ZoomOutRenderTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 1)
    }

    /// One zoom out, held from 2.5 s to 5.5 s, on a white background with no padding.
    private func timeline(scale: Double = 0.5, center: CGPoint = CGPoint(x: 0.5, y: 0.5),
                          cornerRadius: Double = 0, wholeFrame: Bool = false) -> Timeline {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.style.background = .color(ColorValue(r: 1, g: 1, b: 1))
        timeline.style.padding = 0
        timeline.style.cornerRadius = cornerRadius
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = false
        timeline.camera.zoomsWholeFrame = wholeFrame
        timeline.zooms = [ZoomRegion(start: time(2), duration: time(4), scale: scale, center: center,
                                     easing: .easeInOut, transition: time(0.5), followsCursor: false)]
        return timeline
    }

    // MARK: - Where the picture goes

    /// The headline: at 0.5× the picture is half the size in each direction and sits in the
    /// middle of the frame — its frame, corners and all, rather than a magnified crop.
    @Test(arguments: [false, true])
    func atHalfThePictureIsHalfSizeInTheMiddle(wholeFrame: Bool) {
        let scene = builder().descriptor(for: timeline(wholeFrame: wholeFrame), at: time(4))
        #expect(abs(scene.zoom - 0.5) < 1e-9)
        let picture = scene.transformedVideoFrame
        #expect(abs(picture.width - scene.videoFrame.width / 2) < 0.5)
        #expect(abs(picture.height - scene.videoFrame.height / 2) < 0.5)
        #expect(abs(picture.midX - scene.videoFrame.midX) < 0.5)
        #expect(abs(picture.midY - scene.videoFrame.midY) < 0.5)
        #expect(scene.frameFollowsCamera)
        #expect(scene.visibleVideoFrame == picture)
        #expect(scene.pictureEdge == picture)
    }

    /// Aimed somewhere, the camera puts that point of the recording in the middle of the
    /// frame — which at 0.5× it can do anywhere without the picture leaving the hole.
    @Test func aimedAtAPointTheShrunkenPictureCentresOnIt() {
        let target = CGPoint(x: 0.25, y: 0.25)
        let scene = builder().descriptor(for: timeline(center: target), at: time(4))
        let picture = scene.transformedVideoFrame
        // Core Image's origin is bottom-left, so the recording's y runs the other way.
        let landed = CGPoint(x: picture.minX + target.x * picture.width,
                             y: picture.maxY - target.y * picture.height)
        #expect(abs(landed.x - scene.videoFrame.midX) < 0.5)
        #expect(abs(landed.y - scene.videoFrame.midY) < 0.5)
        #expect(scene.videoFrame.contains(picture))
    }

    /// Pushing in is untouched: the hole stays the hole unless the project asked for the
    /// whole frame to zoom.
    @Test func aZoomInStillMagnifiesInsideTheHole() {
        let scene = builder().descriptor(for: timeline(scale: 2), at: time(4))
        #expect(!scene.frameFollowsCamera)
        #expect(scene.visibleVideoFrame == scene.videoFrame)
        #expect(scene.pictureEdge == scene.videoFrame)
    }

    // MARK: - Pixels

    /// The background shows round the shrunken picture, and the picture is there in the
    /// middle.
    @Test func theBackgroundShowsRoundThePicture() throws {
        let scene = builder().descriptor(for: timeline(), at: time(4))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: red()))
        let picture = scene.transformedVideoFrame
        // Near each corner of the output: background.
        for (x, y) in [(20, 20), (image.width - 20, 20), (20, image.height - 20), (image.width - 20, image.height - 20)] {
            let shade = try #require(pixel(image, x: x, y: y))
            #expect(shade.r > 240 && shade.g > 240 && shade.b > 240, "background at \(x), \(y): \(shade)")
        }
        // The middle: the recording.
        let middle = try #require(pixel(image, x: image.width / 2, y: image.height / 2))
        #expect(middle.r > 200 && middle.g < 40, "picture in the middle: \(middle)")
        // Just inside and just outside the picture's left edge (rows run top-down in the
        // bitmap, but the middle row is the middle row either way).
        let inside = try #require(pixel(image, x: Int(picture.minX) + 4, y: image.height / 2))
        let outside = try #require(pixel(image, x: Int(picture.minX) - 4, y: image.height / 2))
        #expect(inside.r > 200 && inside.g < 40, "inside the edge: \(inside)")
        #expect(outside.g > 240, "outside the edge: \(outside)")
    }

    /// The shrunken picture's corners are rounded, in proportion to its new size.
    @Test func theShrunkenPictureKeepsItsRoundedCorners() throws {
        let scene = builder().descriptor(for: timeline(cornerRadius: 0.1), at: time(4))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: red()))
        let picture = scene.transformedVideoFrame
        // The very corner of the shrunken picture is cut away; a little way along its
        // diagonal is picture. Bitmap rows run top-down, so the top-left corner in the
        // bitmap is at the picture's maxY in Core Image's space.
        let top = image.height - Int(picture.maxY)
        let corner = try #require(pixel(image, x: Int(picture.minX) + 2, y: top + 2))
        let inward = try #require(pixel(image, x: Int(picture.minX) + 60, y: top + 60))
        #expect(corner.g > 200, "the corner is rounded off: \(corner)")
        #expect(inward.r > 200 && inward.g < 40, "and the picture is there further in: \(inward)")
    }

    // MARK: - Movement

    /// Into and out of the pull back, frame by frame: the picture's size and middle never
    /// step, and the camera is exactly at rest at both edges of the zoom. The bound is the
    /// eased ramp's fastest frame — half the picture over half a second, ease-in-out, peaks
    /// at a little over 3% a frame — with room to spare, and far below any jump.
    @Test func theMoveInAndOutIsContinuous() {
        let edit = timeline(center: CGPoint(x: 0.3, y: 0.7))
        let builder = builder()
        var previous: CGRect?
        for frame in Int(1.5 * 60)...Int(6.5 * 60) {
            let scene = builder.descriptor(for: edit, at: CMTime(value: CMTimeValue(frame), timescale: 60))
            let picture = scene.transformedVideoFrame
            if let previous {
                #expect(abs(picture.width - previous.width) < scene.videoFrame.width * 0.05,
                        "size stepped at frame \(frame)")
                #expect(abs(picture.midX - previous.midX) < scene.videoFrame.width * 0.05,
                        "middle stepped at frame \(frame)")
                #expect(abs(picture.midY - previous.midY) < scene.videoFrame.height * 0.05,
                        "middle stepped at frame \(frame)")
            }
            previous = picture
        }
        let before = builder.descriptor(for: edit, at: time(1.9))
        let after = builder.descriptor(for: edit, at: time(6.1))
        #expect(before.zoom == 1 && after.zoom == 1)
        #expect(before.transformedVideoFrame == before.videoFrame)
    }

    /// Gliding from a push in to a pull back travels through 1× without a jump, in scale
    /// or in where the picture is.
    @Test func aGlideFromAPushInToAPullBackIsContinuous() {
        var edit = timeline()
        edit.camera.glidesBetweenZooms = true
        edit.zooms = [ZoomRegion(start: time(1), duration: time(3), scale: 2, center: CGPoint(x: 0.3, y: 0.3),
                                 easing: .easeInOut, transition: time(0.5), followsCursor: false),
                      ZoomRegion(start: time(4.2), duration: time(3), scale: 0.5, center: CGPoint(x: 0.5, y: 0.5),
                                 easing: .easeInOut, transition: time(0.5), followsCursor: false)]
        let builder = builder()
        var previous: (zoom: Double, frame: CGRect)?
        var sawBothSides = (below: false, above: false)
        for frame in Int(3.3 * 60)...Int(4.9 * 60) {
            let scene = builder.descriptor(for: edit, at: CMTime(value: CMTimeValue(frame), timescale: 60))
            #expect(scene.zoom >= 0.5 - 1e-9 && scene.zoom <= 2 + 1e-9)
            if scene.zoom < 1 { sawBothSides.below = true }
            if scene.zoom > 1 { sawBothSides.above = true }
            if let previous {
                #expect(abs(scene.zoom - previous.zoom) < 0.1, "scale stepped at frame \(frame)")
                #expect(abs(scene.transformedVideoFrame.midX - previous.frame.midX) < scene.videoFrame.width * 0.05,
                        "picture jumped at frame \(frame)")
            }
            previous = (scene.zoom, scene.transformedVideoFrame)
        }
        #expect(sawBothSides.below && sawBothSides.above)
    }

    /// Overlapping, a pull back to 0.5× is as strong as a push in to 2× and beats a
    /// gentler push in outright.
    @Test func aDeepPullBackBeatsAGentlePushIn() {
        var edit = timeline()
        edit.zooms.append(ZoomRegion(start: time(2), duration: time(4), scale: 1.4,
                                     easing: .easeInOut, transition: time(0.5), followsCursor: false))
        let scene = builder().descriptor(for: edit, at: time(4))
        #expect(abs(scene.zoom - 0.5) < 1e-9)
    }

    // MARK: - Helpers

    private func red() -> CIImage {
        CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: videoSize))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
}
