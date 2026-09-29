import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// Captions drawn the way the project says.
struct CaptionStyleRenderTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let output = CGSize(width: 1_280, height: 720)

    private func layer(_ text: String = "Open the settings panel",
                       spoken: Int? = nil,
                       typeface: CaptionStyle.Typeface = .standard) -> CaptionLayer {
        CaptionLayer(text: text, fontSize: 0.06, color: .white, backgroundOpacity: 0.6,
                     position: .bottom, margin: 0.08, typeface: typeface, spokenWord: spoken,
                     highlightColor: ColorValue(r: 1, g: 0.1, b: 0.1))
    }

    /// The plate as pixels, with where it is.
    private func drawn(_ layer: CaptionLayer) throws -> (extent: CGRect, red: Int, white: Int) {
        CaptionArtwork.clearCache()
        let image = try #require(CaptionArtwork.image(layer, outputSize: output))
        let extent = image.extent
        let width = Int(output.width), height = Int(output.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: width * 4,
                           bounds: CGRect(origin: .zero, size: output),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var red = 0, white = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = bytes[index], g = bytes[index + 1], b = bytes[index + 2]
            if r > 200, g < 90, b < 90 { red += 1 }
            if r > 220, g > 220, b > 220 { white += 1 }
        }
        return (extent, red, white)
    }

    // MARK: - The word being said

    @Test func aLineWithNoWordLitIsOneColour() throws {
        #expect(try drawn(layer()).red == 0)
    }

    @Test func theWordBeingSaidIsLit() throws {
        let plain = try drawn(layer())
        let lit = try drawn(layer(spoken: 2))
        #expect(lit.red > 50)
        #expect(lit.white < plain.white, "and the rest of the line is as it was, less that word")
    }

    /// The colour changes and nothing else does, so the line does not jump about as the
    /// highlight moves along it.
    @Test func lightingAWordDoesNotMoveTheLine() throws {
        let plain = try drawn(layer()).extent
        for word in 0..<4 {
            #expect(try drawn(layer(spoken: word)).extent == plain)
        }
    }

    @Test func aWordThatIsNotThereLightsNothing() throws {
        #expect(try drawn(layer(spoken: 40)).red == 0)
    }

    @Test func wordsAreCountedTheWayTheCaptionCountsThem() {
        let text = "Open  the\nsettings panel"
        #expect(CaptionArtwork.wordRange(0, in: text).map { String(text[$0]) } == "Open")
        #expect(CaptionArtwork.wordRange(1, in: text).map { String(text[$0]) } == "the")
        #expect(CaptionArtwork.wordRange(2, in: text).map { String(text[$0]) } == "settings")
        #expect(CaptionArtwork.wordRange(3, in: text).map { String(text[$0]) } == "panel")
        #expect(CaptionArtwork.wordRange(4, in: text) == nil)
        #expect(CaptionArtwork.wordRange(-1, in: text) == nil)
    }

    // MARK: - Type

    @Test func everyTypefaceIsAFontOfItsOwn() {
        let names = CaptionStyle.Typeface.allCases.map { CaptionArtwork.font($0, size: 40).fontName }
        #expect(Set(names).count == CaptionStyle.Typeface.allCases.count)
    }

    @Test func theTypefaceChangesThePlate() throws {
        let standard = try drawn(layer(typeface: .standard)).extent
        let monospaced = try drawn(layer(typeface: .monospaced)).extent
        #expect(standard.width != monospaced.width)
    }

    /// The end of a line is drawn, whatever the plate's size rounds to.
    ///
    /// The plate used to be rounded to the nearest pixel, and when that was down the words
    /// were laid out in a fraction of a pixel less room than they had measured: the last
    /// word wrapped onto a line below the plate and was never drawn. Two lines differing
    /// only in their last word then came out as the same picture — "…says step 2." and
    /// "…says step 3." both read "…says". A few sizes and frames, because whether it
    /// happened depended on where each line's width fell between two whole pixels.
    @Test(arguments: [0.04, 0.05, 0.06, 0.07])
    func theLastWordOfALineIsDrawn(fontSize: Double) throws {
        func plate(_ text: String, in output: CGSize) throws -> (extent: CGRect, bytes: [UInt8]) {
            let caption = CaptionLayer(text: text, fontSize: fontSize, color: .white, backgroundOpacity: 0.6,
                                       position: .bottom, margin: 0.08)
            let image = try #require(CaptionArtwork.image(caption, outputSize: output))
            let extent = image.extent.integral
            var bytes = [UInt8](repeating: 0, count: Int(extent.width) * Int(extent.height) * 4)
            CIContext().render(image, toBitmap: &bytes, rowBytes: Int(extent.width) * 4, bounds: extent,
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return (extent, bytes)
        }
        for output in [CGSize(width: 640, height: 360), CGSize(width: 1_280, height: 720),
                       CGSize(width: 1_920, height: 1_080), CGSize(width: 3_840, height: 2_160)] {
            let two = try plate("And then we click the button that says step 2.", in: output)
            let three = try plate("And then we click the button that says step 3.", in: output)
            // Different by whole glyphs, not by a step of rounding: a "2" is not a "3".
            let apart = two.extent != three.extent
                || zip(two.bytes, three.bytes).filter { abs(Int($0) - Int($1)) > 64 }.count > 20
            #expect(apart, "the last word was not drawn at \(Int(output.height))p")
        }
    }

    // MARK: - Arriving and leaving

    @Test func aCaptionThatDoesNotMoveIsSimplyThere() {
        for elapsed in [0.0, 0.01, 1, 2.99] {
            let pose = SceneBuilder.captionPose(.none, elapsed: elapsed, remaining: 3 - elapsed, length: 3)
            #expect(pose.opacity == 1)
            #expect(pose.scale == 1)
            #expect(pose.drop == 0)
        }
    }

    @Test(arguments: [CaptionStyle.Animation.fade, .rise, .pop])
    func onceArrivedEveryStyleIsAtRest(_ animation: CaptionStyle.Animation) {
        let pose = SceneBuilder.captionPose(animation, elapsed: 1.5, remaining: 1.5, length: 3)
        #expect(pose.opacity == 1)
        #expect(abs(pose.scale - 1) < 0.0001)
        #expect(abs(pose.drop) < 0.0001)
    }

    @Test func aRisingLineStartsLowAndEndsInPlace() {
        let early = SceneBuilder.captionPose(.rise, elapsed: 0.02, remaining: 2.98, length: 3)
        let later = SceneBuilder.captionPose(.rise, elapsed: 0.15, remaining: 2.85, length: 3)
        #expect(early.drop > later.drop)
        #expect(later.drop > 0)
        #expect(early.opacity < 1)
    }

    @Test func aPoppingLineGoesPastItsSizeAndSettles() {
        let sizes = stride(from: 0.0, through: 0.3, by: 0.01).map {
            SceneBuilder.captionPose(.pop, elapsed: $0, remaining: 3 - $0, length: 3).scale
        }
        #expect(sizes.first! < 1)
        #expect(sizes.max()! > 1)
        #expect(abs(sizes.last! - 1) < 0.0001)
    }

    /// Only the arrival is decorated. A line that moves as it leaves pulls the eye to
    /// something that is over.
    @Test(arguments: [CaptionStyle.Animation.rise, .pop])
    func everyStyleLeavesWithAFadeAndNothingElse(_ animation: CaptionStyle.Animation) {
        let leaving = SceneBuilder.captionPose(animation, elapsed: 2.95, remaining: 0.05, length: 3)
        #expect(leaving.opacity < 1)
        #expect(abs(leaving.scale - 1) < 0.0001)
        #expect(abs(leaving.drop) < 0.0001)
    }

    // MARK: - From the project to the frame

    @Test func theProjectsCaptionStyleReachesTheFrame() throws {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.captions = [CaptionCue(start: time(2), duration: time(4), text: "one two three four")]
        timeline.captionStyle.typeface = .rounded
        timeline.captionStyle.highlightsWords = true
        timeline.captionStyle.animation = .none
        let builder = SceneBuilder(videoSize: CGSize(width: 1_280, height: 720))

        let caption = try #require(builder.descriptor(for: timeline, at: time(4.2)).caption)
        #expect(caption.typeface == .rounded)
        #expect(caption.spokenWord == 2, "just past half way through four words of equal length")
        #expect(caption.opacity == 1)

        timeline.captionStyle.highlightsWords = false
        #expect(builder.descriptor(for: timeline, at: time(4.2)).caption?.spokenWord == nil)
    }
}
