import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
import UniformTypeIdentifiers
@testable import RenderKit

/// The pressed keys as pixels: drawn when they should be, absent when not, inside the
/// frame wherever they are put, clear of the caption, and readable on anything.
struct KeycapRenderTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private let output = CGSize(width: 640, height: 360)

    private func scene(background: Double, keys: KeyLayer?, caption: CaptionLayer? = nil) -> SceneDescriptor {
        var scene = SceneDescriptor(outputSize: output,
                                    background: .color(ColorValue(r: background, g: background, b: background)),
                                    videoFrame: CGRect(origin: .zero, size: output))
        scene.keys = keys
        scene.caption = caption
        return scene
    }

    private func layer(_ caps: [String] = ["⌘", "⇧", "K"], count: Int = 1,
                       look: KeyStyle.Look = .keycaps, position: KeyStyle.Position = .bottomCenter,
                       size: Double = 0.1, scale: Double = 1, opacity: Double = 1,
                       clears: [CaptionLayer] = []) -> KeyLayer {
        KeyLayer(caps: caps, count: count, look: look, position: position, size: size,
                 opacity: opacity, scale: scale, clears: clears)
    }

    private func caption(_ position: CaptionStyle.Position = .bottom) -> CaptionLayer {
        CaptionLayer(text: "Press the shortcut to open the palette", fontSize: 0.06, color: .white,
                     backgroundOpacity: 0.6, position: position, margin: 0.06)
    }

    /// The frame as bytes, RGBA, top row first.
    private func pixels(_ scene: SceneDescriptor) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let image = try #require(SceneRenderer().cgImage(for: scene, source: nil))
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        return (bytes, width, height)
    }

    /// Where the pixels that differ from a plain frame are, as a box with a top-left
    /// origin, and how many of them are dark and how many light.
    private func ink(_ scene: SceneDescriptor, against plain: SceneDescriptor)
        throws -> (bounds: CGRect?, dark: Int, light: Int) {
        let drawn = try pixels(scene)
        let base = try pixels(plain)
        var minX = drawn.width, minY = drawn.height, maxX = -1, maxY = -1
        var dark = 0, light = 0
        for y in 0..<drawn.height {
            for x in 0..<drawn.width {
                let index = (y * drawn.width + x) * 4
                let difference = abs(Int(drawn.bytes[index]) - Int(base.bytes[index]))
                    + abs(Int(drawn.bytes[index + 1]) - Int(base.bytes[index + 1]))
                    + abs(Int(drawn.bytes[index + 2]) - Int(base.bytes[index + 2]))
                guard difference > 60 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                let luminance = (Int(drawn.bytes[index]) * 299 + Int(drawn.bytes[index + 1]) * 587
                                 + Int(drawn.bytes[index + 2]) * 114) / 1000
                if luminance < 90 { dark += 1 }
                if luminance > 165 { light += 1 }
            }
        }
        guard maxX >= 0 else { return (nil, 0, 0) }
        return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), dark, light)
    }

    // MARK: - Drawn, or not

    @Test func theKeysAreDrawnWhereTheyWereAsked() throws {
        let drawn = try ink(scene(background: 0.5, keys: layer()), against: scene(background: 0.5, keys: nil))
        let bounds = try #require(drawn.bounds)
        #expect(bounds.width > 40 && bounds.height > 20)
        #expect(abs(bounds.midX - output.width / 2) < 4, "centred")
        #expect(bounds.maxY > output.height * 0.8, "at the bottom")
        #expect(bounds.maxY <= output.height - 4, "and inside it")
    }

    @Test func withoutKeysTheFrameIsTheFrame() throws {
        let plain = try pixels(scene(background: 0.5, keys: nil))
        let again = try pixels(scene(background: 0.5, keys: nil))
        #expect(plain.bytes == again.bytes)
        #expect(try ink(scene(background: 0.5, keys: layer([])), against: scene(background: 0.5, keys: nil)).bounds == nil,
                "nothing to draw draws nothing")
    }

    @Test func fadedOutKeysDrawNothing() throws {
        let drawn = try ink(scene(background: 0.5, keys: layer(opacity: 0)), against: scene(background: 0.5, keys: nil))
        #expect(drawn.bounds == nil)
    }

    @Test(arguments: KeyStyle.Position.allCases)
    func everyPositionIsInsideTheFrame(_ position: KeyStyle.Position) throws {
        for look in KeyStyle.Look.allCases {
            let drawn = try ink(scene(background: 0.5, keys: layer(look: look, position: position)),
                                against: scene(background: 0.5, keys: nil))
            let bounds = try #require(drawn.bounds, "\(look) at \(position)")
            let frame = CGRect(origin: .zero, size: output).insetBy(dx: 2, dy: 2)
            #expect(frame.contains(bounds), "\(look) at \(position): \(bounds)")
            // In the third of the frame it was asked for. The ink box is measured with a
            // top-left origin.
            #expect(position.isTop ? bounds.midY < output.height / 3 : bounds.midY > output.height * 2 / 3,
                    "\(look) at \(position): \(bounds)")
            switch position.horizontal {
            case 0: #expect(bounds.midX < output.width / 3, "\(position): \(bounds)")
            case 1: #expect(bounds.midX > output.width * 2 / 3, "\(position): \(bounds)")
            default: #expect(abs(bounds.midX - output.width / 2) < 4, "\(position): \(bounds)")
            }
        }
    }

    @Test func keysTooBigForTheirCornerAreStillAllInShot() throws {
        let huge = layer(["⌃", "⌥", "⇧", "⌘", "Space"], count: 12, position: .bottomRight, size: 0.14)
        let drawn = try ink(scene(background: 0.5, keys: huge), against: scene(background: 0.5, keys: nil))
        let bounds = try #require(drawn.bounds)
        #expect(CGRect(origin: .zero, size: output).contains(bounds))
    }

    // MARK: - Clear of the caption

    @Test(arguments: [KeyStyle.Position.bottomCenter, .bottomLeft, .topCenter, .topRight])
    func theKeysSitClearOfACaptionOnTheSameEdge(_ position: KeyStyle.Position) throws {
        let line = caption(position.isTop ? .top : .bottom)
        let plain = scene(background: 0.5, keys: nil)
        let keysAlone = try #require(try ink(scene(background: 0.5, keys: layer(position: position)), against: plain).bounds)
        let captionAlone = try #require(try ink(scene(background: 0.5, keys: nil, caption: line), against: plain).bounds)
        #expect(keysAlone.intersects(captionAlone), "the test only means something if they would collide")

        let cleared = try #require(try ink(scene(background: 0.5, keys: layer(position: position, clears: [line]),
                                                 caption: line),
                                           against: scene(background: 0.5, keys: nil, caption: line)).bounds)
        #expect(!cleared.intersects(captionAlone), "\(position): keys \(cleared) over caption \(captionAlone)")
        #expect(position.isTop ? cleared.minY > captionAlone.maxY : cleared.maxY < captionAlone.minY,
                "beyond the caption, not beside it")
        #expect(CGRect(origin: .zero, size: output).contains(cleared), "and still in the frame")
    }

    @Test func aCaptionOnTheOtherEdgeLeavesTheKeysWhereTheyWere() throws {
        let plain = scene(background: 0.5, keys: nil)
        let alone = try #require(try ink(scene(background: 0.5, keys: layer()), against: plain).bounds)
        let top = caption(.top)
        let withCaption = try #require(try ink(scene(background: 0.5, keys: layer(), caption: top),
                                               against: scene(background: 0.5, keys: nil, caption: top)).bounds)
        #expect(withCaption == alone)
    }

    /// The keys stand still while a line arrives under them: they are placed against
    /// where the line comes to rest, not against the line as it is drawn this frame.
    @Test func theKeysDoNotMoveWhileALineArrives() throws {
        var arriving = caption()
        arriving.scale = 0.92
        arriving.drop = 0.03
        arriving.opacity = 0.3
        let settled = caption()
        let early = try #require(try ink(scene(background: 0.5, keys: layer(clears: [settled]), caption: arriving),
                                         against: scene(background: 0.5, keys: nil, caption: arriving)).bounds)
        let later = try #require(try ink(scene(background: 0.5, keys: layer(clears: [settled]), caption: settled),
                                         against: scene(background: 0.5, keys: nil, caption: settled)).bounds)
        #expect(early == later)
    }

    @Test func placementIsArithmeticBeforeItIsPixels() {
        let plate = CGSize(width: 100, height: 40)
        let bottom = KeycapArtwork.frame(for: plate, layer: layer(position: .bottomCenter), outputSize: output, clearing: [])
        #expect(bottom.midX == output.width / 2)
        #expect(abs(bottom.minY - output.height * KeycapArtwork.margin) < 0.001)
        let corner = KeycapArtwork.frame(for: plate, layer: layer(position: .topRight), outputSize: output, clearing: [])
        #expect(abs(corner.maxX - (output.width - output.height * KeycapArtwork.margin)) < 0.001)
        #expect(abs(corner.maxY - (output.height - output.height * KeycapArtwork.margin)) < 0.001)

        let line = CGRect(x: 200, y: 20, width: 240, height: 50)
        let lifted = KeycapArtwork.frame(for: plate, layer: layer(position: .bottomCenter), outputSize: output, clearing: [line])
        #expect(lifted.minY > line.maxY)
        let aside = KeycapArtwork.frame(for: plate, layer: layer(position: .bottomLeft), outputSize: output,
                                        clearing: [CGRect(x: 300, y: 20, width: 100, height: 50)])
        #expect(aside == KeycapArtwork.frame(for: plate, layer: layer(position: .bottomLeft), outputSize: output, clearing: []),
                "a line the keys are not over does not move them")
        let squeezed = KeycapArtwork.frame(for: plate, layer: layer(position: .bottomCenter), outputSize: output,
                                           clearing: [CGRect(x: 0, y: 0, width: 640, height: 340)])
        #expect(CGRect(origin: .zero, size: output).contains(squeezed), "pushed off the top, and pulled back in")
    }

    // MARK: - Readable

    @Test(arguments: KeyStyle.Look.allCases)
    func everyLookReadsOnWhiteAndOnBlack(_ look: KeyStyle.Look) throws {
        let onWhite = try ink(scene(background: 1, keys: layer(look: look)), against: scene(background: 1, keys: nil))
        #expect(onWhite.dark > 150, "\(look) on white needs a dark backdrop or edge: \(onWhite.dark)")
        #expect(onWhite.light > 0 || look == .text, "\(look) on white still has its light legend")
        let onBlack = try ink(scene(background: 0, keys: layer(look: look)), against: scene(background: 0, keys: nil))
        #expect(onBlack.light > 150, "\(look) on black needs a light legend or rim: \(onBlack.light)")
    }

    @Test func everyNamedKeyAndModifierDrawsALegend() throws {
        // A key with its legend on it has light pixels a blank cap has not.
        let blank = try ink(scene(background: 0.5, keys: layer([" "])), against: scene(background: 0.5, keys: nil))
        for named in NamedKey.allCases {
            let drawn = try ink(scene(background: 0.5, keys: layer([named.symbol])), against: scene(background: 0.5, keys: nil))
            #expect(drawn.light > blank.light + 20, "\(named.rawValue) drew nothing on its key")
        }
        for modifier in KeyModifiers.inDisplayOrder {
            let drawn = try ink(scene(background: 0.5, keys: layer([modifier.symbol])), against: scene(background: 0.5, keys: nil))
            #expect(drawn.light > blank.light + 20, "\(modifier.symbol) drew nothing on its key")
        }
    }

    @Test func aCountMakesTheKeysWider() throws {
        let plain = scene(background: 0.5, keys: nil)
        let once = try #require(try ink(scene(background: 0.5, keys: layer(["⌘", "Z"])), against: plain).bounds)
        let thrice = try #require(try ink(scene(background: 0.5, keys: layer(["⌘", "Z"], count: 3)), against: plain).bounds)
        #expect(thrice.width > once.width + 10)
    }

    @Test func aWordOnAKeyGetsAWiderKey() throws {
        let plain = scene(background: 0.5, keys: nil)
        let letter = try #require(try ink(scene(background: 0.5, keys: layer(["K"])), against: plain).bounds)
        let space = try #require(try ink(scene(background: 0.5, keys: layer(["Space"])), against: plain).bounds)
        #expect(space.width > letter.width * 1.5)
        #expect(abs(space.height - letter.height) < 3, "and the same height")
    }

    @Test func theSizeSettingSizesTheKeys() throws {
        let plain = scene(background: 0.5, keys: nil)
        let small = try #require(try ink(scene(background: 0.5, keys: layer(size: 0.05)), against: plain).bounds)
        let large = try #require(try ink(scene(background: 0.5, keys: layer(size: 0.1)), against: plain).bounds)
        #expect(large.height > small.height * 1.6)
    }

    // MARK: - Arriving and leaving

    @Test func theKeysArriveSmallAndFadedAndSettle() {
        let early = SceneBuilder.keyPose(elapsed: 0.02, remaining: 1.18, length: 1.2)
        #expect(early.opacity < 1)
        #expect(early.scale < 1)
        let settled = SceneBuilder.keyPose(elapsed: 0.6, remaining: 0.6, length: 1.2)
        #expect(settled.opacity == 1)
        #expect(abs(settled.scale - 1) < 0.0001)
        let leaving = SceneBuilder.keyPose(elapsed: 1.17, remaining: 0.03, length: 1.2)
        #expect(leaving.opacity < 1)
        #expect(abs(leaving.scale - 1) < 0.0001, "only a fade on the way out")
    }

    @Test func aShortPressStillArrivesAndLeaves() {
        let pose = SceneBuilder.keyPose(elapsed: 0.05, remaining: 0.05, length: 0.1)
        #expect(pose.opacity > 0 && pose.opacity <= 1)
        #expect(pose.scale > 0.9 && pose.scale <= 1)
    }

    // MARK: - From the project to the frame

    private func timeline(seconds: Double = 30) -> Timeline {
        Timeline(sourceDuration: time(seconds))
    }

    private var builder: SceneBuilder { SceneBuilder(videoSize: CGSize(width: 1_280, height: 720)) }

    @Test func theProjectsKeysReachTheFrameWhileTheyAreOn() throws {
        var timeline = timeline()
        timeline.keyCues = [KeyCue(start: time(2), duration: time(1.2), modifiers: [.command, .shift], key: "K", count: 2)]
        timeline.keyStyle = KeyStyle(position: .topLeft, size: 0.09, look: .pill)

        let keys = try #require(builder.descriptor(for: timeline, at: time(2.6)).keys)
        #expect(keys.caps == ["⇧", "⌘", "K"])
        #expect(keys.count == 2)
        #expect(keys.look == .pill)
        #expect(keys.position == .topLeft)
        #expect(keys.size == 0.09)
        #expect(keys.opacity == 1)
        #expect(builder.descriptor(for: timeline, at: time(1.9)).keys == nil, "before the press")
        #expect(builder.descriptor(for: timeline, at: time(3.3)).keys == nil, "after it")
        #expect(builder.descriptor(for: timeline, at: time(2.02)).keys.map { $0.opacity < 1 && $0.scale < 1 } == true,
                "arriving")

        timeline.keyCues[0].isHidden = true
        #expect(builder.descriptor(for: timeline, at: time(2.6)).keys == nil, "hidden")
        timeline.keyCues[0].isHidden = false
        timeline.keyStyle.isVisible = false
        #expect(builder.descriptor(for: timeline, at: time(2.6)).keys == nil, "the lane switched off")
    }

    @Test func aNamedKeyOnItsOwnReachesTheFrameOnlyWhenAskedFor() throws {
        var timeline = timeline()
        timeline.keyCues = [KeyCue(start: time(2), key: "Return")]
        #expect(builder.descriptor(for: timeline, at: time(2.5)).keys == nil)
        timeline.keyStyle.showsNamedKeysAlone = true
        #expect(builder.descriptor(for: timeline, at: time(2.5)).keys?.caps == ["⏎"])
    }

    @Test func theBuilderNamesTheCaptionsTheKeysMustStayClearOf() throws {
        var timeline = timeline()
        timeline.keyCues = [KeyCue(start: time(2), duration: time(1.2), modifiers: [.command], key: "K")]
        // One line during the press, one before it, one that starts in the middle of it.
        timeline.captions = [CaptionCue(start: time(0), duration: time(1), text: "before"),
                             CaptionCue(start: time(1.5), duration: time(1), text: "during"),
                             CaptionCue(start: time(3), duration: time(2), text: "as it ends")]
        let keys = try #require(builder.descriptor(for: timeline, at: time(2.2)).keys)
        #expect(keys.clears.map(\.text) == ["during", "as it ends"])
        #expect(keys.clears.first?.position == .bottom)
        // The same answer at every frame of the press, whatever line is up.
        #expect(builder.descriptor(for: timeline, at: time(2.9)).keys?.clears == keys.clears)

        timeline.captionStyle.position = .top
        #expect(builder.descriptor(for: timeline, at: time(2.2)).keys?.clears.isEmpty == true, "the other edge")
        timeline.keyStyle.position = .topRight
        #expect(builder.descriptor(for: timeline, at: time(2.2)).keys?.clears.count == 2)
        timeline.captionStyle.isVisible = false
        #expect(builder.descriptor(for: timeline, at: time(2.2)).keys?.clears.isEmpty == true, "captions off")
    }

    /// The same scene twice is the same bytes: the export and the preview draw one picture.
    @Test func theSameKeysRenderIdenticallyTwice() throws {
        KeycapArtwork.clearCache()
        let scene = scene(background: 0.3, keys: layer(count: 3, clears: [caption()]), caption: caption())
        let first = try pixels(scene)
        let second = try pixels(scene)
        #expect(first.bytes == second.bytes)
    }

    /// Writes a few frames to look at, when asked to. Not a test of anything: a way of
    /// seeing the artwork without launching the app.
    @Test func snapshotsForTheEye() throws {
        guard let folder = ProcessInfo.processInfo.environment["KLIK_KEYCAP_SNAPSHOTS"] else { return }
        let renderer = SceneRenderer()
        let large = CGSize(width: 1_280, height: 720)
        func write(_ name: String, _ scene: SceneDescriptor) throws {
            let image = try #require(renderer.cgImage(for: scene, source: nil))
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        for look in KeyStyle.Look.allCases {
            for background in [0.0, 0.5, 1.0] {
                var scene = SceneDescriptor(outputSize: large,
                                            background: .color(ColorValue(r: background, g: background, b: background)),
                                            videoFrame: CGRect(origin: .zero, size: large))
                scene.keys = KeyLayer(caps: ["⌃", "⌥", "⇧", "⌘", "K"], count: 3, look: look, size: 0.07,
                                      clears: [caption()])
                scene.caption = caption()
                try write("\(look)-\(Int(background * 100))", scene)
            }
        }
        var named = SceneDescriptor(outputSize: large,
                                    background: .color(ColorValue(r: 0.9, g: 0.9, b: 0.92)),
                                    videoFrame: CGRect(origin: .zero, size: large))
        named.keys = KeyLayer(caps: ["⌘", "Space"], look: .keycaps, position: .topLeft, size: 0.07)
        try write("space", named)
        named.keys = KeyLayer(caps: NamedKey.allCases.prefix(14).map(\.symbol), look: .keycaps, size: 0.06)
        try write("named", named)
    }
}
