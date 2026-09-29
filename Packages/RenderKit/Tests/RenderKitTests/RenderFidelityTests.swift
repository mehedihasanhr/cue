import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The guard an optimisation has to get past.
///
/// `SceneTests` says what a frame *should* contain; this says that it contains exactly
/// what it contained before anybody went looking for speed. Two halves, because the two
/// failure modes are different: a hash over every field of a descriptor catches a builder
/// that took a short cut and moved the camera a thousandth of a degree, and a hash over
/// the rendered bytes catches a renderer that reused a buffer it should have cleared.
///
/// The expected values are not written down. Comparing against a literal would mean
/// re-recording it on the first legitimate change to the picture, which is how a golden
/// test stops meaning anything; instead the reference is computed from a second,
/// deliberately naive path — one descriptor at a time, one renderer per frame, nothing
/// shared — and the fast path has to agree with it. That is the invariant worth holding:
/// caching must not be observable.
struct RenderFidelityTests {
    private let times = stride(from: 0.0, through: 58.0, by: 2.3).map { RenderWorkload.time($0) }

    /// Every field of every descriptor, folded into one number.
    private func fingerprint(_ scene: SceneDescriptor) -> Int {
        var hasher = Hasher()
        hasher.combine(scene.outputSize.width); hasher.combine(scene.outputSize.height)
        hasher.combine(scene.background)
        hasher.combine(scene.backgroundBlur)
        hasher.combine(scene.videoFrame.minX); hasher.combine(scene.videoFrame.minY)
        hasher.combine(scene.videoFrame.width); hasher.combine(scene.videoFrame.height)
        hasher.combine(scene.cornerRadius)
        hasher.combine(scene.shadowRadius); hasher.combine(scene.shadowOpacity)
        hasher.combine(scene.zoom)
        hasher.combine(scene.zoomCenter.x); hasher.combine(scene.zoomCenter.y)
        for blur in scene.blurs {
            hasher.combine(blur.rect.minX); hasher.combine(blur.rect.minY)
            hasher.combine(blur.rect.width); hasher.combine(blur.rect.height)
            hasher.combine(blur.style); hasher.combine(blur.radius)
        }
        if let cursor = scene.cursor {
            hasher.combine(cursor.position.x); hasher.combine(cursor.position.y)
            hasher.combine(cursor.shape); hasher.combine(cursor.scale)
            hasher.combine(cursor.opacity)
            hasher.combine(cursor.velocity.dx); hasher.combine(cursor.velocity.dy)
            hasher.combine(cursor.sizeFollowsZoom)
        }
        for annotation in scene.annotations {
            hasher.combine(annotation.rect.minX); hasher.combine(annotation.rect.minY)
            hasher.combine(annotation.rect.width); hasher.combine(annotation.rect.height)
            hasher.combine(annotation.color.r); hasher.combine(annotation.color.a)
            hasher.combine(annotation.fontSize); hasher.combine(annotation.opacity)
            if case .text(let string) = annotation.kind { hasher.combine(string) }
        }
        if let webcam = scene.webcam {
            hasher.combine(webcam.rect.minX); hasher.combine(webcam.rect.minY)
            hasher.combine(webcam.rect.width); hasher.combine(webcam.rect.height)
            hasher.combine(webcam.cornerRadius)
            hasher.combine(webcam.isMirrored); hasher.combine(webcam.shadowOpacity)
        }
        if let caption = scene.caption {
            hasher.combine(caption.text); hasher.combine(caption.fontSize)
            hasher.combine(caption.backgroundOpacity); hasher.combine(caption.margin)
            hasher.combine(caption.position); hasher.combine(caption.opacity)
        }
        hasher.combine(scene.sourceTime.seconds)
        hasher.combine(scene.sourceCrop.minX); hasher.combine(scene.sourceCrop.width)
        return hasher.finalize()
    }

