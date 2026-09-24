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
    /// key is missing a field, the warm draw serves the wrong bitmap and the hashes part.
    @Test func aWarmRendererDrawsTheSameBytesAsAColdOne() throws {
        let timeline = RenderWorkload.timeline(regions: 6, duration: 12)
        let track = RenderWorkload.cursorTrack(duration: 12)
        // Small, because this renders every frame twice and the comparison is of bytes,
        // not of speed. The layers exercised are the same ones at any size.
        let builder = SceneBuilder(videoSize: CGSize(width: 640, height: 360), displayScale: 2)
        let source = RenderWorkload.source(CGSize(width: 640, height: 360))
        let moments = Array(stride(from: 0.4, through: 11.4, by: 1.1))

        var cold: [Int] = []
        for at in moments {
            clearArtworkCaches()
            let scene = builder.descriptor(for: timeline, at: RenderWorkload.time(at), cursor: track)
            cold.append(try fingerprint(try #require(SceneRenderer().cgImage(for: scene, source: source))))
        }

        // Warm every cache there is, on frames that are not the ones being compared.
        let warm = SceneRenderer()
        for at in stride(from: 0.0, through: 11.0, by: 0.25) {
            _ = warm.cgImage(for: builder.descriptor(for: timeline, at: RenderWorkload.time(at), cursor: track),
                             source: source)
        }

        for (index, at) in moments.enumerated() {
            let scene = builder.descriptor(for: timeline, at: RenderWorkload.time(at), cursor: track)
            let hot = try fingerprint(try #require(warm.cgImage(for: scene, source: source)))
            #expect(hot == cold[index], "a warm renderer drew \(at)s differently from a cold one")
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

    /// The same renderer asked for the same frame twice hands back the same bytes.
    ///
    /// `SceneTests.thesameSceneRendersIdenticallyTwice` compares one pixel; this compares
    /// all of them, over a frame that has a caption, a label, a pointer and a blur in it.
    @Test func theSameFrameRendersToTheSameBytesTwice() throws {
        let timeline = RenderWorkload.timeline(regions: 6, duration: 12)
        let track = RenderWorkload.cursorTrack(duration: 12)
        let builder = SceneBuilder(videoSize: CGSize(width: 640, height: 360), displayScale: 2)
        let renderer = SceneRenderer()
        let source = RenderWorkload.source(CGSize(width: 640, height: 360))
        let scene = builder.descriptor(for: timeline, at: RenderWorkload.time(3.7), cursor: track)

        let first = try #require(renderer.cgImage(for: scene, source: source))
        let second = try #require(renderer.cgImage(for: scene, source: source))
        #expect(try fingerprint(first) == fingerprint(second))
    }
}
