import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// The four kinds of mask on one region: what an old project reads as, what a copy
/// carries, and what the chip says.
struct MaskRegionTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let rect = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)

    // MARK: - The stored words

    /// Every project written so far stores one of these two, and they must go on
    /// meaning what they meant.
    @Test func theOldKindsKeepTheirStoredNames() {
        #expect(BlurRegion.Style.gaussian.rawValue == "gaussian")
        #expect(BlurRegion.Style.pixelate.rawValue == "pixelate")
        #expect(BlurRegion.Style.cover.rawValue == "cover")
        #expect(BlurRegion.Style.spotlight.rawValue == "spotlight")
        #expect(BlurRegion.Style.allCases.count == 4)
    }

    // MARK: - Reading a project back

    /// A blur written before the cover and the spotlight existed: six keys, and it must
    /// decode to exactly the blur it was.
    @Test func aBlurWrittenBeforeTheNewKindsDecodesWithDefaults() throws {
        let json = """
        {"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
         "start":{"value":600,"timescale":600,"flags":1,"epoch":0},
         "duration":{"value":1200,"timescale":600,"flags":1,"epoch":0},
         "rect":[[0.2,0.3],[0.4,0.2]],"style":"pixelate","radius":31}
        """
        let blur = try JSONDecoder().decode(BlurRegion.self, from: Data(json.utf8))
        #expect(blur.style == .pixelate)
        #expect(blur.radius == 31)
        #expect(blur.rect == rect)
        #expect(blur.color == .black)
        #expect(blur.dimming == BlurRegion.defaultDimming)
        #expect(blur.softness == BlurRegion.defaultSoftness)
        #expect(blur.cornerRadius == 0, "square, which is how it was drawn")
        #expect(blur.id.uuidString == "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")
    }

    /// A kind from a newer build is read as a blur rather than dropped: whatever it was
    /// hiding stays hidden, and the lane keeps every other region.
    @Test func aKindThisBuildDoesNotKnowIsReadAsABlur() throws {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.blurs = [BlurRegion(start: time(1), duration: time(2), rect: rect, style: .cover),
                          BlurRegion(start: time(5), duration: time(2), rect: rect)]
        let data = try JSONEncoder().encode(timeline)
        var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var blurs = try #require(fields["blurs"] as? [[String: Any]])
        blurs[0]["style"] = "glow"
        fields["blurs"] = blurs

        let decoded = try JSONDecoder().decode(Timeline.self, from: try JSONSerialization.data(withJSONObject: fields))
        #expect(decoded.blurs.count == 2)
        #expect(decoded.blurs[0].style == .gaussian)
        #expect(decoded.blurs[0].start == time(1))
        #expect(decoded.blurs[1].id == timeline.blurs[1].id)
    }

    @Test func theNewFieldsSurviveARoundTrip() throws {
        let region = BlurRegion(start: time(1), duration: time(2), rect: rect, style: .spotlight,
                                color: ColorValue(r: 0.9, g: 0.1, b: 0.2, a: 0.7),
                                dimming: 0.35, softness: 0.05, cornerRadius: 0.2)
        let decoded = try JSONDecoder().decode(BlurRegion.self, from: try JSONEncoder().encode(region))
        #expect(decoded == region)
    }

    @Test func aFileThatAsksForTooMuchIsClampedOnTheWayIn() throws {
        let region = BlurRegion(start: time(1), duration: time(2), rect: rect, style: .spotlight,
                                dimming: 4, softness: -1, cornerRadius: 9)
        let decoded = try JSONDecoder().decode(BlurRegion.self, from: try JSONEncoder().encode(region))
        #expect(decoded.dimming == 1)
        #expect(decoded.softness == 0)
        #expect(decoded.cornerRadius == 0.5)
    }

    // MARK: - Copies

    @Test func aPlacedCopyCarriesEveryFieldAndANewIdentity() {
        let region = BlurRegion(start: time(1), duration: time(2), rect: rect, style: .cover,
                                radius: 22, color: ColorValue(r: 0.9, g: 0.1, b: 0.2),
                                dimming: 0.35, softness: 0.05, cornerRadius: 0.2)
        let copy = region.placed(at: time(10), duration: time(3))
        #expect(copy.id != region.id)
        #expect(copy.start == time(10))
        #expect(copy.duration == time(3))
        #expect(copy.rect == region.rect)
        #expect(copy.style == .cover)
        #expect(copy.radius == 22)
        #expect(copy.color == region.color)
        #expect(copy.dimming == 0.35)
        #expect(copy.softness == 0.05)
        #expect(copy.cornerRadius == 0.2)
    }

    /// A cover pasted somewhere else used to come out black whatever colour it was.
    @Test func aPastedCoverKeepsItsColour() throws {
        var timeline = Timeline(sourceDuration: time(30))
        let red = ColorValue(r: 1, g: 0, b: 0)
        let region = BlurRegion(start: time(1), duration: time(2), rect: rect, style: .cover, color: red, cornerRadius: 0.3)
        timeline.blurs = [region]
        let copied = try #require(CopiedRegion(.blur(region.id), in: timeline))
        let placed = try #require(copied.placed(at: time(8), in: timeline))
        guard case .blur(let pasted) = placed else { Issue.record("not a blur"); return }
        #expect(pasted.color == red)
        #expect(pasted.cornerRadius == 0.3)
        #expect(pasted.style == .cover)
        #expect(pasted.id != region.id)
        #expect(placed.title == "Cover", "the undo menu names the kind")
        #expect(copied.summary.contains("cover"))
    }

    @Test func freshenedFootageCarriesTheMasksFields() {
        let region = BlurRegion(start: time(1), duration: time(2), rect: rect, style: .spotlight,
                                dimming: 0.2, softness: 0.07)
        let footage = CopiedFootage(clips: [Clip(sourceStart: .zero, sourceDuration: time(10))],
                                    blurs: [region], sourceDuration: time(30))
        let fresh = footage.freshened()
        #expect(fresh.blurs.count == 1)
        #expect(fresh.blurs[0].id != region.id)
        #expect(fresh.blurs[0].style == .spotlight)
        #expect(fresh.blurs[0].dimming == 0.2)
        #expect(fresh.blurs[0].softness == 0.07)
    }

    // MARK: - Words

    @Test func everyKindHasAShortNameAndASentence() {
        for style in BlurRegion.Style.allCases {
            #expect(!style.title.isEmpty)
            #expect(style.hint.count > 10)
        }
        #expect(BlurRegion.Style.gaussian.title == "Blur")
        #expect(BlurRegion.Style.spotlight.hides == false)
        #expect(BlurRegion.Style.cover.hides)
        #expect(BlurRegion.Style.gaussian.strengthTitle != nil)
        #expect(BlurRegion.Style.spotlight.strengthTitle == nil)
        let region = BlurRegion(start: .zero, duration: time(1), rect: rect, style: .spotlight)
        #expect(region.title == "Spotlight")
    }
}