    /// Every byte of a rendered frame, folded into one number.
    private func fingerprint(_ image: CGImage) throws -> Int {
        let data = try #require(image.dataProvider?.data as Data?)
        var hasher = Hasher()
        hasher.combine(image.width); hasher.combine(image.height)
        hasher.combine(data)
        return hasher.finalize()
    }

    /// How far apart two renders of one frame may be and still be the same picture: one
    /// step of eight bits, in any channel of any pixel.
    ///
    /// Not zero, because Core Image does not promise zero. It has more than one way to run
    /// a graph — a program stitched together from precompiled pieces, or one compiled
    /// whole — and which it uses for a given render depends on whether the stitched one
    /// is ready yet, which depends on how busy the machine is. The two round differently
    /// where a cached bitmap is faded by a colour matrix, by exactly one step. That is
    /// what failed this suite about one run in eight under load: the cold frames, drawn
    /// first, were drawn the other way. Every one of the differing frames was
    /// byte-identical to what Core Image draws with stitching turned off
    /// (`CI_ENABLE_FUNCTION_STITCHING=0`), and every warm one to what it draws normally.
    ///
    /// One step cannot hide what these tests are for. A cache that serves the wrong
    /// bitmap serves other words, another size or another colour — differences of tens or
    /// hundreds of steps, over whole glyphs — and a buffer reused without clearing leaves
    /// a whole other frame behind.
    private static let coreImageRounding = 1

    /// The largest difference, in eight-bit steps, between two rendered frames — or `nil`
    /// when they are not even the same shape.
    private func largestDifference(_ first: CGImage, _ second: CGImage) throws -> Int? {
        guard first.width == second.width, first.height == second.height,
              first.bitsPerPixel == second.bitsPerPixel, first.bytesPerRow == second.bytesPerRow,
              first.bitmapInfo == second.bitmapInfo else { return nil }
        let a = try #require(first.dataProvider?.data as Data?)
        let b = try #require(second.dataProvider?.data as Data?)
        let rowBytes = first.width * first.bitsPerPixel / 8
        var largest = 0
        a.withUnsafeBytes { a in
            b.withUnsafeBytes { b in
                for row in 0..<first.height {
                    let start = row * first.bytesPerRow
                    for index in start..<(start + rowBytes) {
                        largest = max(largest, abs(Int(a[index]) - Int(b[index])))
                    }
                }
            }
        }
        return largest
    }

    /// Whether two renders are the same picture, to within `coreImageRounding`.
    private func samePicture(_ first: CGImage, _ second: CGImage) throws -> Bool {
        guard let difference = try largestDifference(first, second) else { return false }
        return difference <= Self.coreImageRounding
    }

    /// One builder reused across a whole scrub must describe the same frames as a fresh
    /// builder per frame.
    ///
    /// The test any hoisting has to pass: the moment something time-invariant is computed
    /// once and kept, the question becomes whether the kept thing was really invariant,
    /// and this is that question asked of every field.
    @Test func aReusedBuilderDescribesTheSameFramesAsAFreshOne() {
        let timeline = RenderWorkload.timeline()
        let track = RenderWorkload.cursorTrack()
        let shared = RenderWorkload.builder()

        for time in times {
            let once = RenderWorkload.builder().descriptor(for: timeline, at: time, cursor: track)
            let again = shared.descriptor(for: timeline, at: time, cursor: track)
            #expect(once == again, "the descriptor at \(time.seconds)s moved")
            #expect(fingerprint(once) == fingerprint(again))
        }
    }

    /// Describing a frame twice in a row gives the same answer — the builder holds no
    /// state that survives a call, however much is cached behind it.
    @Test func describingTheSameFrameTwiceGivesTheSameDescriptor() {
        let timeline = RenderWorkload.timeline()
        let track = RenderWorkload.cursorTrack()
        let builder = RenderWorkload.builder()

        for time in times {
            let first = builder.descriptor(for: timeline, at: time, cursor: track)
            let second = builder.descriptor(for: timeline, at: time, cursor: track)
            #expect(first == second)
        }
    }

