import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// Marking where a click happened.
///
/// A screen recording is usually watched without sound, so a click has nothing to announce
/// it. Everything the renderer had was a quarter-second swell of the pointer, which is
/// genuinely easy to miss on a busy screen — so these check that a click puts something at
/// the place it happened, that the place is the right one, and that it goes away again.
struct ClickMarkTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)
    /// The recording is 1600×1000 pixels at 2×, so it is 800×500 points, and a sample in
    /// the middle of it is (400, 250).
    private let middleOfTheScreen = CGPoint(x: 400, y: 250)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2)
    }

    /// A plain edit with no padding, no rounding and no shadow, so the finished frame is
    /// the recording and a pixel is where the arithmetic says it is.
    private func timeline() -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = true
        timeline.cursor.smoothing = 0
        return timeline
    }

    /// A pointer that sits still in the middle, and clicks once at two seconds.
    private func track(at point: CGPoint? = nil, button: Int = 0) -> CursorTrack {
        let where_ = point ?? middleOfTheScreen
        let samples = stride(from: 0.0, through: 6.0, by: 0.1).map {
            CursorSample(t: $0, x: where_.x, y: where_.y, shape: .arrow)
        }
        return CursorTrack(samples: samples,
                           input: [.mouseDown(t: 2, button: button, x: where_.x, y: where_.y)])
    }

    // MARK: - The track

    @Test func aClickRemembersWhereItHappened() {
        let click = try? #require(track().clicks.first)
        #expect(click?.point == middleOfTheScreen)
        #expect(click?.t == 2)
        #expect(click?.isSecondary == false)
    }

    @Test func aRightClickIsToldApartFromALeftOne() {
        #expect(track(button: 1).clicks.first?.isSecondary == true)
    }

    /// Overlapping marks are kept apart. A double-click is two, and collapsing them would
    /// hide the second tap — which is the one somebody is watching for.
    @Test func aDoubleClickIsTwoMarks() {
        let samples = [CursorSample(t: 0, x: 400, y: 250, shape: .arrow)]
        let track = CursorTrack(samples: samples, input: [
            .mouseDown(t: 2, button: 0, x: 400, y: 250),
            .mouseDown(t: 2.18, button: 0, x: 400, y: 250),
        ])
        #expect(track.marks(at: 2.2).count == 2)
    }

    @Test func aMarkRunsFromNothingToFinishedAndThenStops() {
        let track = track()
        #expect(track.marks(at: 1.9).isEmpty, "before the click")
        #expect(track.marks(at: 2).first?.progress == 0)
        let halfway = try? #require(track.marks(at: 2.225).first)
        #expect((halfway?.progress ?? 0) > 0.45 && (halfway?.progress ?? 1) < 0.55)
        #expect(track.marks(at: 2.5).isEmpty, "and it is over")
    }

    // MARK: - What the scene says

    @Test func aClickBecomesALayerWhereItHappened() {
        let scene = builder().descriptor(for: timeline(), at: time(2.1), cursor: track())
        let click = try? #require(scene.clicks.first)
        // The middle of the recording, normalised.
        #expect(abs((click?.position.x ?? 0) - 0.5) < 0.001)
        #expect(abs((click?.position.y ?? 0) - 0.5) < 0.001)
    }

    @Test func thereIsNoLayerWhenNobodyHasClicked() {
        let scene = builder().descriptor(for: timeline(), at: time(1), cursor: track())
        #expect(scene.clicks.isEmpty)
    }

    @Test func turningTheHighlightOffLeavesTheSceneWithoutOne() {
        var timeline = timeline()
        timeline.cursor.clickHighlight = false
        let scene = builder().descriptor(for: timeline, at: time(2.1), cursor: track())
        #expect(scene.clicks.isEmpty)
    }

    /// A stretch where the pointer has been faded out is one where the viewer is being
    /// asked to look elsewhere, and a ring over it would be the only thing moving.
    @Test func aHiddenPointerMarksNoClicks() {
        var timeline = timeline()
        timeline.cursor.isVisible = false
        let scene = builder().descriptor(for: timeline, at: time(2.1), cursor: track())
        #expect(scene.clicks.isEmpty)
    }

    /// A click on footage the crop threw away is not on screen, so it is not marked.
    @Test func aClickOutsideTheCropIsNotMarked() {
        var timeline = timeline()
        timeline.style.crop = CropRect(rect: CGRect(x: 0, y: 0, width: 0.4, height: 1))
        let scene = builder().descriptor(for: timeline, at: time(2.1),
                                         cursor: track(at: CGPoint(x: 700, y: 250)))
        #expect(scene.clicks.isEmpty)
    }

    // MARK: - What actually lands in the frame

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func black() -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: videoSize))
    }

    /// The assertion that matters: something bright appears on a black recording, at a
    /// radius from the click rather than on top of it, and it is gone afterwards.
    @Test func aClickPutsARingOnTheFrame() throws {
        var timeline = timeline()
        timeline.cursor.isVisible = true
        // The pointer is drawn at the click too, and it is white — so the sample is taken
        // to the *left* of the click, where the ring reaches and the arrow does not.
        timeline.cursor.scale = 0.4
        timeline.cursor.clickSize = 0.3

        let renderer = SceneRenderer()
        let scene = builder().descriptor(for: timeline, at: time(2.2), cursor: track())
        let image = try #require(renderer.cgImage(for: scene, source: black()))

        let centre = CGPoint(x: Double(image.width) / 2, y: Double(image.height) / 2)
        let onTheRing = try #require(pixel(image,
                                           x: Int(centre.x - Double(image.height) * 0.3 * 0.42),
                                           y: Int(centre.y)))
        #expect(onTheRing.r > 40, "the ring is drawn to the left of the click")

        let after = builder().descriptor(for: timeline, at: time(3), cursor: track())
        let plain = try #require(renderer.cgImage(for: after, source: black()))
        let sameSpot = try #require(pixel(plain,
                                          x: Int(centre.x - Double(image.height) * 0.3 * 0.42),
                                          y: Int(centre.y)))
        #expect(sameSpot.r < 10, "and half a second later there is nothing there")
    }

    /// The setting has to reach the pixels, not only the descriptor.
    @Test func turningTheHighlightOffLeavesTheFrameAlone() throws {
        var timeline = timeline()
        timeline.cursor.isVisible = false      // no pointer either, so the frame is only the ring
        timeline.cursor.clickSize = 0.3

        let renderer = SceneRenderer()
        var on = timeline
        on.cursor.isVisible = true
        on.cursor.scale = 0.4
        on.cursor.clickHighlight = false

        let scene = builder().descriptor(for: on, at: time(2.2), cursor: track())
        let image = try #require(renderer.cgImage(for: scene, source: black()))
        let sample = try #require(pixel(image,
                                        x: Int(Double(image.width) / 2 - Double(image.height) * 0.3 * 0.42),
                                        y: image.height / 2))
        #expect(sample.r < 10)
    }
}
