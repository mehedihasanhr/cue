import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// The shapes a finished frame can have: the three new presets, the typed one, and
/// what an older or a newer project file does to them.
struct AspectShapeTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - Presets

    @Test func theNewPresetsHaveTheRatiosTheyName() throws {
        #expect(abs(try #require(AspectPreset.portrait4x5.ratio) - 0.8) < 1e-12)
        #expect(abs(try #require(AspectPreset.portrait3x4.ratio) - 0.75) < 1e-12)
        #expect(abs(try #require(AspectPreset.wide16x10.ratio) - 1.6) < 1e-12)
    }

    /// The stored words are what every project written so far carries, and a rename would
    /// make each of those projects open at the wrong shape.
    @Test func theStoredNamesOfTheOldShapesAreUnchanged() {
        #expect(AspectPreset.source.rawValue == "source")
        #expect(AspectPreset.wide16x9.rawValue == "wide16x9")
        #expect(AspectPreset.square.rawValue == "square")
        #expect(AspectPreset.vertical9x16.rawValue == "vertical9x16")
        #expect(AspectPreset.classic4x3.rawValue == "classic4x3")
    }

    @Test func thePickerOrderListsEveryShapeOnce() {
        #expect(Set(AspectPreset.menuOrder) == Set(AspectPreset.allCases))
        #expect(AspectPreset.menuOrder.count == AspectPreset.allCases.count)
        #expect(AspectPreset.menuOrder.first == .source)
        #expect(AspectPreset.menuOrder.last == .custom)
    }

    @Test func customHasNoRatioOfItsOwn() {
        // The numbers live on the style, which is the only place that knows them.
        #expect(AspectPreset.custom.ratio == nil)
        var style = FrameStyle()
        style.aspect = .custom
        style.customAspect = CustomAspect(width: 21, height: 9)
        #expect(abs((style.aspectRatio ?? 0) - 21.0 / 9) < 1e-12)
        style.aspect = .square
        #expect(style.aspectRatio == 1)
        style.aspect = .source
        #expect(style.aspectRatio == nil)
    }

    // MARK: - Typed numbers

    @Test func typedNumbersAreCheckedAndTheReasonsAreSentences() {
        #expect(CustomAspect.refusal(width: 4, height: 5) == nil)
        #expect(CustomAspect.refusal(width: 0, height: 5) == .outOfRange)
        #expect(CustomAspect.refusal(width: 101, height: 5) == .outOfRange)
        #expect(CustomAspect.refusal(width: 4, height: 1) == .tooWide)
        #expect(CustomAspect.refusal(width: 1, height: 4) == .tooTall)
        #expect(CustomAspect.refusal(width: 3, height: 1) == nil, "3 : 1 is the limit, and allowed")
        #expect(CustomAspect.refusal(width: 1, height: 3) == nil)
        #expect(CustomAspect.refusal(width: "4", height: "5") == nil)
        #expect(CustomAspect.refusal(width: "4.5", height: "5") == .notWhole)
        #expect(CustomAspect.refusal(width: "", height: "5") == .notWhole)
        #expect(CustomAspect.refusal(width: " 16 ", height: "10") == nil)
        for refusal in [CustomAspect.Refusal.notWhole, .outOfRange, .tooWide, .tooTall] {
            #expect(!refusal.message.isEmpty)
        }
    }

    @Test func aStoredShapeIsAlwaysOneTheRendererCanDraw() {
        let wild = CustomAspect(width: 500, height: 0)
        #expect(wild.width == 100)
        #expect(wild.height == 1)
        // The sides are kept as typed and the *ratio* is held inside the limits.
        #expect(wild.ratio == 3)
        #expect(CustomAspect(width: 1, height: 100).ratio == 1.0 / 3)
        #expect(CustomAspect().title == "3 : 2")
    }

    @Test func aHalfWrittenCustomShapeDecodesToTheDefault() throws {
        let decoded = try JSONDecoder().decode(CustomAspect.self, from: Data(#"{"width": "wide"}"#.utf8))
        #expect(decoded == CustomAspect())
        let partial = try JSONDecoder().decode(CustomAspect.self, from: Data(#"{"width": 5}"#.utf8))
        #expect(partial == CustomAspect(width: 5, height: 2))
    }

    // MARK: - The style, read back

    /// A project written before the border and the typed shape existed carries none of
    /// their keys, and must open with the background and padding it had.
    @Test func aProjectWrittenBeforeTheBorderExistedKeepsItsStyle() throws {
        var original = Timeline(sourceDuration: time(30))
        original.style.padding = 0.13
        original.style.background = .color(ColorValue(r: 0.2, g: 0.3, b: 0.4))
        original.style.aspect = .square
        let data = try JSONEncoder().encode(original)
        var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var style = try #require(fields["style"] as? [String: Any])
        style.removeValue(forKey: "customAspect")
        style.removeValue(forKey: "borderWidth")
        style.removeValue(forKey: "borderColor")
        fields["style"] = style

        let decoded = try JSONDecoder().decode(Timeline.self, from: try JSONSerialization.data(withJSONObject: fields))
        #expect(decoded.style.padding == 0.13)
        #expect(decoded.style.background == .color(ColorValue(r: 0.2, g: 0.3, b: 0.4)))
        #expect(decoded.style.aspect == .square)
        #expect(decoded.style.borderWidth == 0, "no border, which is what that project drew")
        #expect(decoded.style.borderColor == .white)
        #expect(decoded.style.customAspect == CustomAspect())
        #expect(decoded.style == original.style)
    }

    /// A newer build's shape costs this one the shape and nothing else.
    @Test func aShapeThisBuildDoesNotKnowFallsBackToTheRecordingsOwn() throws {
        var original = Timeline(sourceDuration: time(30))
        original.style.padding = 0.11
        original.style.borderWidth = 0.01
        let data = try JSONEncoder().encode(original)
        var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var style = try #require(fields["style"] as? [String: Any])
        style["aspect"] = "ultrawide21x9"
        fields["style"] = style

        let decoded = try JSONDecoder().decode(Timeline.self, from: try JSONSerialization.data(withJSONObject: fields))
        #expect(decoded.style.aspect == .source)
        #expect(decoded.style.padding == 0.11)
        #expect(decoded.style.borderWidth == 0.01)
    }

    @Test func theNewFieldsSurviveARoundTrip() throws {
        var original = Timeline(sourceDuration: time(30))
        original.style.aspect = .custom
        original.style.customAspect = CustomAspect(width: 7, height: 5)
        original.style.borderWidth = 0.012
        original.style.borderColor = ColorValue(r: 0.1, g: 0.2, b: 0.3, a: 0.5)
        let decoded = try JSONDecoder().decode(Timeline.self, from: try JSONEncoder().encode(original))
        #expect(decoded.style == original.style)
    }

    @Test func theBorderRangeIsTheOneTheSliderAndTheRendererShare() {
        #expect(FrameStyle.borderWidthRange.lowerBound == 0)
        #expect(FrameStyle.borderWidthRange.upperBound > 0)
        #expect(FrameStyle.borderWidthRange.upperBound <= 0.1, "a border is a line, not a mat")
    }
}