    /// Every cache the renderer has behind it, emptied.
    ///
    /// The artwork caches are process-wide, which is what makes them worth having — the
    /// preview and an export share the plate they both want. It also means a "fresh"
    /// `SceneRenderer` is not drawing anything cold, so a test comparing two renderers
    /// would pass however incomplete a cache key was. Emptying them is what makes the
    /// comparison below mean something.
    private func clearArtworkCaches() {
        CaptionArtwork.clearCache()
        AnnotationArtwork.clearCache()
        CursorArtwork.clearCache()
    }

    /// A renderer whose caches are full must draw a frame identically to one drawing it
    /// from nothing.
    ///
    /// This is the assertion that makes the artwork and background caches safe, and the
    /// one that catches an incomplete cache key: the cold bytes are taken first, with
    /// every cache emptied before each frame, and then the same frames are drawn again
    /// through a renderer warmed on a hundred *other* frames of the same project — where
    /// the caption, the label, the pointer and the camera have all moved in between. If a
    /// key is missing a field, the warm draw serves the wrong bitmap and the frames part.
    ///
    /// "The same bytes" to within Core Image's own rounding — see `coreImageRounding` for
    /// why that is one step and not zero, and why one step hides no wrong bitmap.
    @Test func aWarmRendererDrawsTheSameBytesAsAColdOne() throws {
        let timeline = RenderWorkload.timeline(regions: 6, duration: 12)
        let track = RenderWorkload.cursorTrack(duration: 12)
        // Small, because this renders every frame twice and the comparison is of bytes,
        // not of speed. The layers exercised are the same ones at any size.
        let builder = SceneBuilder(videoSize: CGSize(width: 640, height: 360), displayScale: 2)
        let source = RenderWorkload.source(CGSize(width: 640, height: 360))
        let moments = Array(stride(from: 0.4, through: 11.4, by: 1.1))

        var cold: [CGImage] = []
        for at in moments {
            clearArtworkCaches()
            let scene = builder.descriptor(for: timeline, at: RenderWorkload.time(at), cursor: track)
            cold.append(try #require(SceneRenderer().cgImage(for: scene, source: source)))
        }

        // Warm every cache there is, on frames that are not the ones being compared.
        let warm = SceneRenderer()
        for at in stride(from: 0.0, through: 11.0, by: 0.25) {
            _ = warm.cgImage(for: builder.descriptor(for: timeline, at: RenderWorkload.time(at), cursor: track),
                             source: source)
        }

        for (index, at) in moments.enumerated() {
            let scene = builder.descriptor(for: timeline, at: RenderWorkload.time(at), cursor: track)
            let hot = try #require(warm.cgImage(for: scene, source: source))
            let difference = try largestDifference(hot, cold[index])
            #expect(try samePicture(hot, cold[index]),
                    "a warm renderer drew \(at)s differently from a cold one (by \(difference.map(String.init) ?? "shape"))")
        }
    }

