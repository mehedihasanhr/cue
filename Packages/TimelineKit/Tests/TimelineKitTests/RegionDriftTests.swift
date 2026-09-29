import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Regions, sound and caption words sliding off their footage during ordinary edits.
///
/// Each of these is a case a reviewer reproduced against the code before it was fixed,
/// kept here in the numbers they were found with.
struct RegionDriftTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func close(_ a: CMTime?, _ b: CMTime, within tolerance: Double = 0.005) -> Bool {
        guard let a else { return false }
        return abs((a - b).seconds) < tolerance
    }

    /// Clips 0–10, 10–20, 20–40 of a 40-second take.
    private func threeClips() -> Timeline {
        var timeline = Timeline(sourceDuration: time(40))
        ClipSequence.split(&timeline, at: time(10))
        ClipSequence.split(&timeline, at: time(20))
        return timeline
    }

    /// Where a word of a cue is said, on the timeline.
    private func heard(_ word: String, in cue: CaptionCue) -> (from: CMTime, to: CMTime)? {
        guard let found = cue.words.first(where: { $0.text == word }) else { return nil }
        let seconds = cue.duration.seconds
        return (cue.start + CMTime(seconds: found.from * seconds, preferredTimescale: 60_000),
                cue.start + CMTime(seconds: found.to * seconds, preferredTimescale: 60_000))
    }

    /// "a b um d" over 8–12 s, with "um" said at 10.0–10.5.
    private func line(start: Double = 8) -> CaptionCue {
        CaptionCue(start: time(start), duration: time(4), text: "a b um d",
                   words: [.init(text: "a", from: 0, to: 0.2),
                           .init(text: "b", from: 0.2, to: 0.4),
                           .init(text: "um", from: 0.5, to: 0.625),
                           .init(text: "d", from: 0.75, to: 1)])
    }

    // MARK: - 1. An edge that could not be cut

    @Test func aDeleteStartingASliverPastACutTakesTheWholeClipAndMovesRegionsByThat() {
        var timeline = threeClips()
        timeline.zooms = [ZoomRegion(start: time(32), duration: time(2))]
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(10.05), end: time(25))))
        #expect(timeline.duration == time(25), "10–25 went: the edge went to the cut beside it")
        #expect(timeline.sourceTime(at: timeline.zooms[0].start) == time(32))
    }

    @Test func aSpeedChangeStartingASliverPastACutRetimesTheWholeClip() {
        var timeline = threeClips()
        timeline.zooms = [ZoomRegion(start: time(35), duration: time(2))]
        #expect(ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(10.05), end: time(30)), speed: 4))
        #expect(timeline.clips[1].speed == 4, "the clip across the edge is part of it")
        #expect(timeline.duration == time(25))
        #expect(close(timeline.sourceTime(at: timeline.zooms[0].start), time(35)))
    }

    /// Two filler words a twentieth of a second apart: the second delete used to do nothing.
    @Test func aSecondDeleteJustAfterAFirstStillDeletes() {
        var timeline = Timeline(sourceDuration: time(30))
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(5), end: time(5.3))))
        let after = timeline.duration
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(5.05), end: time(5.3))))
        #expect(timeline.duration < after)
    }

    // MARK: - 2. One speed over clips at different speeds

    @Test func settingOneSpeedOverMixedSpeedsKeepsRegionsAndSoundOnTheirFootage() throws {
        var timeline = Timeline(sourceDuration: time(15))
        ClipSequence.split(&timeline, at: time(10))
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(10)), speed: 2)
        // Now 0–5 at 2× (source 0–10), 5–10 at 1× (source 10–15).
        ClipSequence.detachSound(&timeline)
        timeline.zooms = [ZoomRegion(start: time(7), duration: time(1))]    // source 12

        #expect(ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(10)), speed: 2))
        #expect(close(timeline.sourceTime(at: timeline.zooms[0].start), time(12)))
        let runs = try #require(timeline.detachedSound)
        #expect(runs.map(\.speed) == [2, 2], "each run plays at its picture's speed exactly")
        for run in runs {
            #expect(close(timeline.sourceTime(at: run.start), run.sourceStart))
        }
        #expect(timeline.detachedSoundIsInStepWithClips)
    }

    // MARK: - 3. Trimming a tail

    @Test func trimmingAClipsTailTakesWhatWasOnTheFootageItCutOff() {
        var timeline = Timeline(sourceDuration: time(20))
        ClipSequence.split(&timeline, at: time(10))
        timeline.zooms = [ZoomRegion(start: time(8.5), duration: time(1)),
                          ZoomRegion(start: time(15), duration: time(1))]
        #expect(ClipSequence.trim(&timeline, clipID: timeline.clips[0].id, head: nil, tail: time(8)))
        #expect(timeline.zooms.count == 1, "the zoom on 8.5–9.5 went with the footage")
        #expect(timeline.sourceTime(at: timeline.zooms[0].start) == time(15))
    }

    // MARK: - 6. Caption words through a speed change and an insertion

    @Test func aLineAcrossASpeedChangeKeepsEachWordOnItsMoment() throws {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.captions = [line()]
        #expect(ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(10), end: time(20)), speed: 2))
        let cue = timeline.captions[0]
        #expect(cue.start == time(8))
        #expect(close(cue.end, time(11)))
        let um = try #require(heard("um", in: cue))
        #expect(close(um.from, time(10)), "said at the start of the sped-up stretch")
        #expect(close(um.to, time(10.25)), "and for half as long")
        let b = try #require(heard("b", in: cue))
        #expect(close(b.from, time(8.8)), "the words before the change do not move")
    }

    @Test func footagePastedIntoALinePushesTheWordsAfterIt() throws {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.captions = [line()]
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(20), duration: time(2)), in: timeline))
        #expect(ClipSequence.insert(&timeline, footage, at: time(9.7)))
        let cue = timeline.captions[0]
        #expect(close(cue.end, time(14)))
        #expect(close(heard("um", in: cue)?.from, time(12)), "said after the pasted footage")
        #expect(close(heard("b", in: cue)?.from, time(8.8)), "and the words before it stay")
    }

    // MARK: - 10. Dragging a caption's edge

    @Test func trimmingALinesEndDropsTheWordsItLeftOutside() throws {
        var timeline = Timeline(sourceDuration: time(30))
        var cue = line(start: 0)                                           // "um" at 2.0–2.5
        cue.duration = time(5)                                             // "um" at 2.5–3.125
        timeline.captions = [cue]
        #expect(Commands.MoveRegion(id: cue.id, start: .zero, duration: time(2.5)).apply(to: &timeline))
        let trimmed = timeline.captions[0]
        #expect(trimmed.text == "a b", "the words said after 2.5 s are not in the line any more")
        #expect(close(heard("b", in: trimmed)?.from, time(1)), "and the ones left are where they were")
    }

    @Test func trimmingALinesEndKeepsTheWordsItStillCovers() throws {
        var timeline = Timeline(sourceDuration: time(30))
        var cue = line(start: 0)
        cue.duration = time(5)                                             // "um" at 2.5–3.125
        timeline.captions = [cue]
        #expect(Commands.MoveRegion(id: cue.id, start: .zero, duration: time(4)).apply(to: &timeline))
        let trimmed = timeline.captions[0]
        #expect(trimmed.text == "a b um")
        #expect(close(heard("um", in: trimmed)?.from, time(2.5)), "not squeezed towards the start")
    }

    @Test func trimmingALinesStartKeepsTheRestWhereTheyAre() throws {
        var timeline = Timeline(sourceDuration: time(30))
        let cue = line()                                                   // 8–12
        timeline.captions = [cue]
        #expect(Commands.MoveRegion(id: cue.id, start: time(9.7), duration: time(2.3)).apply(to: &timeline))
        let trimmed = timeline.captions[0]
        #expect(trimmed.text == "um d")
        #expect(close(heard("um", in: trimmed)?.from, time(10)))
    }

    @Test func movingALineCarriesItsWords() throws {
        var timeline = Timeline(sourceDuration: time(30))
        let cue = line()
        timeline.captions = [cue]
        #expect(Commands.MoveRegion(id: cue.id, start: time(15)).apply(to: &timeline))
        let moved = timeline.captions[0]
        #expect(moved.words == cue.words)
        #expect(close(heard("um", in: moved)?.from, time(17)))
    }

    // MARK: - The end of the edit

    @Test func aLineRunningPastTheEndLosesTheWordsSaidThere() throws {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.captions = [line()]                                       // 8–12
        #expect(ClipSequence.trim(&timeline, clipID: timeline.clips[0].id, head: nil, tail: time(10.2),
                                  movesRegions: false))
        let cue = timeline.captions[0]
        #expect(cue.text == "a b")
        #expect(close(heard("b", in: cue)?.from, time(8.8)))
    }
}
