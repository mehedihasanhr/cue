import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

/// A cue with the recogniser's timings, words given as (text, from, to) in seconds on the
/// timeline.
private func spoken(_ words: [(String, Double, Double)], from start: Double? = nil, to end: Double? = nil) -> CaptionCue {
    let start = start ?? words[0].1, end = end ?? words[words.count - 1].2
    let length = end - start
    return CaptionCue(start: t(start), duration: t(end) - t(start),
                      text: words.map(\.0).joined(separator: " "),
                      words: words.map { CaptionCue.Word(text: $0.0, from: ($0.1 - start) / length, to: ($0.2 - start) / length) })
}

@Suite("Bug hunt 2026-09-30")
struct BugHuntTests {
    @Test("A caption added over the end of a spoken line leaves that line's words where they are heard")
    func addCaptionKeepsWordTimes() throws {
        var timeline = Timeline(sourceDuration: t(30))
        let line = spoken([("so", 1, 1.5), ("this", 2, 2.5), ("um", 3, 3.5)], from: 1, to: 5)
        timeline.captions = [line]
        #expect(Commands.AddCaption(CaptionCue(start: t(4), duration: t(2), text: "typed")).apply(to: &timeline))
        let words = TranscriptEditing.spokenWords(in: timeline)
        let um = try #require(words.first { $0.text == "um" })
        #expect(abs(um.range.start.seconds - 3) < 0.01)
        #expect(abs(um.range.end.seconds - 3.5) < 0.01)
    }

    @Test("Merging a caption with one that sits inside it keeps the whole of the first")
    func mergeKeepsTheLongerEnd() throws {
        var timeline = Timeline(sourceDuration: t(30))
        let first = CaptionCue(start: t(1), duration: t(5), text: "first")
        let second = CaptionCue(start: t(2), duration: t(1), text: "second")
        timeline.captions = [first, second]
        #expect(Commands.MergeCaptions(id: first.id).apply(to: &timeline))
        let merged = try #require(timeline.captions.first)
        #expect(merged.end == t(6))
    }

    @Test("Speed Up Waiting never offers a title slide or a freeze frame")
    func paceLeavesHoldsAlone() {
        var timeline = Timeline(sourceDuration: t(20))
        _ = ClipSequence.insert(&timeline, clip: .title(TitleCard(), for: t(4)), at: t(10))
        // Pointer busy over all of the recording's footage; only the title is still.
        let found = PaceSuggester.suggestions(timeline: timeline, pointer: [0...20], screen: [],
                                              typing: [], speech: [])
        #expect(found.isEmpty)
    }

    @Test("A line of caption text with an arrow in it stays in the caption")
    func arrowInText() throws {
        let file = """
        1
        00:00:01,000 --> 00:00:03,000
        Open File --> Export
        and choose a size

        2
        00:00:04,000 --> 00:00:05,000
        Done
        """
        let parsed = try SubtitleImport.parse(file)
        #expect(parsed.skipped == 0)
        #expect(parsed.cues.map(\.text) == ["Open File --> Export\nand choose a size", "Done"])
    }

    @Test("Something found in the recording is never masked over an added movie")
    func sensitiveSkipsImportedClips() {
        var timeline = Timeline(sourceDuration: t(20))
        let movie = MediaFile(path: "Movies/intro.mov", name: "intro.mov", duration: t(10),
                              pixelSize: CGSize(width: 1920, height: 1080), hasSound: false)
        #expect(Commands.AddMedia(movie, at: .zero).apply(to: &timeline))
        #expect(ClipSequence.freeze(&timeline, at: t(3)))
        // The recording now starts at 12 s; its 2–4 s is at 14–16 s.
        let pieces = timeline.pieces(ofSource: 2...4)
        #expect(pieces.count == 1)
        #expect(abs((pieces.first?.range.start.seconds ?? 0) - 14) < 0.01)
    }

    /// Two spoken lines with a title slide put in between them, at 10 s for 3 s.
    private func linesAroundATitle() -> (Timeline, CaptionCue, CaptionCue) {
        var timeline = Timeline(sourceDuration: t(30))
        let before = spoken([("first", 9, 9.5), ("part", 9.6, 9.9)])
        let after = spoken([("second", 10.2, 10.6), ("part", 10.7, 11)])
        timeline.captions = [before, after]
        _ = ClipSequence.insert(&timeline, clip: .title(TitleCard(), for: t(3)), at: t(10))
        return (timeline, before, after)
    }

    @Test("Shortening pauses never cuts into a title slide between two lines")
    func pausesLeaveTitlesAlone() throws {
        let (timeline, _, _) = linesAroundATitle()
        #expect(timeline.captions.map(\.start.seconds).map { ($0 * 10).rounded() / 10 } == [9, 13.2])
        let cuts = TranscriptEditing.pauseRanges(in: timeline, longerThan: 1, keeping: 0.4)
        #expect(cuts.isEmpty)
    }

    @Test("Cutting the words either side of a title slide leaves the slide")
    func wordCutsLeaveTitlesAlone() throws {
        let (timeline, before, after) = linesAroundATitle()
        let chosen: Set<TranscriptEditing.WordID> = [.init(cue: before.id, index: 1), .init(cue: after.id, index: 0)]
        let cuts = TranscriptEditing.wordCutRanges(chosen, in: timeline)
        let title = CMTimeRange(start: t(10), duration: t(3))
        #expect(!cuts.isEmpty)
        #expect(cuts.allSatisfy { $0.intersection(title).duration < CMTime(value: 1, timescale: 1_000) })
    }
}
