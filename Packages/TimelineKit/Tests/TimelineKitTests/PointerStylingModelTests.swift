import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// The pointer's style, spotlight and magnifier, as stored.
@Suite("Pointer styles, spotlight and magnifier in the project")
struct PointerStylingModelTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Old and new files

    /// A project written before there were styles draws the pointer it always drew, with
    /// neither effect on, and keeps every setting it did have.
    @Test func anOldProjectDrawsThePointerAsRecorded() throws {
        let style = try decode(CursorStyle.self, #"{"scale": 2.2, "motionBlur": true}"#)
        #expect(style.appearance == .asRecorded)
        #expect(style.dotColor == CursorStyle.defaultDotColor)
        #expect(!style.spotlight.isEnabled)
        #expect(!style.magnifier.isEnabled)
        #expect(style.scale == 2.2)
        #expect(style.motionBlur)
    }

    /// A style a newer build wrote is drawn as recorded, and costs nothing else.
    @Test func aStyleThisBuildDoesNotKnowIsDrawnAsRecorded() throws {
        let style = try decode(CursorStyle.self, #"{"appearance": "sparkle", "scale": 1.9, "dotColor": {"r": 0, "g": 1, "b": 0, "a": 1}}"#)
        #expect(style.appearance == .asRecorded)
        #expect(style.scale == 1.9)
        #expect(style.dotColor == ColorValue(r: 0, g: 1, b: 0))
    }

    @Test func everyStyleSurvivesBeingSaved() throws {
        for appearance in CursorStyle.Appearance.allCases {
            var style = CursorStyle()
            style.appearance = appearance
            style.dotColor = ColorValue(r: 0.2, g: 0.4, b: 1)
            style.spotlight = PointerSpotlight(isEnabled: true, radius: 0.3, dimming: 0.7, scope: .markedStretches)
            style.magnifier = PointerMagnifier(isEnabled: true, factor: 2.5, diameter: 0.4, scope: .markedStretches)
            let back = try JSONDecoder().decode(CursorStyle.self, from: JSONEncoder().encode(style))
            #expect(back == style)
        }
    }

    /// A file can say anything; the renderer is only ever handed what a slider could set.
    @Test func settingsOutOfRangeAreHeldToTheirRanges() throws {
        let spotlight = try decode(PointerSpotlight.self, #"{"isEnabled": true, "radius": 40, "dimming": -3}"#)
        #expect(spotlight.isEnabled)
        #expect(spotlight.radius == PointerSpotlight.radiusRange.upperBound)
        #expect(spotlight.dimming == PointerSpotlight.dimmingRange.lowerBound)
        #expect(spotlight.scope == .everywhere)

        let magnifier = try decode(PointerMagnifier.self, #"{"isEnabled": true, "factor": 12, "diameter": 0, "scope": "nowhere"}"#)
        #expect(magnifier.factor == PointerMagnifier.factorRange.upperBound)
        #expect(magnifier.diameter == PointerMagnifier.diameterRange.lowerBound)
        #expect(magnifier.scope == .everywhere)
    }

    // MARK: - Stretches

    @Test func anOldStretchNeitherSpotlightsNorMagnifies() throws {
        let region = try decode(CursorRegion.self, #"{"start": {"value": 0, "timescale": 600}, "duration": {"value": 1200, "timescale": 600}}"#)
        #expect(!region.spotlights)
        #expect(!region.magnifies)
        #expect(region.isHidden)
    }

    @Test func aStretchThatOnlySpotlightsIsDoingSomething() {
        let region = CursorRegion(start: time(1), duration: time(2), isHidden: false, spotlights: true)
        #expect(!region.isInert)
        #expect(region.title == "Spotlight")
        #expect(CursorRegion(start: time(1), duration: time(2), isHidden: false, magnifies: true).title == "Magnified")
    }

    @Test func aCopiedStretchKeepsWhatItTurnsOn() throws {
        let timeline = Timeline(sourceDuration: time(30))
        let region = CursorRegion(start: time(1), duration: time(2), isHidden: false,
                                  spotlights: true, magnifies: true)
        guard case .cursor(let copy)? = CopiedRegion.cursor(region).placed(at: time(10), in: timeline) else {
            Issue.record("the stretch did not paste")
            return
        }
        #expect(copy.spotlights)
        #expect(copy.magnifies)
        #expect(copy.sanitised.spotlights && copy.sanitised.magnifies)
    }

    @Test func anEffectOnEverywhereIsAlwaysIn() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.cursor.spotlight.isEnabled = true
        #expect(timeline.pointerEffectPresence(at: time(4)).spotlight == 1)
        #expect(timeline.pointerEffectPresence(at: time(4)).magnifier == 0)
    }

    /// Limited to stretches, an effect is in only where a stretch asks for it, and arrives
    /// and leaves over the stretch's ramp.
    @Test func anEffectLimitedToStretchesFollowsThem() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.cursor.magnifier = PointerMagnifier(isEnabled: true, scope: .markedStretches)
        timeline.cursor.spotlight = PointerSpotlight(isEnabled: true, scope: .markedStretches)
        timeline.cursorRegions = [
            CursorRegion(start: time(2), duration: time(4), isHidden: false,
                         transition: time(0.5), magnifies: true),
        ]
        #expect(timeline.pointerEffectPresence(at: time(1)).magnifier == 0)
        #expect(timeline.pointerEffectPresence(at: time(4)).magnifier == 1)
        let arriving = timeline.pointerEffectPresence(at: time(2.25)).magnifier
        #expect(arriving > 0 && arriving < 1)
        #expect(timeline.pointerEffectPresence(at: time(4)).spotlight == 0, "the stretch does not ask for it")
    }

    // MARK: - Looks

    @Test func aLookCarriesTheStyleAndBothEffects() throws {
        var source = Timeline(sourceDuration: time(10))
        source.cursor.appearance = .dot
        source.cursor.dotColor = ColorValue(r: 0.1, g: 0.8, b: 0.3)
        source.cursor.spotlight = PointerSpotlight(isEnabled: true, radius: 0.2, dimming: 0.8)
        source.cursor.magnifier = PointerMagnifier(isEnabled: true, factor: 3, diameter: 0.2, scope: .markedStretches)
        let look = Look(name: "Presenter", capturing: source)
        // Through a file, as a saved look travels.
        let saved = try JSONDecoder().decode(Look.self, from: JSONEncoder().encode(look))
        var target = Timeline(sourceDuration: time(10))
        saved.apply(to: &target)
        #expect(target.cursor.appearance == .dot)
        #expect(target.cursor.dotColor == source.cursor.dotColor)
        #expect(target.cursor.spotlight == source.cursor.spotlight)
        #expect(target.cursor.magnifier == source.cursor.magnifier)
    }

    /// A look saved before there were styles leaves the project's style alone.
    @Test func anOldLookLeavesTheStyleAlone() throws {
        let pointer = try decode(Look.Pointer.self, #"{"scale": 2}"#)
        var style = CursorStyle()
        style.appearance = .minimal
        pointer.apply(to: &style)
        #expect(style.appearance == .minimal)
        #expect(style.scale == 2)
    }

    /// A project saved with one of the drawn styles that the system pointers replaced
    /// opens on the system pointer nearest to it.
    @Test func aRetiredStyleOpensAsTheNearestSystemPointer() throws {
        let expected: [String: CursorStyle.Appearance] = [
            "blackArrow": .macOS14, "softArrow": .macOS26, "colourArrow": .macOS26Colour,
            "hand": .macOS26, "touch": .dot, "ring": .dot, "crosshair": .asRecorded,
        ]
        for (raw, appearance) in expected {
            let style = try decode(CursorStyle.self, #"{"appearance": "\#(raw)"}"#)
            #expect(style.appearance == appearance, "\(raw)")
        }
        // And the system pointers follow the pointer's shape, as the recorded one does.
        #expect(CursorStyle.Appearance.allCases.filter(\.followsRecordedShape)
                == [.asRecorded, .macOS26, .macOS14, .macOS26White, .macOS14White, .macOS26Colour,
                    .classicKlik, .gradient, .neon, .frost])
    }
}