    /// The caption plate is cached; changing anything the plate is made of must still
    /// change the plate.
    ///
    /// Written as a set of distinct hashes rather than as a list of expected pictures: what
    /// matters is that no two of these collide, because a collision *is* the bug — one
    /// caption served where another was asked for.
    @Test func everyFieldThePlateIsMadeOfChangesThePlate() throws {
        let output = CGSize(width: 640, height: 360)
        let base = CaptionLayer(text: "The quick brown fox",
                                fontSize: 0.06,
                                color: ColorValue(r: 1, g: 1, b: 1),
                                backgroundOpacity: 0.5,
                                position: .bottom,
                                margin: 0.05)
        var variants = [base]
        variants.append({ var c = base; c.text = "The quick brown dog"; return c }())
        variants.append({ var c = base; c.fontSize = 0.08; return c }())
        variants.append({ var c = base; c.color = ColorValue(r: 1, g: 0.2, b: 0.1); return c }())
        variants.append({ var c = base; c.backgroundOpacity = 0.9; return c }())

        let renderer = SceneRenderer()
        // Deliberately not black: the plate behind a caption *is* black, and a darker
        // black over black is still black — the first version of this test passed a
        // missing-field bug because it could not see the plate at all.
        let scene = SceneDescriptor(outputSize: output,
                                    background: .color(ColorValue(r: 0.9, g: 0.9, b: 0.85)),
                                    videoFrame: CGRect(origin: .zero, size: output))
        var hashes: Set<Int> = []
        for caption in variants {
            var scene = scene
            scene.caption = caption
            hashes.insert(try fingerprint(try #require(renderer.cgImage(for: scene, source: nil))))
        }
        #expect(hashes.count == variants.count,
                "two captions that should look different came out identical — a cache key is short a field")

        // And the fields the plate is *not* made of must place it without redrawing it: a
        // different margin is a different picture, from the same cached bitmap.
        var moved = scene
        moved.caption = { var c = base; c.margin = 0.2; return c }()
        let placed = try fingerprint(try #require(renderer.cgImage(for: moved, source: nil)))
        #expect(!hashes.contains(placed), "moving the plate must move it")
    }

    /// The same, for annotations: the size and the words are keyed, the position is not.
    @Test func everyFieldTheLabelIsMadeOfChangesTheLabel() throws {
        let output = CGSize(width: 640, height: 360)
        let base = AnnotationLayer(kind: .text("Step one"),
                                   rect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.15),
                                   color: ColorValue(r: 1, g: 0.23, b: 0.19),
                                   fontSize: 0.06,
                                   opacity: 1)
        var variants = [base]
        variants.append({ var a = base; a.kind = .text("Step two"); return a }())
        variants.append({ var a = base; a.kind = .rectangle; return a }())
        // Widened as a box rather than as a label: a wider bitmap holding the same
        // left-set words is the same pixels with more transparency beside them, so a text
        // annotation cannot tell this test anything about its own size.
        variants.append({ var a = base; a.kind = .rectangle; a.rect.size.width = 0.5; return a }())
        variants.append({ var a = base; a.color = ColorValue(r: 0.1, g: 0.9, b: 0.2); return a }())
        variants.append({ var a = base; a.fontSize = 0.1; return a }())
        variants.append({ var a = base; a.opacity = 0.4; return a }())
        variants.append({ var a = base; a.rect.origin.x = 0.45; return a }())

        let renderer = SceneRenderer()
        var hashes: Set<Int> = []
        for annotation in variants {
            var scene = SceneDescriptor(outputSize: output,
                                        background: .color(ColorValue(r: 0, g: 0, b: 0)),
                                        videoFrame: CGRect(origin: .zero, size: output))
            scene.annotations = [annotation]
            hashes.insert(try fingerprint(try #require(renderer.cgImage(for: scene, source: nil))))
        }
        #expect(hashes.count == variants.count,
                "two labels that should look different came out identical — a cache key is short a field")
    }

    // MARK: - The preview's own path

    /// The frame at rest is the frame the export writes — byte for byte.
    ///
    /// The assertion the preview's fidelity switch stands or falls on. `EditorModel` scales
    /// the descriptor down while the picture is moving and scales it by 1 the moment it
    /// stops, so the whole guarantee reduces to this: `scaled(by: 1)` must be a no-op, not
    /// approximately a no-op. Checked twice over — as a value, so no field was touched, and
    /// as rendered bytes, so no field that *isn't* compared by `==` could have been either.
    @Test func describingAFrameAtFullSizeChangesNothingAtAll() throws {
        let timeline = RenderWorkload.timeline(regions: 6, duration: 12)
        let track = RenderWorkload.cursorTrack(duration: 12)
        let builder = SceneBuilder(videoSize: CGSize(width: 640, height: 360), displayScale: 2)
        let source = RenderWorkload.source(CGSize(width: 640, height: 360))
        let renderer = SceneRenderer()

        for at in stride(from: 0.4, through: 11.4, by: 1.1) {
            let exported = builder.descriptor(for: timeline, at: RenderWorkload.time(at), cursor: track)
            let atRest = exported.scaled(by: 1)
            #expect(atRest == exported, "the frame at rest moved at \(at)s")
            #expect(fingerprint(atRest) == fingerprint(exported))

            // The picture to within Core Image's rounding (`coreImageRounding`): the
            // exactness this test is about is the descriptor's, asserted just above.
            let written = try #require(renderer.cgImage(for: exported, source: source))
            let shown = try #require(renderer.cgImage(for: atRest, source: source))
            #expect(try samePicture(shown, written), "the preview at rest drew \(at)s differently from the export")
        }
    }

    /// A scaled descriptor is smaller in output pixels and unchanged in everything
    /// normalised.
    ///
    /// Which is the claim `scaled(by:)`'s comment makes, and the reason it is allowed to be
    /// four lines long: if a normalised field were scaled too it would be scaled *twice* —
    /// once here and once by the renderer multiplying it back up by the new output size —
    /// and the pointer would drift to a quarter of the way across a half-size frame.
    @Test func scalingAFrameMovesOnlyWhatIsMeasuredInPixels() {
        let timeline = RenderWorkload.timeline(regions: 6, duration: 12)
        let track = RenderWorkload.cursorTrack(duration: 12)
        let builder = SceneBuilder(videoSize: CGSize(width: 3_840, height: 2_160), displayScale: 2)

        for at in stride(from: 0.4, through: 11.4, by: 1.1) {
            let full = builder.descriptor(for: timeline, at: RenderWorkload.time(at), cursor: track)
            let half = full.scaled(by: 0.5)

            #expect(half.outputSize.width == (full.outputSize.width / 2).rounded())
            #expect(half.outputSize.height == (full.outputSize.height / 2).rounded())
            #expect(half.videoFrame.width == full.videoFrame.width / 2)
            #expect(half.videoFrame.minX == full.videoFrame.minX / 2)
            #expect(half.cornerRadius == full.cornerRadius / 2)
            #expect(half.shadowRadius == full.shadowRadius / 2)

            // Everything normalised, untouched — and `sourceTime` above all, because the
            // preview showing a *different moment* than the export is the one divergence
            // this whole exercise refused to accept.
            #expect(half.sourceTime == full.sourceTime)
            #expect(half.sourceCrop == full.sourceCrop)
            #expect(half.zoom == full.zoom)
            #expect(half.zoomCenter == full.zoomCenter)
            #expect(half.background == full.background)
            #expect(half.backgroundBlur == full.backgroundBlur)
            #expect(half.shadowOpacity == full.shadowOpacity)
            #expect(half.blurs == full.blurs)
            #expect(half.cursor == full.cursor)
            #expect(half.annotations == full.annotations)
            #expect(half.caption == full.caption)

            // And the video still sits in the same relative place, which is what makes the
            // overlays — which map through `outputSize` — land on the same spot either way.
            #expect(abs(half.videoFrame.midX / half.outputSize.width
                        - full.videoFrame.midX / full.outputSize.width) < 0.001)
        }
    }

