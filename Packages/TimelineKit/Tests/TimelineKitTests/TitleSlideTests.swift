import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Title slides: clips with no footage, only words.
struct TitleSlideTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timeline(seconds: Double = 30) -> Timeline {
        Timeline(sourceDuration: time(seconds))
    }

    @Test func aTitleAtTheStartPushesTheWholeTakeAlong() {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(2))]
        let command = Commands.AddTitle(at: .zero)
        #expect(command.apply(to: &timeline))

        #expect(timeline.clips.first?.id == command.clip.id, "the command knows what it made")
        #expect(timeline.clips.first?.isTitle == true)
        #expect(timeline.duration == time(33), "three seconds unless told otherwise")
        #expect(timeline.zooms[0].start == time(3), "the zoom stays on the footage it was placed on")
        #expect(timeline.sourceTime(at: time(3)) == .zero, "the take starts after the title")
    }

    @Test func aTitleAtTheEndAddsToTheEnd() {
        var timeline = timeline()
        #expect(Commands.AddTitle(at: timeline.duration).apply(to: &timeline))
        #expect(timeline.clips.last?.isTitle == true)
        #expect(timeline.clips.count == 2)
        #expect(timeline.duration == time(33))
    }

    @Test func aTitleAtThePlayheadCutsThereAndSitsInTheCut() {
        var timeline = timeline()
        #expect(Commands.AddTitle(at: time(12)).apply(to: &timeline))
        #expect(timeline.clips.count == 3)
        #expect(timeline.clips[1].isTitle)
        #expect(timeline.start(ofClipAt: 1) == time(12))
        #expect(timeline.sourceTime(at: time(15)) == time(12))
    }

    /// A title shows no footage, so nothing measured against the recording can land on it.
    @Test func aTitleReachesNoMomentOfTheRecording() {
        var timeline = timeline()
        _ = Commands.AddTitle(at: .zero).apply(to: &timeline)
        #expect(timeline.timelineTime(atSource: .zero) == time(3))
        #expect(timeline.soundRunsFollowingClips.first?.start == time(3), "silent while it shows")
        #expect(timeline.timelineRanges(ofSource: 0...1) == [CMTimeRange(start: time(3), duration: time(1))])
    }

    /// One card, one entrance: splitting would play the entrance twice.
    @Test func aTitleDoesNotSplit() {
        var timeline = timeline()
        _ = Commands.AddTitle(at: .zero).apply(to: &timeline)
        let before = timeline
        #expect(!ClipSequence.split(&timeline, at: time(1.5)))
        #expect(timeline == before)
    }

    /// And so a range delete reaching less than halfway into one leaves the title whole —
    /// and, the fix underneath it, moves the regions after by what really went.
    @Test func deletingARangeThatReachesIntoATitleLeavesItWhole() {
        var timeline = timeline()
        _ = Commands.AddTitle(at: time(10)).apply(to: &timeline)          // 10…13
        timeline.zooms = [ZoomRegion(start: time(20), duration: time(2))]
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(8), end: time(11.2))))
        #expect(timeline.clips.contains { $0.isTitle && $0.duration == time(3) })
        #expect(timeline.duration == time(31), "two seconds of footage went, the title did not")
        #expect(timeline.zooms[0].start == time(18), "and the zoom moved by the two seconds that went")
    }

    /// More than halfway, and the edge goes to the far side of the title: it goes whole.
    @Test func deletingARangeThatReachesMostOfTheWayThroughATitleTakesIt() {
        var timeline = timeline()
        _ = Commands.AddTitle(at: time(10)).apply(to: &timeline)          // 10…13
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(8), end: time(12.5))))
        #expect(!timeline.clips.contains { $0.isTitle })
        #expect(timeline.duration == time(28))
    }

    @Test func aTitlesLengthIsItsOwn() {
        var timeline = timeline()
        let command = Commands.AddTitle(at: .zero)
        _ = command.apply(to: &timeline)
        #expect(Commands.SetHold(clipID: command.clip.id, to: time(5)).apply(to: &timeline))
        #expect(timeline.clips[0].duration == time(5))
        #expect(timeline.duration == time(35))
    }

    @Test func restylingATitleChangesOnlyItsCard() {
        var timeline = timeline()
        let command = Commands.AddTitle(at: .zero)
        _ = command.apply(to: &timeline)
        let restyle = Commands.RestyleTitle(clipID: command.clip.id, "Title Text") { $0.title = "Getting started" }
        #expect(restyle.apply(to: &timeline))
        #expect(timeline.clips[0].title?.title == "Getting started")
        #expect(timeline.duration == time(33))
        #expect(!restyle.apply(to: &timeline), "the same words again is not an edit")
    }

    @Test func restylingFootageAsATitleIsRefused() {
        var timeline = timeline()
        let before = timeline
        #expect(!Commands.RestyleTitle(clipID: timeline.clips[0].id, "Title Text") { $0.title = "x" }
            .apply(to: &timeline))
        #expect(timeline == before)
    }

    @Test func speedDoesNotTouchATitle() {
        var timeline = timeline()
        _ = Commands.AddTitle(at: .zero).apply(to: &timeline)
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: timeline.duration), speed: 2)
        #expect(timeline.clips[0].duration == time(3))
        #expect(timeline.duration == time(18))
    }

    /// There is nothing trimmed off the front of a title to put back.
    @Test func aTitleFirstOffersNoHeadTrim() {
        var timeline = timeline()
        _ = ClipSequence.trim(&timeline, clipID: timeline.clips[0].id, head: time(4), tail: nil)
        #expect(Selection.headTrim.isValid(in: timeline))
        _ = Commands.AddTitle(at: .zero).apply(to: &timeline)
        #expect(!Selection.headTrim.isValid(in: timeline))
    }

    @Test func aTitleSurvivesCopyPasteAndTheExcerpt() throws {
        var timeline = timeline()
        var card = TitleCard(title: "Chapter 2", subtitle: "Settings", layout: .left)
        card.entrance = .rise
        _ = Commands.AddTitle(card, at: .zero).apply(to: &timeline)
        let copied = try #require(CopiedFootage(.clip(timeline.clips[0].id), in: timeline)).freshened()
        #expect(copied.clips[0].title == card)
        #expect(copied.soundRuns.isEmpty, "a title has no sound to carry")

        let excerpt = timeline.cut(to: CMTimeRange(start: time(1), duration: time(4)))
        #expect(excerpt.clips[0].title == card)
        #expect(excerpt.clips[0].duration == time(2))
    }

    // MARK: - Reading it back

    @Test func aTitleRoundTripsThroughAProject() throws {
        var timeline = timeline()
        _ = Commands.AddTitle(TitleCard(title: "Hello", subtitle: "World", layout: .lowerThird,
                                    backdrop: .panel, entrance: .rise, size: 0.12),
                          at: .zero).apply(to: &timeline)
        let back = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(back == timeline)
    }

    /// A layout a newer build added costs the layout, not the words.
    @Test func anUnknownLayoutFallsBackAlone() throws {
        let json = #"{"title":"Hello","subtitle":"There","layout":"diagonal","size":0.1}"#
        let card = try JSONDecoder().decode(TitleCard.self, from: Data(json.utf8))
        #expect(card.title == "Hello")
        #expect(card.subtitle == "There")
        #expect(card.layout == .centred)
        #expect(card.size == 0.1)
    }

    /// A title written without its length is still a title, for the default length.
    @Test func aTitleWithoutALengthGetsTheDefault() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sourceStart":{"value":0,"timescale":600},
         "sourceDuration":{"value":0,"timescale":600},"speed":1,"title":{"title":"Hi"}}
        """
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(clip.isTitle)
        #expect(clip.duration == Clip.defaultTitleLength)
    }

    @Test func theSizeIsHeldToWhatCanBeDrawn() {
        #expect(TitleCard(size: 4).sanitisedSize == TitleCard.maximumSize)
        #expect(TitleCard(size: -1).sanitisedSize == TitleCard.minimumSize)
        #expect(TitleCard(size: .nan).sanitisedSize == 0.09)
    }

    // MARK: - The entrance

    @Test func aFadeArrivesFromNothingAndSettles() {
        let card = TitleCard(entrance: .fade)
        #expect(card.pose(elapsed: 0).opacity == 0)
        #expect(card.pose(elapsed: TitleCard.entranceLength).opacity == 1)
        #expect(card.pose(elapsed: 10) == (1, 0))
        #expect(card.pose(elapsed: 0.1).drop == 0)
    }

    @Test func aRiseComesUpFromBelow() {
        let card = TitleCard(entrance: .rise)
        #expect(card.pose(elapsed: 0).drop > 0)
        #expect(card.pose(elapsed: 0.3).drop < card.pose(elapsed: 0.1).drop)
        #expect(card.pose(elapsed: TitleCard.entranceLength).drop == 0)
    }

    @Test func noEntranceIsThereFromTheFirstFrame() {
        #expect(TitleCard(entrance: .none).pose(elapsed: 0) == (1, 0))
    }
}
