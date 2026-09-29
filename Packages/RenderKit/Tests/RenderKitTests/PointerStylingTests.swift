import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// The pointer styles, the spotlight and the magnifier, read back as pixels.
///
/// Each draws a frame onto a known picture and measures where the light landed, the way
/// `PointerPlacementTests` does for the recorded shapes.
struct PointerStylingTests {
    // MARK: - Reading pixels

    /// A rendered frame, as bytes with the first row at the top.
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func value(_ x: Int, _ y: Int, _ channel: Int = 0) -> UInt8 {
            bytes[(y * width + x) * 4 + channel]
        }

        /// The brightest channel, which is what "light" means for a coloured dot.
        func light(_ x: Int, _ y: Int) -> Int {
            let base = (y * width + x) * 4
            return Int(max(bytes[base], bytes[base + 1], bytes[base + 2]))
        }

        /// Where the light is, as a box and a centre of mass, in pixels from the top-left.
        func light(above threshold: Int = 12, within area: CGRect? = nil) -> (box: CGRect, centre: CGPoint)? {
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            var sumX = 0.0, sumY = 0.0, total = 0.0
            let xs = area.map { max(0, Int($0.minX))..<min(width, Int($0.maxX.rounded(.up))) } ?? 0..<width
            let ys = area.map { max(0, Int($0.minY))..<min(height, Int($0.maxY.rounded(.up))) } ?? 0..<height
            for y in ys {
                for x in xs {
                    let value = light(x, y)
                    guard value > threshold else { continue }
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    // Pixel centres, so a symmetrical shape's centre is its middle.
                    sumX += (Double(x) + 0.5) * Double(value)
                    sumY += (Double(y) + 0.5) * Double(value)
                    total += Double(value)
                }
            }
            guard total > 0 else { return nil }
            return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
                    CGPoint(x: sumX / total, y: sumY / total))
        }
    }

    private func render(_ scene: SceneDescriptor, source: CIImage? = nil) throws -> Pixels {
        let source = source ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: scene.outputSize))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: source))
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(width: width, height: height, bytes: bytes)
    }

    /// A frame with no padding and no camera move, so a position in the recording is a
    /// position in the frame.
    private func frame(_ size: CGSize, cursor: CursorLayer? = nil) -> SceneDescriptor {
        SceneDescriptor(outputSize: size,
                        background: .color(.init(r: 0, g: 0, b: 0, a: 1)),
                        videoFrame: CGRect(origin: .zero, size: size),
                        cursor: cursor)
    }

    private func pointer(_ appearance: CursorStyle.Appearance, at position: CGPoint,
                         scale: Double = 1.4, velocity: CGVector = .zero,
                         color: ColorValue = CursorStyle.defaultDotColor) -> CursorLayer {
        var layer = CursorLayer(position: position, shape: .arrow, scale: scale, velocity: velocity)
        layer.appearance = appearance
        layer.dotColor = color
        return layer
    }

    private static let sizes = [CGSize(width: 1_920, height: 1_080), CGSize(width: 3_840, height: 2_160)]
    /// Somewhere that is not the middle, and not on a whole pixel at either size.
    private static let spot = CGPoint(x: 0.3713, y: 0.6127)

    // MARK: - Each style at its point

    /// The arrows point with their tips: the top-left of what is drawn is the point, to a
    /// pixel, at 1080p and at 4K.
    @Test(arguments: [CursorStyle.Appearance.largeArrow, .minimal])
    func anArrowStyleHasItsTipOnThePoint(_ appearance: CursorStyle.Appearance) throws {
        for size in Self.sizes {
            let point = CGPoint(x: Self.spot.x * size.width, y: Self.spot.y * size.height)
            let drawn = try #require(try render(frame(size, cursor: pointer(appearance, at: Self.spot))).light())
            #expect(abs(drawn.box.minX - point.x) <= 1, "\(appearance) at \(size): tip x \(drawn.box.minX), point \(point.x)")
            #expect(abs(drawn.box.minY - point.y) <= 1, "\(appearance) at \(size): tip y \(drawn.box.minY), point \(point.y)")
            // And the arrow is below and right of its tip, never above or left of it.
            #expect(drawn.box.width > 10 && drawn.box.height > 10)
        }
    }

    /// The dot's middle is the pointer, at 1080p and at 4K.
    @Test func theDotsMiddleIsThePointer() throws {
        for size in Self.sizes {
            let point = CGPoint(x: Self.spot.x * size.width, y: Self.spot.y * size.height)
            let drawn = try #require(try render(frame(size, cursor: pointer(.dot, at: Self.spot))).light())
            #expect(abs(drawn.centre.x - point.x) <= 1, "dot at \(size): centre x \(drawn.centre.x), point \(point.x)")
            #expect(abs(drawn.centre.y - point.y) <= 1, "dot at \(size): centre y \(drawn.centre.y), point \(point.y)")
            #expect(abs(drawn.box.midX - point.x) <= 1)
            #expect(abs(drawn.box.midY - point.y) <= 1)
        }
    }

    /// The styles are drawn at the size of the frame, not scaled up: at 4K the drawing is
    /// twice the size it is at 1080p, and its edges are harder than the 1080p drawing
    /// enlarged to the same size would be.
    @Test(arguments: [CursorStyle.Appearance.largeArrow, .dot, .minimal])
    func aStyleIsSharpAtFourK(_ appearance: CursorStyle.Appearance) throws {
        let small = try #require(try render(frame(Self.sizes[0], cursor: pointer(appearance, at: Self.spot))).light())
        let large = try #require(try render(frame(Self.sizes[1], cursor: pointer(appearance, at: Self.spot))).light())
        #expect(abs(large.box.width / small.box.width - 2) < 0.1, "\(appearance) is \(large.box.width / small.box.width)× at 4K")

        // The drawing the 4K frame uses, against the 1080p one enlarged twice.
        let size = min(Self.sizes[1].width, Self.sizes[1].height) * 0.035 * 1.4
        let native = try #require(PointerStyleArtwork.drawing(appearance, size: size, color: CursorStyle.defaultDotColor))
        let half = try #require(PointerStyleArtwork.drawing(appearance, size: size / 2, color: CursorStyle.defaultDotColor))
        let enlarged = half.image.transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        let nativeStep = try steepestStep(native.image)
        let enlargedStep = try steepestStep(enlarged)
        #expect(nativeStep > enlargedStep * 1.3,
                "\(appearance): edges step by \(nativeStep) drawn at size, \(enlargedStep) enlarged")
    }

    /// The steepest step between two neighbouring pixels along every row of a drawing
    /// laid on black, averaged over the rows that have any — one number for how hard its
    /// edges are.
    private func steepestStep(_ image: CIImage) throws -> Double {
        let extent = image.extent.integral
        let flat = image.composited(over: CIImage(color: .black).cropped(to: extent))
        let cg = try #require(CIContext().createCGImage(flat, from: extent))
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height,
                                             bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let pixels = Pixels(width: cg.width, height: cg.height, bytes: bytes)
        var total = 0.0, rows = 0
        for y in 0..<cg.height {
            var steepest = 0
            for x in 0..<(cg.width - 1) {
                steepest = max(steepest, abs(pixels.light(x + 1, y) - pixels.light(x, y)))
            }
            guard steepest > 0 else { continue }
            total += Double(steepest)
            rows += 1
        }
        return rows > 0 ? total / Double(rows) : 0
    }

    /// The styles are the size setting, like the drawn arrow: the large arrow bigger, the
    /// minimal one smaller.
    @Test func theArrowsAreTheSizesTheyAreCalled() throws {
        let size = Self.sizes[0]
        func width(_ layer: CursorLayer) throws -> Double {
            try #require(try render(frame(size, cursor: layer)).light()).box.width
        }
        let drawn = try width(CursorLayer(position: Self.spot, shape: .arrow, scale: 1.4))
        #expect(try width(pointer(.largeArrow, at: Self.spot)) > drawn * 1.15)
        #expect(try width(pointer(.minimal, at: Self.spot)) < drawn)
    }

    /// Motion blur still smears a styled pointer along its travel without moving it.
    @Test(arguments: [CGVector(dx: 3_000, dy: 0), CGVector(dx: 0, dy: -3_000)])
    func aSmearedDotIsWhereAStillOneIs(_ velocity: CGVector) throws {
        let size = Self.sizes[0]
        let still = try #require(try render(frame(size, cursor: pointer(.dot, at: Self.spot))).light())
        let moving = try #require(try render(frame(size, cursor: pointer(.dot, at: Self.spot, velocity: velocity))).light())
        #expect(abs(moving.centre.x - still.centre.x) <= 1)
        #expect(abs(moving.centre.y - still.centre.y) <= 1)
        #expect(moving.box.width > still.box.width || moving.box.height > still.box.height, "and it was smeared")
    }

    /// The dot is drawn in its colour.
    @Test func theDotIsItsColour() throws {
        let size = Self.sizes[0]
        let pixels = try render(frame(size, cursor: pointer(.dot, at: Self.spot, color: ColorValue(r: 0, g: 0, b: 1))))
        let x = Int(Self.spot.x * size.width), y = Int(Self.spot.y * size.height)
        #expect(pixels.value(x, y, 2) > 200)
        #expect(pixels.value(x, y, 0) < 40)
    }

    // MARK: - From the project

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let builder = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000), displayScale: 2)

    private func timeline(_ change: (inout Timeline) -> Void = { _ in }) -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.smoothing = 0
        change(&timeline)
        return timeline
    }

    /// Moves for the first second, then still at (400, 250) points — the middle of the
    /// picture — with a click at 8 s.
    private var track: CursorTrack {
        let samples = (0...1_000).map { step -> CursorSample in
            let t = Double(step) / 100
            return CursorSample(t: t, x: t < 1 ? 100 + t * 300 : 400, y: 250, shape: .iBeam)
        }
        return CursorTrack(samples: samples, input: [.mouseDown(t: 8, button: 0, x: 400, y: 250)])
    }

    @Test func aProjectAsRecordedDrawsWhatItAlwaysDid() {
        let scene = builder.descriptor(for: timeline(), at: time(3), cursor: track)
        #expect(scene.cursor?.appearance == .asRecorded)
        #expect(scene.cursor?.shape == .iBeam)
        #expect(scene.pointerSpotlight == nil)
        #expect(scene.pointerMagnifier == nil)
    }

    @Test(arguments: [CursorStyle.Appearance.largeArrow, .dot, .minimal])
    func aDrawnStyleIsOneDrawingWhateverTheShape(_ appearance: CursorStyle.Appearance) {
        let scene = builder.descriptor(for: timeline { $0.cursor.appearance = appearance }, at: time(3), cursor: track)
        #expect(scene.cursor?.appearance == appearance)
        #expect(scene.cursor?.artwork == nil)
        #expect(scene.cursor?.shape == .arrow)
    }

    @Test func invisibleButClicksDrawsTheClicksAndNoPointer() {
        let scene = builder.descriptor(for: timeline { $0.cursor.appearance = .clicksOnly }, at: time(8.1), cursor: track)
        #expect(scene.cursor == nil)
        #expect(scene.clicks.count == 1)
    }

    /// The swell and "Keep size while zoomed" reach a styled pointer as they reach the
    /// drawn one.
    @Test func theSwellAndTheZoomSettingStillApply() {
        let style = timeline {
            $0.cursor.appearance = .dot
            $0.cursor.clickEffect = true
            $0.cursor.sizeIsIndependentOfZoom = false
        }
        let before = builder.descriptor(for: style, at: time(7), cursor: track)
        let during = builder.descriptor(for: style, at: time(8.05), cursor: track)
        #expect((during.cursor?.scale ?? 0) != (before.cursor?.scale ?? 0))
        #expect(during.cursor?.sizeFollowsZoom == true)
    }

    @Test func keepingItsSizeWhileZoomedHoldsForTheDot() throws {
        let size = Self.sizes[0]
        var flat = frame(size, cursor: pointer(.dot, at: CGPoint(x: 0.5, y: 0.5)))
        let still = try #require(try render(flat).light())
        flat.zoom = 2
        let zoomed = try #require(try render(flat).light())
        #expect(abs(zoomed.box.width - still.box.width) <= 1)
        flat.cursor?.sizeFollowsZoom = true
        let grown = try #require(try render(flat).light())
        #expect(grown.box.width > still.box.width * 1.8)
    }

    // MARK: - Spotlight

    private func grey(_ size: CGSize, _ level: CGFloat = 0.8) -> CIImage {
        CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Outside the circle the picture is darker by the amount set; inside it is not.
    @Test(arguments: [0.3, 0.6, 0.9])
    func theSpotlightDimsByTheAmountSet(_ dimming: Double) throws {
        let size = Self.sizes[0]
        var scene = frame(size)
        scene.pointerSpotlight = PointerSpotlightLayer(center: CGPoint(x: 0.5, y: 0.5), radius: 0.2, dimming: dimming)
        let pixels = try render(scene, source: grey(size))
        let inside = Double(pixels.value(960, 540))
        let outside = Double(pixels.value(40, 40))
        let edge = Double(pixels.value(960 + Int(0.2 * 1_080 * 0.8), 540))
        #expect(abs(inside - 204) <= 2, "inside the circle is \(inside)")
        #expect(abs(outside / inside - (1 - dimming)) < 0.02, "outside is \(outside) against \(inside)")
        #expect(edge > outside, "the edge is soft, not a step")
    }

    /// The spotlight is under what is written on the picture: a caption and a note far
    /// from the pointer are exactly as bright as they are with no spotlight at all.
    @Test func captionsAndNotesAreNotDimmed() throws {
        let size = Self.sizes[0]
        var plain = frame(size)
        plain.caption = CaptionLayer(text: "Read me", fontSize: 0.06, color: .white,
                                     backgroundOpacity: 0, position: .bottom, margin: 0.05)
        plain.annotations = [AnnotationLayer(kind: .rectangle,
                                             rect: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.2),
                                             color: ColorValue(r: 1, g: 1, b: 0), fontSize: 0.05, opacity: 1)]
        var spotlit = plain
        spotlit.pointerSpotlight = PointerSpotlightLayer(center: CGPoint(x: 0.15, y: 0.2), radius: 0.1, dimming: 0.8)

        let before = try render(plain, source: grey(size, 0.5))
        let after = try render(spotlit, source: grey(size, 0.5))
        // The picture round them is dimmed...
        #expect(Int(after.value(960, 700)) < Int(before.value(960, 700)) / 2)
        // ...and every pixel of caption or note that was bright still is.
        var written = 0
        // Solid ones: an edge pixel is part picture, and the picture under it is dimmed.
        for y in 0..<size.height.toInt {
            for x in 0..<size.width.toInt where before.light(x, y) >= 254 {
                written += 1
                #expect(after.light(x, y) >= 252, "dimmed at \(x), \(y)")
                if after.light(x, y) < 252 { return }
            }
        }
        #expect(written > 500, "the caption and the note were drawn")
    }

    /// From the project: on while the pointer is shown, gone once it has been hidden for
    /// being still, and back with it.
    @Test func theSpotlightGoesWithAPointerHiddenForBeingStill() {
        let project = timeline {
            $0.cursor.spotlight = PointerSpotlight(isEnabled: true, radius: 0.2, dimming: 0.6)
            $0.cursor.hidesWhenIdle = true
            $0.cursor.idleDelay = 2
        }
        let moving = builder.descriptor(for: project, at: time(0.5), cursor: track)
        #expect(moving.pointerSpotlight?.dimming == 0.6)
        #expect(moving.pointerSpotlight.map { abs($0.center.x - 250.0 * 2 / 1_600) < 0.01 } == true)
        #expect(builder.descriptor(for: project, at: time(5), cursor: track).pointerSpotlight == nil)
        #expect(builder.descriptor(for: project, at: time(8), cursor: track).pointerSpotlight?.dimming == 0.6)
    }

    @Test func aSpotlightLimitedToStretchesIsOnlyThere() {
        let project = timeline {
            $0.cursor.spotlight = PointerSpotlight(isEnabled: true, dimming: 0.6, scope: .markedStretches)
            $0.cursorRegions = [CursorRegion(start: self.time(2), duration: self.time(4), isHidden: false,
                                             transition: .zero, spotlights: true)]
        }
        #expect(builder.descriptor(for: project, at: time(1), cursor: track).pointerSpotlight == nil)
        #expect(builder.descriptor(for: project, at: time(3), cursor: track).pointerSpotlight?.dimming == 0.6)
        #expect(builder.descriptor(for: project, at: time(7), cursor: track).pointerSpotlight == nil)
    }

    // MARK: - Magnifier

    /// A black picture with a white square in the middle of it.
    private func square(_ size: CGSize, side: CGFloat, at centre: CGPoint) -> CIImage {
        let square = CIImage(color: .white)
            .cropped(to: CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side))
        return square.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
    }

    private let lensFrame = CGSize(width: 1_600, height: 1_000)

    /// A 20-pixel square under the pointer is 20 × factor pixels in the lens.
    @Test(arguments: [1.5, 2.0, 3.0])
    func theLensEnlargesByTheFactorSet(_ factor: Double) throws {
        var scene = frame(lensFrame)
        scene.pointerMagnifier = PointerMagnifierLayer(center: CGPoint(x: 0.5, y: 0.5), factor: factor, diameter: 0.3)
        let pixels = try render(scene, source: square(lensFrame, side: 20, at: CGPoint(x: 800, y: 500)))
        let inside = CGRect(x: 800 - 100, y: 500 - 100, width: 200, height: 200)
        let drawn = try #require(pixels.light(above: 128, within: inside))
        #expect(abs(drawn.box.width - 20 * factor) <= 2, "\(drawn.box.width) wide at \(factor)×")
        #expect(abs(drawn.box.height - 20 * factor) <= 2)
        #expect(abs(drawn.box.midX - 800) <= 1 && abs(drawn.box.midY - 500) <= 1)
    }

    /// The factor is against the picture as it is shown: with the camera in at 2×, a 2×
    /// lens shows things four times their recorded size.
    @Test func theLensMagnifiesWhatTheCameraShows() throws {
        var scene = frame(lensFrame)
        scene.zoom = 2
        scene.pointerMagnifier = PointerMagnifierLayer(center: CGPoint(x: 0.5, y: 0.5), factor: 2, diameter: 0.4)
        let pixels = try render(scene, source: square(lensFrame, side: 20, at: CGPoint(x: 800, y: 500)))
        let drawn = try #require(pixels.light(above: 128, within: CGRect(x: 700, y: 400, width: 200, height: 200)))
        #expect(abs(drawn.box.width - 80) <= 2, "\(drawn.box.width) wide")
    }

    /// Drawn from the recording at its own resolution. Stripes one recorded pixel wide on a
    /// recording twice the size of the frame are a flat grey in the picture — and stripes
    /// again in a 2× lens, which an enlarged frame could never show.
    @Test func theLensIsDrawnFromTheFullResolutionRecording() throws {
        let recorded = CGSize(width: 3_200, height: 2_000)
        var stripes = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: recorded))
        for x in stride(from: 0, to: Int(recorded.width), by: 2) {
            stripes = CIImage(color: .white).cropped(to: CGRect(x: x, y: 0, width: 1, height: Int(recorded.height)))
                .composited(over: stripes)
        }
        var scene = frame(lensFrame)
        scene.pointerMagnifier = PointerMagnifierLayer(center: CGPoint(x: 0.5, y: 0.5), factor: 2, diameter: 0.3)
        let pixels = try render(scene, source: stripes)

        func contrast(_ xs: Range<Int>, row: Int) -> Int {
            let values = xs.map { pixels.light($0, row) }
            return (values.max() ?? 0) - (values.min() ?? 0)
        }
        #expect(contrast(100..<140, row: 100) < 40, "the picture is grey")
        #expect(contrast(780..<820, row: 500) > 150, "the lens resolves the stripes")
    }

    /// Near an edge the lens slides inward and stays whole: a full circle, inside the
    /// frame, still showing what is under the pointer.
    @Test(arguments: [CGPoint(x: 0.01, y: 0.99), CGPoint(x: 0.995, y: 0.02), CGPoint(x: 0.5, y: 0)])
    func theLensStaysInsideTheFrame(_ position: CGPoint) throws {
        var scene = frame(lensFrame)
        let lens = PointerMagnifierLayer(center: position, factor: 2, diameter: 0.3)
        scene.pointerMagnifier = lens
        let geometry = SceneRenderer.lensGeometry(lens, in: scene)
        let reach = geometry.radius + SceneRenderer.lensBorder(radius: geometry.radius)
        #expect(geometry.centre.x - reach >= 0 && geometry.centre.x + reach <= lensFrame.width)
        #expect(geometry.centre.y - reach >= 0 && geometry.centre.y + reach <= lensFrame.height)

        // On a black picture the white rim is all there is to see, and it is a whole circle.
        let pixels = try render(scene)
        let rim = try #require(pixels.light(above: 128))
        #expect(abs(rim.box.width - geometry.radius * 2) <= 2, "rim \(rim.box.width) wide")
        #expect(abs(rim.box.height - geometry.radius * 2) <= 2, "rim \(rim.box.height) tall")

        // What is under the pointer is in the middle of the lens.
        let point = CGPoint(x: position.x * lensFrame.width, y: position.y * lensFrame.height)
        let marked = try render(scene, source: square(lensFrame, side: 6,
                                                       at: CGPoint(x: min(max(point.x, 3), 1_597),
                                                                   y: lensFrame.height - min(max(point.y, 3), 997))))
        let middle = CGPoint(x: geometry.centre.x, y: lensFrame.height - geometry.centre.y)
        let found = try #require(marked.light(above: 128, within: CGRect(x: middle.x - 40, y: middle.y - 40,
                                                                          width: 80, height: 80)))
        #expect(abs(found.box.midX - middle.x) <= 8 && abs(found.box.midY - middle.y) <= 8)
    }

    /// Whatever the picture hides, the lens hides: a cover over the square keeps it covered
    /// at 2×.
    @Test func theLensCannotSeeUnderACover() throws {
        var scene = frame(lensFrame)
        scene.blurs = [BlurLayer(rect: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), style: .cover, radius: 0)]
        scene.pointerMagnifier = PointerMagnifierLayer(center: CGPoint(x: 0.5, y: 0.5), factor: 2, diameter: 0.3)
        let pixels = try render(scene, source: square(lensFrame, side: 20, at: CGPoint(x: 800, y: 500)))
        #expect(pixels.light(above: 128, within: CGRect(x: 740, y: 440, width: 120, height: 120)) == nil)
    }

    @Test func theLensFollowsThePointerFromTheProject() {
        let project = timeline {
            $0.cursor.magnifier = PointerMagnifier(isEnabled: true, factor: 2.5, diameter: 0.3)
        }
        let scene = builder.descriptor(for: project, at: time(3), cursor: track)
        let lens = scene.pointerMagnifier
        #expect(lens?.factor == 2.5)
        #expect(lens.map { abs($0.center.x - 0.5) < 0.001 && abs($0.center.y - 0.5) < 0.001 } == true)
        #expect(builder.descriptor(for: timeline(), at: time(3), cursor: track).pointerMagnifier == nil)
    }
}

private extension CGFloat {
    var toInt: Int { Int(self) }
}
