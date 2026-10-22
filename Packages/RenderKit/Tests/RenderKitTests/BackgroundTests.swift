import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Resolving a background, and keeping the preview and the export honest about it.
struct BackgroundTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func timeline(_ background: FrameStyle.Background) -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.style.background = background
        timeline.cursor.isVisible = false
        return timeline
    }

    @Test func aModelGradientBecomesATwoStopRamp() {
        let from = ColorValue(r: 1, g: 0, b: 0)
        let to = ColorValue(r: 0, g: 0, b: 1)
        let layer = DefaultBackgroundResolver().layer(for: .gradient(from: from, to: to, angle: 0.25),
                                                      packageURL: nil)
        #expect(layer == .gradient(stops: [GradientStop(color: from, location: 0),
                                           GradientStop(color: to, location: 1)],
                                   angle: 0.25))
    }

    @Test func aWallpaperNobodyCanResolveIsVisiblyMissing() {
        let layer = DefaultBackgroundResolver().layer(for: .wallpaper(id: "cue:ocean"), packageURL: nil)
        #expect(layer == .missing, "a forgotten resolver must fail loudly, not quietly differently")
    }

    @Test func aPackageRelativeImageResolvesAgainstTheProject() {
        let package = URL(fileURLWithPath: "/tmp/Take.cuerec")
        let layer = DefaultBackgroundResolver().layer(for: .image(path: "Backgrounds/a.heic"),
                                                      packageURL: package)
        #expect(layer == .image(url: package.appendingPathComponent("Backgrounds/a.heic")))
    }

    @Test func anAbsoluteImagePathStillWorks() {
        // Projects written before the path was package-relative stored a full path.
        let layer = DefaultBackgroundResolver().layer(for: .image(path: "/tmp/old.heic"), packageURL: nil)
        #expect(layer == .image(url: URL(fileURLWithPath: "/tmp/old.heic")))
    }

    /// The promise the whole architecture rests on, and nothing tested it until now.
    @Test func twoBuildersWithTheSameInputsDescribeTheSameFrame() {
        let timeline = timeline(.gradient(from: ColorValue(r: 1, g: 0, b: 0),
                                          to: ColorValue(r: 0, g: 0, b: 1), angle: 0.25))
        let preview = SceneBuilder(videoSize: videoSize, displayScale: 2)
        let export = SceneBuilder(videoSize: videoSize, displayScale: 2)
        #expect(preview.descriptor(for: timeline, at: time(3))
            == export.descriptor(for: timeline, at: time(3)))
    }

    @Test func backgroundBlurIsAFractionOfTheShorterSide() {
        var timeline = timeline(.color(ColorValue(r: 0, g: 0, b: 0)))
        timeline.style.backgroundBlur = 0.02

        let small = SceneBuilder(videoSize: CGSize(width: 1_920, height: 1_080))
            .descriptor(for: timeline, at: .zero)
        let large = SceneBuilder(videoSize: CGSize(width: 3_840, height: 2_160))
            .descriptor(for: timeline, at: .zero)

        #expect(small.backgroundBlur == 1_080 * 0.02)
        // The same setting has to soften the picture by the same *proportion* at any
        // resolution, which a raw sigma did not.
        #expect(large.backgroundBlur == small.backgroundBlur * 2)
    }

    @Test func blurStaysProportionalThroughAnAspectChange() {
        var timeline = timeline(.color(ColorValue(r: 0, g: 0, b: 0)))
        timeline.style.backgroundBlur = 0.02
        timeline.style.aspect = .vertical9x16

        let scene = SceneBuilder(videoSize: videoSize).descriptor(for: timeline, at: .zero)
        #expect(abs(scene.backgroundBlur - min(scene.outputSize.width, scene.outputSize.height) * 0.02) < 1e-9)
    }

    // MARK: - The cache

    @Test func theSameBackgroundIsBuiltOnceAndThenReused() {
        let cache = BackgroundCache()
        var builds = 0
        let make: () -> CIImage = {
            builds += 1
            return CIImage(color: .red)
        }
        let size = CGSize(width: 800, height: 600)

        _ = cache.image(for: .color(ColorValue(r: 1, g: 0, b: 0)), size: size, blurSigma: 0, make: make)
        _ = cache.image(for: .color(ColorValue(r: 1, g: 0, b: 0)), size: size, blurSigma: 0, make: make)
        #expect(builds == 1, "an image background was being decoded from disk every frame")
    }

    @Test func changingTheBlurOrTheSizeIsADifferentBackground() {
        let cache = BackgroundCache()
        var builds = 0
        let make: () -> CIImage = { builds += 1; return CIImage(color: .red) }
        let layer = BackgroundLayer.color(ColorValue(r: 1, g: 0, b: 0))

        _ = cache.image(for: layer, size: CGSize(width: 800, height: 600), blurSigma: 0, make: make)
        _ = cache.image(for: layer, size: CGSize(width: 800, height: 600), blurSigma: 4, make: make)
        _ = cache.image(for: layer, size: CGSize(width: 400, height: 300), blurSigma: 4, make: make)
        #expect(builds == 3)
    }

    // MARK: - The two flags that used to do nothing

    /// Three samples a frame apart, so there is a frame *behind* the one asked about —
    /// velocity is measured by looking back, and at t = 0 there is nothing to look at.
    private func track(speedPerSecond: Double) -> CursorTrack {
        CursorTrack(samples: (0...2).map { step in
            .init(t: Double(step) / 30, x: 400 + speedPerSecond * Double(step) / 30, y: 250, shape: .arrow)
        })
    }

    private let aFrameIn = CMTime(value: 1, timescale: 30)

    @Test func motionBlurIsOffUntilItIsAskedFor() {
        var timeline = timeline(.color(ColorValue(r: 0, g: 0, b: 0)))
        timeline.cursor.isVisible = true
        timeline.cursor.smoothing = 0
        let scene = SceneBuilder(videoSize: videoSize)
            .descriptor(for: timeline, at: aFrameIn, cursor: track(speedPerSecond: 3_000))
        #expect(scene.cursor?.velocity == .zero)
    }

    @Test func aMovingPointerCarriesItsTravelWhenMotionBlurIsOn() throws {
        var timeline = timeline(.color(ColorValue(r: 0, g: 0, b: 0)))
        timeline.cursor.isVisible = true
        timeline.cursor.smoothing = 0
        timeline.cursor.motionBlur = true

        let scene = SceneBuilder(videoSize: videoSize)
            .descriptor(for: timeline, at: aFrameIn, cursor: track(speedPerSecond: 3_000))
        let cursor = try #require(scene.cursor)
        #expect(cursor.velocity.dx > 0, "the smear has to know which way the pointer went")
        #expect(cursor.velocity.dy == 0)
    }

    @Test func keepingThePointerSizeThroughAZoomIsTheDefault() throws {
        var timeline = timeline(.color(ColorValue(r: 0, g: 0, b: 0)))
        timeline.cursor.isVisible = true
        let scene = SceneBuilder(videoSize: videoSize)
            .descriptor(for: timeline, at: .zero, cursor: track(speedPerSecond: 0))
        #expect(try #require(scene.cursor).sizeFollowsZoom == false)

        timeline.cursor.sizeIsIndependentOfZoom = false
        let following = SceneBuilder(videoSize: videoSize)
            .descriptor(for: timeline, at: .zero, cursor: track(speedPerSecond: 0))
        #expect(try #require(following.cursor).sizeFollowsZoom)
    }
}
