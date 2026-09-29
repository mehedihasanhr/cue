import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

private func milliseconds(_ value: CMTime) -> Int {
    Int((value.seconds * 1_000).rounded())
}

/// A cue with the recogniser's timings, words given as (text, from, to) in seconds on the
/// timeline.
private func spoken(_ words: [(String, Double, Double)]) -> CaptionCue {
    let start = words[0].1, end = words[words.count - 1].2
    let length = end - start
    return CaptionCue(start: time(start), duration: time(end) - time(start),
                      text: words.map(\.0).joined(separator: " "),
                      words: words.map { CaptionCue.Word(text: $0.0, from: ($0.1 - start) / length, to: ($0.2 - start) / length) })
}

@Suite("Cutting words out by the transcript")
struct TranscriptWordCutTests {
    private let line = spoken([("so", 2, 2.4), ("um", 2.6, 3.0), ("this", 3.2, 3.5), ("works", 3.6, 4.0)])

    private func timeline(_ cues: CaptionCue...) -> Timeline {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.captions = cues
        return timeline
    }

    private func word(_ index: Int, of cue: CaptionCue) -> TranscriptEditing.WordID {
        TranscriptEditing.WordID(cue: cue.id, index: index)
    }

    @Test("One word is cut with a few milliseconds either side")
    func padded() throws {
        let cuts = TranscriptEditing.wordCutRanges([word(1, of: line)], in: timeline(line))
        let cut = try #require(cuts.first)
        #expect(cuts.count == 1)
        #expect(milliseconds(cut.start) == 2_570)
        #expect(milliseconds(cut.end) == 3_030)
    }

    @Test("Words next to each other are one cut, the silence between them included")
    func adjacentMerge() throws {
        let cuts = TranscriptEditing.wordCutRanges([word(1, of: line), word(2, of: line)], in: timeline(line))
        let cut = try #require(cuts.first)
        #expect(cuts.count == 1, "\"um this\" is one stretch, not two with a crumb of pause between")
        #expect(milliseconds(cut.start) == 2_570)
        #expect(milliseconds(cut.end) == 3_530)
    }

    @Test("Words apart from each other are separate cuts, and the word between them stays whole")
    func apart() {
        let cuts = TranscriptEditing.wordCutRanges([word(0, of: line), word(2, of: line)], in: timeline(line))
        #expect(cuts.count == 2)
        #expect(cuts.allSatisfy { $0.end <= time(2.6) || $0.start >= time(3.0) }, "\"um\" is never touched")
    }

    @Test("A cut never reaches into a word that stays, however close it is")
    func neighboursBound() throws {
        // Ten milliseconds of silence either side of "um": less than the padding.
        let tight = spoken([("so", 2, 2.59), ("um", 2.6, 3.0), ("this", 3.01, 3.4)])
        let cut = try #require(TranscriptEditing.wordCutRanges([word(1, of: tight)], in: timeline(tight)).first)
        #expect(milliseconds(cut.start) == 2_590, "stops at the end of \"so\"")
        #expect(milliseconds(cut.end) == 3_010, "and at the start of \"this\"")
    }

    @Test("Where the recogniser's words overlap, the one that stays keeps all of its sound")
    func overlappingNeighbour() throws {
        let overlapping = spoken([("so", 2, 2.7), ("um", 2.6, 3.0), ("this", 3.2, 3.5)])
        let cut = try #require(TranscriptEditing.wordCutRanges([word(1, of: overlapping)], in: timeline(overlapping)).first)
        #expect(milliseconds(cut.start) == 2_700)
        #expect(milliseconds(cut.end) == 3_030)
    }

    @Test("Across two lines, words heard one after the other are still one cut")
    func acrossLines() throws {
        let first = spoken([("hello", 1, 1.5), ("there", 1.6, 2.0)])
        let second = spoken([("and", 2.2, 2.4), ("welcome", 2.5, 3.0)])
        let cuts = TranscriptEditing.wordCutRanges([word(1, of: first), word(0, of: second)],
                                                   in: timeline(first, second))
        let cut = try #require(cuts.first)
        #expect(cuts.count == 1)
        #expect(milliseconds(cut.start) == 1_570)
        #expect(milliseconds(cut.end) == 2_430)
    }

    @Test("The first and last words are held inside the edit")
    func edges() throws {
        let opening = spoken([("hi", 0.01, 0.3), ("there", 0.4, 0.8)])
        let start = try #require(TranscriptEditing.wordCutRanges([word(0, of: opening)], in: timeline(opening)).first)
        #expect(start.start == .zero)

        var short = Timeline(sourceDuration: time(5))
        let closing = spoken([("bye", 4.5, 4.99)])
        short.captions = [closing]
        let end = try #require(TranscriptEditing.wordCutRanges([word(0, of: closing)], in: short).first)
        #expect(end.end == short.duration)
    }

    @Test("A line whose timings are a guess cannot be cut by its words")
    func guessedNeverCut() {
        var edited = line
        edited.text = "so um this really works"
        #expect(TranscriptEditing.wordCutRanges([word(1, of: edited)], in: timeline(edited)).isEmpty)
        let typed = CaptionCue(start: time(5), duration: time(2), text: "typed by hand")
        #expect(TranscriptEditing.wordCutRanges([word(0, of: typed)], in: timeline(typed)).isEmpty)
        #expect(Commands.cutWords([word(0, of: typed)], in: timeline(typed)) == nil)
    }

    @Test("Cutting the words is one edit that takes them, and only them, out of the line")
    func command() throws {
        var edit = timeline(line)
        let command = try #require(Commands.cutWords([word(1, of: line)], in: edit))
        #expect(command.name == "Cut Word")
        #expect(command.apply(to: &edit))
        #expect(edit.captions.map(\.text) == ["so this works"])
        #expect(abs(edit.duration.seconds - (30 - 0.46)) < 0.001)
        let words = TranscriptEditing.spokenWords(in: edit)
        #expect(words.map(\.text) == ["so", "this", "works"])
        #expect(milliseconds(words[0].range.end) == 2_400, "the word before keeps its end")
        #expect(milliseconds(words[1].range.start) == 2_740, "and the one after lands 0.46 s earlier")
    }

    @Test("Words are numbered within their line, so a picked word is that word and no other")
    func identities() {
        let words = TranscriptEditing.spokenWords(in: timeline(line))
        #expect(words.map(\.index) == [0, 1, 2, 3])
        #expect(Set(words.map(\.id)).count == 4)
    }

    @Test("The word under the playhead is the one being said, and nothing between words")
    func wordAtTime() {
        let words = TranscriptEditing.spokenWords(in: timeline(line))
        #expect(TranscriptEditing.word(at: time(2.7), among: words)?.text == "um")
        #expect(TranscriptEditing.word(at: time(2.5), among: words) == nil)
        #expect(TranscriptEditing.word(at: time(3.6), among: words)?.text == "works")
    }
}
