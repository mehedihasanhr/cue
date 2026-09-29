import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// A window round the picture: room made for it inside the padding, drawn where that room
/// is, rounded where the picture's corners were, and carried with the camera.
@Suite("Window frames")
struct WindowChromeTests {
    private let videoSize = CGSize(width: 1_600, height: 1_000)
    private let red = ColorValue(r: 1, g: 0, b: 0)
    private let blue = ColorValue(r: 0, g: 0, b: 1)

    private func timeline(_ kind: WindowChrome.Kind, appearance: WindowChrome.Appearance = .light) -> Timeline {
        var timeline = Timeline(sourceDuration: DressingFixtures.time(20))
        timeline.style.padding = 0.1
        timeline.style.cornerRadius = 0.03
        timeline.style.shadowOpacity = 0
        timeline.style.background = .color(blue)
        timeline.style.chrome = WindowChrome(kind: kind, appearance: appearance)
        timeline.cursor.isVisible = false
        return timeline
    }

    private func scene(_ timeline: Timeline, at seconds: Double = 1) -> SceneDescriptor {
        SceneBuilder(videoSize: videoSize).descriptor(for: timeline, at: DressingFixtures.time(seconds))
    }

    private func render(_ timeline: Timeline, at seconds: Double = 1) throws -> (SceneDescriptor, DressingPixels) {
        try DressingFixtures.render(timeline, at: seconds, source: DressingFixtures.flat(red, size: videoSize),
                                    videoSize: videoSize)
    }

    /// A rectangle in Core Image's bottom-left space, as whole pixels from the top.
    private func top(_ y: Double, in scene: SceneDescriptor) -> Int {
        Int((scene.outputSize.height - y).rounded(.down))
    }

    // MARK: - Room for it

    @Test("Without a window the picture is exactly where it always was")
    func noWindowNoChange() {
        let scene = scene(timeline(.none))
        #expect(scene.chrome == nil)
        #expect(scene.chromeBarFrame == nil)
        #expect(scene.videoFrame == CGRect(x: 160, y: 100, width: 1_280, height: 800))
    }

    @Test("The picture and its bar fit together inside the padding, centred, the picture keeping its shape")
    func windowFitsThePadding() throws {
        for kind in [WindowChrome.Kind.window, .browser] {
            let scene = scene(timeline(kind))
            let bar = try #require(scene.chromeBarFrame)
            let window = scene.videoFrame.union(bar)
            #expect(abs(window.height - 800) < 0.5, "the window fills the padded height exactly")
            #expect(window.width <= 1_400.5)
            #expect(abs(window.midY - 500) < 0.5, "centred as a whole")
            #expect(abs(window.midX - 800) < 0.5)
            #expect(abs(scene.videoFrame.width / scene.videoFrame.height - 1.6) < 0.001)
            #expect(abs(bar.minY - scene.videoFrame.maxY) < 0.001, "the bar sits on the picture")
            #expect(abs(bar.width - scene.videoFrame.width) < 0.001)
            let fraction = SceneRenderer.barFraction(for: kind)
            #expect(abs(bar.height - fraction * scene.videoFrame.height) < 0.001)
        }
        #expect(SceneRenderer.barFraction(for: .browser) > SceneRenderer.barFraction(for: .window))
    }

    // MARK: - Drawn

