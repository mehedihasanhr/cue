import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// What the project says about the pointer, reaching the frame.
struct PointerStyleTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let builder = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000), displayScale: 2)

    private func timeline(_ change: (inout CursorStyle) -> Void = { _ in }) -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        // Nothing round the picture and nothing cut off it, so the frame is the recording
        // and anything that is not black was drawn by what is being tested.
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.smoothing = 0
        change(&timeline.cursor)
        return timeline
    }

    /// Moves for the first second, is still until a click at 8 s. An I-beam for 50 ms at
    /// half a second in.
    private var track: CursorTrack {
        let samples = (0...1_000).map { step -> CursorSample in
            let t = Double(step) / 100
            let shape: CursorShape = t >= 0.5 && t < 0.55 ? .iBeam : .pointingHand
            return CursorSample(t: t, x: t < 1 ? 100 + t * 300 : 400, y: 250, shape: shape)
        }
        return CursorTrack(samples: samples, input: [.mouseDown(t: 8, button: 0, x: 400, y: 250)])
    }

    // MARK: - At rest

    @Test func aPointerLeftAloneIsStillDrawnUnlessToldOtherwise() {
        let scene = builder.descriptor(for: timeline(), at: time(5), cursor: track)
        #expect(scene.cursor?.opacity == 1)
    }

    @Test func aPointerLeftAloneGoesWhenTheProjectAsks() {
        let timeline = timeline { $0.hidesWhenIdle = true; $0.idleDelay = 2 }
        #expect(builder.descriptor(for: timeline, at: time(0.5), cursor: track).cursor?.opacity == 1, "moving")
        #expect(builder.descriptor(for: timeline, at: time(2.5), cursor: track).cursor?.opacity == 1, "inside the delay")
        #expect(builder.descriptor(for: timeline, at: time(5), cursor: track).cursor == nil, "gone")
        #expect(builder.descriptor(for: timeline, at: time(8), cursor: track).cursor?.opacity == 1, "back for the click")
    }

    /// The ring marks the place, and the place was clicked whether or not the pointer had
    /// gone to rest a moment before.
    @Test func aClickIsStillMarked() {
        let timeline = timeline { $0.hidesWhenIdle = true }
        #expect(builder.descriptor(for: timeline, at: time(8.1), cursor: track).clicks.count == 1)
    }

    // MARK: - Shape

    @Test func aFlickerOfShapeIsNotDrawn() {
        let steady = builder.descriptor(for: timeline { $0.steadiesShape = true }, at: time(0.52), cursor: track)
        let raw = builder.descriptor(for: timeline { $0.steadiesShape = false }, at: time(0.52), cursor: track)
        #expect(steady.cursor?.shape == .pointingHand)
        #expect(raw.cursor?.shape == .iBeam)
    }

    @Test func theArrowCanBeInsistedOn() {
        let scene = builder.descriptor(for: timeline { $0.alwaysArrow = true }, at: time(3), cursor: track)
        #expect(scene.cursor?.shape == .arrow)
    }

    // MARK: - Click styles

    @Test(arguments: CursorStyle.ClickStyle.allCases)
    func theClickStyleReachesTheFrame(_ style: CursorStyle.ClickStyle) {
        let scene = builder.descriptor(for: timeline { $0.clickStyle = style }, at: time(8.1), cursor: track)
        #expect(scene.clicks.first?.style == style)
    }

    private func fingerprint(_ scene: SceneDescriptor) throws -> [UInt8] {
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: scene.outputSize))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: black))
        var bytes = [UInt8](repeating: 0, count: 64 * 40 * 4)
        let context = try #require(CGContext(data: &bytes, width: 64, height: 40, bitsPerComponent: 8,
                                             bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 40))
        return bytes
    }

    /// Three styles, three pictures. If two of them drew the same thing the setting would
    /// be a switch that does nothing.
    @Test func everyClickStyleDrawsSomethingOfItsOwn() throws {
        var pictures: [[UInt8]] = []
        for style in CursorStyle.ClickStyle.allCases {
            var timeline = timeline { $0.clickStyle = style; $0.clickSize = 0.16 }
            timeline.cursor.isVisible = true
            var scene = builder.descriptor(for: timeline, at: time(8.2), cursor: track)
            // The mark alone: the pointer is the same in all three and would only dilute
            // the difference.
            scene.cursor = nil
            #expect(!scene.clicks.isEmpty)
            pictures.append(try fingerprint(scene))
        }
        #expect(Set(pictures).count == CursorStyle.ClickStyle.allCases.count)
        #expect(pictures.allSatisfy { $0.contains { $0 > 8 } }, "and every one of them drew something")
    }

    // MARK: - Seen on anything

    /// The darkest and the lightest the frame gets, read at full size: a thin ring is
    /// averaged away by anything smaller.
    private func tones(_ scene: SceneDescriptor, over page: CIColor) throws -> (darkest: UInt8, lightest: UInt8) {
        let source = CIImage(color: page).cropped(to: CGRect(origin: .zero, size: scene.outputSize))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: source))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var darkest = UInt8.max, lightest = UInt8.min
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            let low = min(bytes[pixel], bytes[pixel + 1], bytes[pixel + 2])
            let high = max(bytes[pixel], bytes[pixel + 1], bytes[pixel + 2])
            darkest = min(darkest, low)
            lightest = max(lightest, high)
        }
        return (darkest, lightest)
    }

    private func mark(_ style: CursorStyle.ClickStyle, ink: ColorValue, progress: Double) -> SceneDescriptor {
        var scene = builder.descriptor(for: timeline { $0.clickStyle = style; $0.clickSize = 0.16 },
                                       at: time(8.1), cursor: track)
        scene.cursor = nil
        scene.clicks = scene.clicks.map {
            ClickLayer(position: $0.position, progress: progress, color: ink, size: $0.size,
                       isSecondary: false, style: style)
        }
        return scene
    }

    /// The mark is white unless somebody changes it, and so is most of what is recorded.
    @Test(arguments: CursorStyle.ClickStyle.allCases)
    func aWhiteMarkShowsOnAWhitePage(_ style: CursorStyle.ClickStyle) throws {
        let white = ColorValue(r: 1, g: 1, b: 1, a: 1)
        let seen = try tones(mark(style, ink: white, progress: 0.35), over: .white)
        #expect(seen.darkest < 215, "something darker than the page was drawn")
    }

    @Test(arguments: CursorStyle.ClickStyle.allCases)
    func aBlackMarkShowsOnABlackPage(_ style: CursorStyle.ClickStyle) throws {
        let black = ColorValue(r: 0, g: 0, b: 0, a: 1)
        let seen = try tones(mark(style, ink: black, progress: 0.35), over: .black)
        #expect(seen.lightest > 40, "something lighter than the page was drawn")
    }

    /// The edge is made from the mark, so it is gone when the mark is.
    @Test(arguments: CursorStyle.ClickStyle.allCases)
    func theEdgeGoesWithTheMark(_ style: CursorStyle.ClickStyle) throws {
        let white = ColorValue(r: 1, g: 1, b: 1, a: 1)
        let seen = try tones(mark(style, ink: white, progress: 1), over: .white)
        #expect(seen.darkest >= 250)
    }

    /// A mark has finished by the time it says it has.
    @Test(arguments: CursorStyle.ClickStyle.allCases)
    func aMarkIsGoneWhenItIsOver(_ style: CursorStyle.ClickStyle) throws {
        var scene = builder.descriptor(for: timeline { $0.clickStyle = style }, at: time(8.2), cursor: track)
        scene.cursor = nil
        scene.clicks = scene.clicks.map {
            ClickLayer(position: $0.position, progress: 1, color: $0.color, size: $0.size,
                       isSecondary: false, style: style)
        }
        #expect(try fingerprint(scene).allSatisfy { $0 <= 8 || $0 == 255 })
    }
}
