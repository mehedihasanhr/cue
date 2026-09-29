import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Words set in a family chosen by name: a different family draws differently, and one this
/// Mac does not have draws exactly what the system's type draws.
@Suite("Font families", .serialized)
struct FontFamilyRenderTests {
    /// Families every Mac has. A test that picked something from the user's own font folder
    /// would pass on one machine only.
    private static let serif = "Georgia"
    private static let mono = "Menlo"
    private static let missing = "Klik No Such Family"

    private static let size = CGSize(width: 800, height: 450)

    /// Every byte of `image` over a transparent frame of `size`.
    private func bytes(_ image: CIImage?, size: CGSize = Self.size) throws -> [UInt8] {
        let image = try #require(image)
        let width = Int(size.width), height = Int(size.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: width * 4,
                           bounds: CGRect(origin: .zero, size: size),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    private func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    // MARK: - Finding a family

    @Test("A family is found by name, and a missing or empty one is not")
    func lookup() throws {
        #expect(FontFamilies.isInstalled(Self.serif))
        #expect(FontFamilies.isInstalled("  \(Self.mono) "), "the name is read without the spaces round it")
        #expect(!FontFamilies.isInstalled(Self.missing))
        #expect(!FontFamilies.isInstalled(""))
        #expect(FontFamilies.font(family: Self.missing, size: 20, weight: .regular) == nil)
        let georgia = try #require(FontFamilies.font(family: Self.serif, size: 20, weight: .bold))
        #expect(georgia.familyName == Self.serif)
        #expect(georgia.fontDescriptor.symbolicTraits.contains(.bold), "the nearest weight the family has")
        #expect(FontFamilies.curatedInstalled.allSatisfy(FontFamilies.isInstalled))
        #expect(!FontFamilies.curatedInstalled.isEmpty)
    }

    // MARK: - Annotations

    private func label(_ kind: AnnotationItem.Kind = .text("Quick brown fox"), family: String) -> AnnotationLayer {
        AnnotationLayer(kind: kind, rect: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.5),
                        color: .white, fontSize: 0.1, opacity: 1,
                        style: AnnotationStyle(fontFamily: family))
    }

    private func drawn(_ layer: AnnotationLayer) throws -> [UInt8] {
        AnnotationArtwork.clearCache()
        let rect = CGRect(x: layer.rect.minX * Self.size.width, y: layer.rect.minY * Self.size.height,
                          width: layer.rect.width * Self.size.width, height: layer.rect.height * Self.size.height)
        return try bytes(AnnotationArtwork.image(layer, in: rect, outputHeight: Self.size.height))
    }

    @Test("A label in another family is drawn differently")
    func labelFamiliesDiffer() throws {
        let system = try drawn(label(family: ""))
        let serif = try drawn(label(family: Self.serif))
        let mono = try drawn(label(family: Self.mono))
        #expect(differing(system, serif) > 500)
        #expect(differing(serif, mono) > 500)
    }

    @Test("A label in a family this Mac does not have is the system's type, to the byte")
    func labelMissingFallsBack() throws {
        #expect(try drawn(label(family: Self.missing)) == drawn(label(family: "")))
    }

    @Test("A callout's words follow the family too")
    func calloutFamily() throws {
        let kind = AnnotationItem.Kind.callout("Click here", tail: CGPoint(x: 0.5, y: 1.4))
        let system = try drawn(label(kind, family: ""))
        #expect(differing(system, try drawn(label(kind, family: Self.serif))) > 500)
        #expect(try drawn(label(kind, family: Self.missing)) == system)
    }

    @Test("A label's box is measured in the family it is drawn in")
    func fitFollowsFamily() {
        func size(_ family: String) -> CGSize {
            AnnotationFit.labelSize("Quick brown fox jumps", style: AnnotationStyle(fontFamily: family),
                                    color: .white, fontSize: 0.06, maxWidth: 1, frame: CGSize(width: 1_920, height: 1_080))
        }
        #expect(size(Self.mono).width > size("").width * 1.1, "Menlo's letters are wider than the system's")
        #expect(size(Self.missing) == size(""), "a missing family is measured as the type it is drawn in")
    }

    @Test("An annotation style written before families existed opens with the system's type")
    func oldStyleDecodes() throws {
        let style = try JSONDecoder().decode(AnnotationStyle.self, from: Data(#"{"weight":"bold"}"#.utf8))
        #expect(style.fontFamily == "")
        let chosen = try JSONDecoder().decode(AnnotationStyle.self, from: Data(#"{"fontFamily":" Georgia "}"#.utf8))
        #expect(chosen.fontFamily == "Georgia")
        let wrong = try JSONDecoder().decode(AnnotationStyle.self, from: Data(#"{"fontFamily":12}"#.utf8))
        #expect(wrong.fontFamily == "", "a value of the wrong kind costs the family, not the style")
    }

    // MARK: - Captions

    private func caption(family: String, typeface: CaptionStyle.Typeface = .standard) -> CaptionLayer {
        CaptionLayer(text: "Open the settings panel", fontSize: 0.07, color: .white, backgroundOpacity: 0.6,
                     position: .bottom, margin: 0.08, typeface: typeface, fontFamily: family)
    }

    private func drawn(_ caption: CaptionLayer) throws -> [UInt8] {
        CaptionArtwork.clearCache()
        return try bytes(CaptionArtwork.image(caption, outputSize: Self.size))
    }

    @Test("A caption in another family is drawn differently")
    func captionFamiliesDiffer() throws {
        #expect(differing(try drawn(caption(family: "")), try drawn(caption(family: Self.mono))) > 500)
    }

    @Test("A caption in a missing family is the typeface it would have had, to the byte")
    func captionMissingFallsBack() throws {
        #expect(try drawn(caption(family: Self.missing)) == drawn(caption(family: "")))
        #expect(try drawn(caption(family: Self.missing, typeface: .serif)) == drawn(caption(family: "", typeface: .serif)))
    }

    @Test("The captions' family reaches the picture from the project")
    func captionFromTimeline() {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.captions = [CaptionCue(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600), text: "Hi")]
        timeline.captionStyle.fontFamily = Self.serif
        let scene = SceneBuilder(videoSize: CGSize(width: 1_280, height: 720))
            .descriptor(for: timeline, at: CMTime(seconds: 2, preferredTimescale: 600))
        #expect(scene.caption?.fontFamily == Self.serif)
    }

    // MARK: - Title slides

    private func title(family: String) -> TitleLayer {
        TitleLayer(title: "Getting started", subtitle: "Part one", fontFamily: family)
    }

    private func drawn(_ title: TitleLayer) throws -> [UInt8] {
        TitleArtwork.clearCache()
        var scene = SceneDescriptor(outputSize: Self.size, background: .color(.black),
                                    videoFrame: CGRect(origin: .zero, size: Self.size))
        scene.title = title
        return try bytes(TitleArtwork.image(title, in: scene))
    }

    @Test("A title in another family is drawn differently, and a missing one as the system's type")
    func titleFamily() throws {
        let system = try drawn(title(family: ""))
        #expect(differing(system, try drawn(title(family: Self.serif))) > 500)
        #expect(try drawn(title(family: Self.missing)) == system)
    }

    @Test("A title card carries its family to the slide, and an old card opens without one")
    func titleCard() throws {
        let card = TitleCard(title: "Hi", fontFamily: Self.serif)
        #expect(TitleLayer(card, elapsed: 1).fontFamily == Self.serif)
        let old = try JSONDecoder().decode(TitleCard.self, from: Data(#"{"title":"Hi","typeface":"serif"}"#.utf8))
        #expect(old.fontFamily == "")
        #expect(old.typeface == .serif)
    }
}
