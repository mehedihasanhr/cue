import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The picture softened while the camera moves fast, and only then — worked out from the
/// camera's path at the frame itself, so a scrubbed frame is the played one.
@Suite("Zoom motion blur")
struct CameraMotionBlurTests {
    private let videoSize = CGSize(width: 800, height: 500)

    /// One zoom: pushing in over the first half second, holding, and pulling out.
    private func timeline(motionBlur: Bool = true, instant: Bool = false) -> Timeline {
        var timeline = Timeline(sourceDuration: DressingFixtures.time(6))
        timeline.style.padding = 0.08
        timeline.style.shadowOpacity = 0
        timeline.style.cornerRadius = 0
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        timeline.cursor.isVisible = false
        timeline.camera.motionBlur = motionBlur
        var zoom = ZoomRegion(start: DressingFixtures.time(1), duration: DressingFixtures.time(3), scale: 2.5,
                              center: CGPoint(x: 0.3, y: 0.4), easing: .easeInOut,
                              transition: DressingFixtures.time(0.5), followsCursor: false)
        zoom.isInstant = instant
        timeline.zooms = [zoom]
        return timeline
    }

    private func scene(_ timeline: Timeline, at seconds: Double) -> SceneDescriptor {
        SceneBuilder(videoSize: videoSize).descriptor(for: timeline, at: DressingFixtures.time(seconds))
    }

    @Test("Pushing in streaks outwards, pulling out the other way, and in between nothing")
    func onlyWhileMoving() throws {
        let edit = timeline()
        let pushing = try #require(scene(edit, at: 1.25).cameraMotion, "half way through the push-in")
        #expect(pushing.growth > 0)
        let pulling = try #require(scene(edit, at: 3.75).cameraMotion, "half way through the pull-out")
        #expect(pulling.growth < 0)
        // The centre is off the middle, so the zoom also travels.
        #expect(hypot(pushing.travel.dx, pushing.travel.dy) > 0.5)

        #expect(scene(edit, at: 2.5).cameraMotion == nil, "held: the camera is still")
        #expect(scene(edit, at: 0.5).cameraMotion == nil, "before any zoom")
        #expect(scene(edit, at: 5).cameraMotion == nil, "after it")
    }

    @Test("Gentle: the streak is held to a few per cent however fast the camera goes")
    func capped() throws {
        var edit = timeline()
        edit.zooms[0].transition = DressingFixtures.time(0.05)
        let fast = try #require(scene(edit, at: 1.025).cameraMotion)
        #expect(abs(fast.growth) <= SceneBuilder.maximumGrowth + 1e-9)
        let shorter = min(scene(edit, at: 1.025).outputSize.width, scene(edit, at: 1.025).outputSize.height)
        #expect(hypot(fast.travel.dx, fast.travel.dy) <= shorter * SceneBuilder.maximumTravel + 1e-6)
    }

    @Test("Off means off")
    func switchedOff() {
        #expect(scene(timeline(motionBlur: false), at: 1.25).cameraMotion == nil)
    }

    @Test("A cut is not a movement: an instant zoom is never blurred")
    func instantZoomsAreNotBlurred() {
        let edit = timeline(instant: true)
        for seconds in [1.0, 1.0 + 1.0 / 60, 4.0, 4.0 - 1.0 / 60] {
            #expect(scene(edit, at: seconds).cameraMotion == nil, "at \(seconds)s")
        }
    }

    @Test("Scrubbing to a frame gives the frame playing to it gives")
    func stateless() {
        let edit = timeline()
        let builder = SceneBuilder(videoSize: videoSize)
        // Played: every frame in order up to 1.3 s.
        var played: SceneDescriptor?
        for frame in 0...78 {
            played = builder.descriptor(for: edit, at: CMTime(value: CMTimeValue(frame), timescale: 60))
        }
        // Scrubbed: straight there from somewhere else, with a different builder.
        _ = builder.descriptor(for: edit, at: DressingFixtures.time(3.9))
        let scrubbed = SceneBuilder(videoSize: videoSize).descriptor(for: edit, at: CMTime(value: 78, timescale: 60))
        #expect(played == scrubbed)
        #expect(scrubbed.cameraMotion != nil)
    }

    @Test("A preview-sized frame is streaked in proportion")
    func scaled() throws {
        let full = scene(timeline(), at: 1.25)
        let motion = try #require(full.cameraMotion)
        let half = try #require(full.scaled(by: 0.5).cameraMotion)
        #expect(abs(half.travel.dx - motion.travel.dx / 2) < 1e-9)
        #expect(half.growth == motion.growth)
        #expect(abs(half.center.x - motion.center.x / 2) < 1e-9)
    }

    /// Stripes, so there are edges for a blur to soften.
    private func stripes() -> CIImage {
        var image = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: videoSize))
        for index in stride(from: 0, to: Int(videoSize.width), by: 40) {
            image = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
                .cropped(to: CGRect(x: Double(index), y: 0, width: 20, height: videoSize.height))
                .composited(over: image)
        }
        return image
    }

    /// How many pixels along a row are neither black nor white — the soft edges.
    private func softPixels(_ pixels: DressingPixels, row: Int, from: Int, to: Int) -> Int {
        (from..<to).filter { x in
            let c = pixels.colour(x, row)
            let level = (c.r + c.g + c.b) / 3
            return level > 0.12 && level < 0.88
        }.count
    }

    @Test("And it shows: the stripes' edges are softer while the camera moves, and crisp when it holds")
    func pixels() throws {
        let moving = 1.25
        let on = try DressingFixtures.render(timeline(), at: moving, source: stripes(), videoSize: videoSize)
        let off = try DressingFixtures.render(timeline(motionBlur: false), at: moving, source: stripes(),
                                              videoSize: videoSize)
        #expect(on.scene.videoFrame == off.scene.videoFrame)
        let row = on.pixels.height / 2
        let frame = on.scene.visibleVideoFrame
        let blurred = softPixels(on.pixels, row: row, from: Int(frame.minX) + 4, to: Int(frame.maxX) - 4)
        let sharp = softPixels(off.pixels, row: row, from: Int(frame.minX) + 4, to: Int(frame.maxX) - 4)
        #expect(blurred > sharp + 10, "blurred \(blurred) soft pixels against \(sharp)")

        let held = try DressingFixtures.render(timeline(), at: 2.5, source: stripes(), videoSize: videoSize)
        let heldOff = try DressingFixtures.render(timeline(motionBlur: false), at: 2.5, source: stripes(),
                                                  videoSize: videoSize)
        #expect(held.pixels.bytes == heldOff.pixels.bytes, "a still camera draws exactly what it drew before")
    }
}