    /// Scaling is a description, not a resample: the smaller frame is a real composite at
    /// the smaller size.
    ///
    /// Worth asserting because the lazy alternative — render the full frame and shrink the
    /// result — would pass every test above while paying the full cost, which is the one
    /// thing the preview path exists not to do. A `CGImage` of the scaled size is the
    /// evidence that Core Image was never asked for the big one.
    @Test func aScaledFrameIsDrawnAtItsOwnSize() throws {
        let builder = SceneBuilder(videoSize: CGSize(width: 1_920, height: 1_080), displayScale: 2)
        let scene = builder.descriptor(for: RenderWorkload.timeline(regions: 4, duration: 8),
                                       at: RenderWorkload.time(2.5),
                                       cursor: RenderWorkload.cursorTrack(duration: 8))
        let quarter = scene.scaled(by: 0.25)
        let image = try #require(SceneRenderer().cgImage(for: quarter, source: nil))
        #expect(image.width == Int(quarter.outputSize.width))
        #expect(image.height == Int(quarter.outputSize.height))
        #expect(image.width < Int(scene.outputSize.width))
    }

    /// The same renderer asked for the same frame twice hands back the same bytes.
    ///
    /// `SceneTests.thesameSceneRendersIdenticallyTwice` compares one pixel; this compares
    /// all of them, over a frame that has a caption, a label, a pointer and a blur in it.
    /// To within Core Image's rounding: this is the very frame (3.7 s, a caption fading
    /// in) that Core Image was seen to draw both ways — see `coreImageRounding`.
    @Test func theSameFrameRendersToTheSameBytesTwice() throws {
        let timeline = RenderWorkload.timeline(regions: 6, duration: 12)
        let track = RenderWorkload.cursorTrack(duration: 12)
        let builder = SceneBuilder(videoSize: CGSize(width: 640, height: 360), displayScale: 2)
        let renderer = SceneRenderer()
        let source = RenderWorkload.source(CGSize(width: 640, height: 360))
        let scene = builder.descriptor(for: timeline, at: RenderWorkload.time(3.7), cursor: track)

        let first = try #require(renderer.cgImage(for: scene, source: source))
        let second = try #require(renderer.cgImage(for: scene, source: source))
        #expect(try samePicture(first, second))
    }

