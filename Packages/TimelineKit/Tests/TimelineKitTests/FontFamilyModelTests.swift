import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// A family of type chosen by name, as the project stores it.
@Suite("Font families in the project")
struct FontFamilyModelTests {
    private func timeline() -> Timeline {
        Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
    }

    @Test("Captions written before families existed open in the system's type")
    func oldCaptionStyle() throws {
        let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(#"{"typeface":"rounded"}"#.utf8))
        #expect(style.fontFamily == "")
        #expect(style.typeface == .rounded)
    }

    @Test("A caption family survives saving and opening")
    func roundTrip() throws {
        var style = CaptionStyle()
        style.fontFamily = "Georgia"
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(CaptionStyle.self, from: data).fontFamily == "Georgia")
    }

    @Test("The captions' family travels with a look, and a look without one takes it off")
    func look() {
        var source = timeline()
        source.captionStyle.fontFamily = "Avenir Next"
        var target = timeline()
        Look(name: "Avenir", capturing: source).apply(to: &target)
        #expect(target.captionStyle.fontFamily == "Avenir Next")

        Look(name: "Plain", capturing: timeline()).apply(to: &target)
        #expect(target.captionStyle.fontFamily == "", "the system's type is a choice a look makes too")
    }

    @Test("A look file from before families leaves the project's family alone")
    func oldLook() throws {
        let look = try #require(Look.decoded(from: Data(#"{ "name": "Old", "captions": { "fontSize": 0.06 } }"#.utf8)))
        var target = timeline()
        target.captionStyle.fontFamily = "Georgia"
        look.apply(to: &target)
        #expect(target.captionStyle.fontFamily == "Georgia")
        #expect(target.captionStyle.fontSize == 0.06)
    }
}