    @Test("A light window: a pale bar, three dots, square corners where it meets the picture, rounded ones outside")
    func lightWindowPixels() throws {
        let (scene, pixels) = try render(timeline(.window))
        let bar = try #require(scene.chromeBarFrame)
        let barRow = top(bar.midY, in: scene)

        #expect(pixels.isClose(Int(bar.midX + bar.width * 0.3), barRow,
                               to: ColorValue(r: 0.93, g: 0.93, b: 0.94), within: 0.02),
                "the bar: \(pixels.colour(Int(bar.midX + bar.width * 0.3), barRow))")

        let diameter = bar.height * 0.27
        let radius = scene.cornerRadius
        let firstDot = bar.minX + max(diameter * 1.1, radius * 0.6) + diameter / 2
        #expect(pixels.isClose(Int(firstDot), barRow, to: ColorValue(r: 1, g: 0.37, b: 0.34), within: 0.05),
                "the first dot: \(pixels.colour(Int(firstDot), barRow))")
        let thirdDot = firstDot + 2 * diameter * 1.68
        #expect(pixels.isClose(Int(thirdDot), barRow, to: ColorValue(r: 0.16, g: 0.79, b: 0.25), within: 0.05),
                "the third dot: \(pixels.colour(Int(thirdDot), barRow))")

        let left = Int(scene.videoFrame.minX) + 1
        // The picture's top corner meets the bar, so it is square: picture right in it.
        #expect(pixels.isClose(left, top(scene.videoFrame.maxY, in: scene) + 1, to: red))
        // Its bottom corner is still rounded: background there.
        #expect(pixels.isClose(left, top(scene.videoFrame.minY, in: scene) - 2, to: blue))
        // And the bar's own top corner is rounded like the picture's used to be.
        #expect(pixels.isClose(left, top(bar.maxY, in: scene) + 1, to: blue))
    }

    @Test("A border under a bar keeps an even width into the square corners")
    func borderUnderTheBar() throws {
        var edit = timeline(.window)
        edit.style.borderWidth = 0.01
        edit.style.borderColor = .white
        let (scene, pixels) = try render(edit)
        let width = try #require(scene.border?.width)
        let left = scene.videoFrame.minX
        let topRow = top(scene.videoFrame.maxY, in: scene)
        // Just inside the rim, diagonally in from the square corner: picture, not a rim
        // that has thickened into a curve the corner no longer has.
        let x = Int(left + width + 3), y = topRow + Int(width + 3)
        #expect(pixels.isClose(x, y, to: red), "\(pixels.colour(x, y))")
        #expect(pixels.isClose(Int(left + width / 2), topRow + 30, to: .white), "the rim itself is there")
    }

    @Test("A dark window has a dark bar")
    func darkWindow() throws {
        let (scene, pixels) = try render(timeline(.window, appearance: .dark))
        let bar = try #require(scene.chromeBarFrame)
        #expect(pixels.isClose(Int(bar.midX), top(bar.midY, in: scene),
                               to: ColorValue(r: 0.17, g: 0.17, b: 0.19), within: 0.02))
    }

    @Test("A browser has an address field in the middle of its bar")
    func browserField() throws {
        let (scene, pixels) = try render(timeline(.browser))
        let bar = try #require(scene.chromeBarFrame)
        let row = top(bar.midY, in: scene)
        // Inside the field, clear of the short rule standing in for the address.
        #expect(pixels.isClose(Int(bar.midX - bar.width * 0.2), row,
                               to: ColorValue(r: 0.85, g: 0.85, b: 0.87), within: 0.02),
                "the field: \(pixels.colour(Int(bar.midX - bar.width * 0.2), row))")
        // And the bar either side of it.
        #expect(pixels.isClose(Int(bar.maxX - bar.width * 0.05), row,
                               to: ColorValue(r: 0.93, g: 0.93, b: 0.94), within: 0.02))
    }

    @Test("The bar casts the shadow with the picture")
    func shadowIncludesTheBar() throws {
        let scene = scene(timeline(.window))
        let bar = try #require(scene.chromeBarFrame)
        #expect(abs(scene.shadowCaster.maxY - bar.maxY) < 0.001)
        #expect(abs(scene.shadowCaster.minY - scene.videoFrame.minY) < 0.001)
    }

    // MARK: - With the camera

    private func zoomed(_ timeline: Timeline, wholeFrame: Bool) -> Timeline {
        var timeline = timeline
        timeline.camera.zoomsWholeFrame = wholeFrame
        timeline.zooms = [ZoomRegion(start: .zero, duration: DressingFixtures.time(10), scale: 2,
                                     center: CGPoint(x: 0.5, y: 0.5), easing: .linear,
                                     transition: DressingFixtures.time(0.1), followsCursor: false)]
        return timeline
    }

    @Test("When the whole frame zooms the bar grows and travels with the picture")
    func barFollowsAWholeFrameZoom() throws {
        let scene = scene(zoomed(timeline(.window), wholeFrame: true), at: 5)
        let bar = try #require(scene.chromeBarFrame)
        let barHeight = try #require(scene.chrome?.barHeight)
        #expect(abs(bar.height - barHeight * 2) < 0.001)
        #expect(abs(bar.minY - scene.transformedVideoFrame.maxY) < 0.001)
    }

    @Test("When only the contents zoom the bar stays put above the hole")
    func barStaysForAnInnerZoom() throws {
        let scene = scene(zoomed(timeline(.window), wholeFrame: false), at: 5)
        let bar = try #require(scene.chromeBarFrame)
        let barHeight = try #require(scene.chrome?.barHeight)
        #expect(abs(bar.height - barHeight) < 0.001)
        #expect(abs(bar.minY - scene.videoFrame.maxY) < 0.001)
    }

    /// The fix that came with this: rounding the magnified picture put its curves out past
    /// the hole, where they were cut off, so the corners went square during every zoom.
    @Test("An inner zoom keeps the frame's corners rounded")
    func innerZoomKeepsRoundedCorners() throws {
        let (scene, pixels) = try render(zoomed(timeline(.none), wholeFrame: false), at: 5)
        #expect(scene.zoom == 2)
        let left = Int(scene.videoFrame.minX) + 1
        #expect(pixels.isClose(left, top(scene.videoFrame.maxY, in: scene) + 1, to: blue),
                "the top corner is background: \(pixels.colour(left, top(scene.videoFrame.maxY, in: scene) + 1))")
        #expect(pixels.isClose(left, top(scene.videoFrame.minY, in: scene) - 2, to: blue))
        #expect(pixels.isClose(Int(scene.videoFrame.midX), Int(scene.outputSize.height / 2), to: red))
    }

    @Test("A preview-sized frame has a proportionally smaller bar")
    func scaledDescriptor() throws {
        let scene = scene(timeline(.browser))
        let half = scene.scaled(by: 0.5)
        let full = try #require(scene.chromeBarFrame)
        let small = try #require(half.chromeBarFrame)
        #expect(abs(small.height - full.height / 2) < 0.001)
        #expect(abs(small.minY - full.minY / 2) < 0.5)
    }
}
