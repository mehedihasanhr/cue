import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Chapters from markers and title slides, and YouTube's rules for them.
struct ChapterTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timeline(seconds: Double = 120) -> Timeline {
        Timeline(sourceDuration: time(seconds))
    }

    @Test func markersBecomeChaptersAfterAnIntroAtTheStart() {
        let chapters = Chapters.list(for: timeline(), markers: [time(30), time(75.6)])
        #expect(Chapters.text(chapters) == "0:00 Intro\n0:30 Chapter 2\n1:15 Chapter 3")
        #expect(Chapters.youTubeProblem(chapters, duration: time(120)) == nil)
    }

    /// A marker names its chapter with what is said just after it.
    @Test func aMarkerIsNamedByTheCaptionSaidThere() {
        var timeline = timeline()
        timeline.captions = [
            CaptionCue(start: time(31), duration: time(3), text: "Now let's set up\nthe  project"),
            CaptionCue(start: time(90), duration: time(3), text: "Too far after the marker"),
        ]
        let chapters = Chapters.list(for: timeline, markers: [time(30), time(80)])
        #expect(chapters.map(\.title) == ["Intro", "Now let's set up the project", "Chapter 3"])
    }

    @Test func aTitleSlideNamesItsChapterAndOneAtTheStartIsTheFirst() {
        var timeline = timeline()
        _ = Commands.AddTitle(TitleCard(title: "Welcome"), at: .zero).apply(to: &timeline)
        _ = Commands.AddTitle(TitleCard(title: "", subtitle: "Part two"), at: time(63)).apply(to: &timeline)
        let chapters = Chapters.list(for: timeline, markers: [time(33)])
        #expect(chapters.map(\.title) == ["Welcome", "Chapter 2", "Part two"])
        #expect(chapters.map { Int($0.time.seconds) } == [0, 33, 63])
    }

    /// A marker on a title slide's first frame is one chapter, called what the slide says.
    @Test func aMarkerOnATitleSlideIsTheSameChapter() {
        var timeline = timeline()
        _ = Commands.AddTitle(TitleCard(title: "Setup"), at: time(40)).apply(to: &timeline)
        let chapters = Chapters.list(for: timeline, markers: [time(40.2)])
        #expect(chapters.map(\.title) == ["Intro", "Setup"])
    }

    @Test func somethingWithinASecondOfTheStartIsTheFirstChapter() {
        let chapters = Chapters.list(for: timeline(), markers: [time(0.6), time(40)])
        #expect(chapters.map { Int($0.time.seconds) } == [0, 40])
        #expect(chapters[0].title == "Chapter 1" || chapters[0].title == "Intro")
    }

    @Test func aMarkerInFootageThatWasCutIsNoChapter() {
        var timeline = timeline()
        ClipSequence.delete(&timeline, range: CMTimeRange(start: time(20), duration: time(20)))
        let markers = RecordedMarkers.times(of: [MarkerSample(t: 30), MarkerSample(t: 60)], in: timeline)
        let chapters = Chapters.list(for: timeline, markers: markers)
        #expect(chapters.map { Int($0.time.seconds) } == [0, 40])
    }

    // MARK: - YouTube's rules

    @Test func fewerThanThreeIsExplained() throws {
        let one = Chapters.list(for: timeline(), markers: [])
        #expect(Chapters.youTubeProblem(one, duration: time(120)) == .tooFew(1))
        let two = Chapters.list(for: timeline(), markers: [time(50)])
        let problem = try #require(Chapters.youTubeProblem(two, duration: time(120)))
        #expect(problem == .tooFew(2))
        #expect(problem.reason.contains("at least three"))
        #expect(problem.reason.contains("has 2"))
    }

    @Test func aChapterShorterThanTenSecondsIsNamedInTheReason() throws {
        let chapters = Chapters.list(for: timeline(), markers: [time(30), time(36)])
        let problem = try #require(Chapters.youTubeProblem(chapters, duration: time(120)))
        #expect(problem == .tooShort(title: "Chapter 2", at: 30, seconds: 6))
        #expect(problem.reason.contains("“Chapter 2” at 0:30 lasts 6 seconds"))
    }

    /// The last chapter runs to the end of the video, and has to last ten seconds too.
    @Test func theLastChapterCountsUpToTheEnd() {
        let chapters = Chapters.list(for: timeline(), markers: [time(40), time(115)])
        #expect(Chapters.youTubeProblem(chapters, duration: time(120)) == .tooShort(title: "Chapter 3", at: 115, seconds: 5))
    }

    /// Whole seconds, as the description writes them: 9.9 seconds apart is written nine.
    @Test func lengthsAreCountedAsTheTimestampsSayThem() {
        let chapters = [Chapter(time: .zero, title: "A"), Chapter(time: time(20.9), title: "B"),
                        Chapter(time: time(30.2), title: "C")]
        #expect(Chapters.youTubeProblem(chapters, duration: time(60)) == nil)
        let tight = [Chapter(time: .zero, title: "A"), Chapter(time: time(20.9), title: "B"),
                     Chapter(time: time(29.95), title: "C")]
        #expect(Chapters.youTubeProblem(tight, duration: time(60)) == .tooShort(title: "B", at: 20, seconds: 9))
    }

    @Test func theFirstChapterMustBeAtZero() {
        let chapters = [Chapter(time: time(5), title: "A"), Chapter(time: time(20), title: "B"),
                        Chapter(time: time(40), title: "C")]
        #expect(Chapters.youTubeProblem(chapters, duration: time(60)) == .firstNotAtStart)
    }

    // MARK: - Words

    @Test(arguments: [(0, "0:00"), (83, "1:23"), (725, "12:05"), (3_723, "1:02:03")])
    func timestampsAreWrittenAsYouTubeReadsThem(seconds: Int, stamp: String) {
        #expect(Chapters.stamp(seconds) == stamp)
    }

    @Test func aListThatRunsPastAnHourWritesHoursOnEveryLine() {
        let chapters = [Chapter(time: .zero, title: "Intro"), Chapter(time: time(3_700), title: "Late")]
        #expect(Chapters.text(chapters) == "0:00:00 Intro\n1:01:40 Late")
    }

    @Test func aLongCaptionIsCutAtAWord() {
        let long = String(repeating: "word ", count: 30)
        let title = Chapters.oneLine(long)
        #expect(title.count <= Chapters.longestTitle + 1)
        #expect(title.hasSuffix("word…"))
    }
}