    /// Core Image rounding a faded plate differently is the same picture; a different
    /// plate is not.
    ///
    /// The regression test for the flake `coreImageRounding` describes, made to happen on
    /// demand. Core Image chose its second way on its own, under load; here the graph is
    /// split with an intermediate buffer, which is the same kind of choice made
    /// deliberately, and on this machine it moves the faded plate by exactly one step.
    /// With the old byte-for-byte comparison the first expectation failed every time. The
    /// second is what keeps the tolerance honest: a plate one word different must still
    /// be told apart.
    @Test func coreImagesOwnRoundingIsNotADifferentPicture() throws {
        let output = CGSize(width: 640, height: 360)
        let frame = CGRect(origin: .zero, size: output)
        let background = ColorValue(r: 0.2, g: 0.25, b: 0.5)
        var scene = SceneDescriptor(outputSize: output, background: .color(background), videoFrame: frame)
        // Part-way through fading in, which is what puts the plate through a colour matrix.
        scene.caption = CaptionLayer(text: "Now open the settings panel",
                                     fontSize: 0.06,
                                     color: ColorValue(r: 1, g: 1, b: 1),
                                     backgroundOpacity: 0.5,
                                     position: .bottom,
                                     margin: 0.05,
                                     opacity: 0.83)
        let renderer = SceneRenderer()
        let drawn = try #require(renderer.cgImage(for: scene, source: nil))

        let caption = try #require(scene.caption)
        let plate = try #require(CaptionArtwork.image(caption, outputSize: output))
        let flat = CIImage(color: CIColor(red: background.r, green: background.g, blue: background.b)).cropped(to: frame)
        let split = try #require(renderer.context.createCGImage(
            plate.insertingIntermediate(cache: false).composited(over: flat), from: frame))
        let difference = try largestDifference(drawn, split)
        #expect(try samePicture(drawn, split), "by \(difference.map(String.init) ?? "shape")")

        var other = scene
        other.caption?.text = "Now open the settings window"
        let different = try #require(renderer.cgImage(for: other, source: nil))
        #expect(try !samePicture(drawn, different))
    }
}
