import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

private func range(_ from: Double, _ to: Double) -> CMTimeRange {
    CMTimeRange(start: time(from), end: time(to))
}

private func seconds(_ value: CMTime) -> Double {
    (value.seconds * 1_000).rounded() / 1_000
}

/// A cue with the recogniser's timings: words given as (text, from, to) in seconds on the
/// timeline, the cue running from the first word to the last.
private func spoken(_ words: [(String, Double, Double)]) -> CaptionCue {
    let start = words.first!.1, end = words.last!.2
    let length = end - start
    return CaptionCue(start: time(start), duration: time(end) - time(start),
                      text: words.map(\.0).joined(separator: " "),
                      words: words.map { CaptionCue.Word(text: $0.0, from: ($0.1 - start) / length, to: ($0.2 - start) / length) })
}

@Suite("Cutting a stretch out of the timeline")
struct CutRegionTests {
    @Test("Something that began inside the cut begins where the cut now is")
    func beganInside() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.zooms = [ZoomRegion(start: time(6), duration: time(4))]
        #expect(ClipSequence.delete(&timeline, range: range(5, 7)))
        #expect(seconds(timeline.zooms[0].start) == 5)
        #expect(seconds(timeline.zooms[0].end) == 8, "the three seconds after the cut are kept")
    }

    @Test("A sound whose front was cut plays on from where the cut ends")
    func soundFront() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.audio = [AudioRegion(start: time(6), duration: time(4), path: "Audio/a.m4a", sourceStart: time(1))]
        #expect(ClipSequence.delete(&timeline, range: range(5, 7)))
        #expect(seconds(timeline.audio[0].start) == 5)
        #expect(seconds(timeline.audio[0].sourceStart) == 2, "one second of it was cut")
        #expect(seconds(timeline.audio[0].duration) == 3)
    }

    @Test("A detached run's front is cut at its own speed")
    func detachedRun() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.detachedSound = [SoundRun(start: time(6), duration: time(4), sourceStart: time(10), speed: 2)]
        #expect(ClipSequence.delete(&timeline, range: range(5, 7)))
        let run = timeline.detachedSound![0]
        #expect(seconds(run.start) == 5)
        #expect(seconds(run.sourceStart) == 12, "a second of timeline is two of recording at double speed")
    }

    @Test("Something that ends inside the cut keeps its start")
    func endedInside() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.blurs = [BlurRegion(start: time(3), duration: time(3), rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))]
        #expect(ClipSequence.delete(&timeline, range: range(5, 7)))
        #expect(seconds(timeline.blurs[0].start) == 3)
        #expect(seconds(timeline.blurs[0].end) == 5)
    }
}

@Suite("Cutting through a caption")
struct CaptionCutTests {
    private let line = spoken([("so", 2, 2.4), ("um", 2.6, 3.0), ("this", 3.2, 3.5), ("works", 3.6, 4.0)])

    @Test("The words said in the cut go with it, and the rest keep their moments")
    func wordsInside() throws {
        let cut = try #require(line.cut(range(2.5, 3.1)))
        #expect(cut.text == "so this works")
        let words = TranscriptEditing.spokenWords(in: {
            var timeline = Timeline(sourceDuration: time(30))
            timeline.captions = [cut]
            return timeline
        }())
        #expect(words.map(\.text) == ["so", "this", "works"])
        #expect(seconds(words[1].range.start) == 2.6, "\"this\" was at 3.2, and 0.6 s before it was cut")
        #expect(seconds(words[2].range.end) == 3.4)
    }

    @Test("Cut before it, it moves; cut after it, it is left alone")
    func outside() {
        #expect(seconds(line.cut(range(0, 1))!.start) == 1)
        #expect(line.cut(range(10, 12)) == line)
    }

    @Test("Cut all of it, it is gone")
    func whole() {
        #expect(line.cut(range(1, 5)) == nil)
    }

    @Test("A line typed by hand keeps its words")
    func typed() throws {
        let typed = CaptionCue(start: time(2), duration: time(2), text: "Open the menu")
        let cut = try #require(typed.cut(range(3, 3.5)))
        #expect(cut.text == "Open the menu")
        #expect(seconds(cut.duration) == 1.5)
    }
}

@Suite("Finding what to cut in the transcript")
struct TranscriptFindingTests {
    private func timeline(_ cues: CaptionCue...) -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.captions = cues
        return timeline
    }

    @Test("Fillers are found whatever their case or punctuation, and only real ones")
    func fillers() {
        let edit = timeline(spoken([("Um,", 1, 1.3), ("like", 1.4, 1.6), ("this", 1.7, 2.0), ("uh...", 2.1, 2.4), ("works", 2.5, 3.0)]))
        let ranges = TranscriptEditing.fillerRanges(in: edit)
        #expect(ranges.map { seconds($0.start) } == [1, 2.1])
    }

    @Test("Guessed timings are never cut")
    func guessed() {
        var cue = spoken([("um", 1, 1.3), ("hello", 1.4, 2.0)])
        cue.text = "um hello there"          // edited, so the timings are a guess now
        #expect(TranscriptEditing.fillerRanges(in: timeline(cue)).isEmpty)
    }

    @Test("A long pause is cut down to what is kept, from its middle")
    func pauses() {
        let edit = timeline(spoken([("first", 1, 2)]), spoken([("second", 6, 7)]), spoken([("third", 7.5, 8)]))
        let cuts = TranscriptEditing.pauseRanges(in: edit, longerThan: 1, keeping: 0.5)
        #expect(cuts.count == 1)
        #expect(seconds(cuts[0].start) == 2.25)
        #expect(seconds(cuts[0].end) == 5.75)
    }

    @Test("A pause in which the pointer is busy is left alone")
    func busyPause() {
        let edit = timeline(spoken([("first", 1, 2)]), spoken([("second", 6, 7)]))
        #expect(TranscriptEditing.pauseRanges(in: edit, longerThan: 1, keeping: 0.5, busy: [range(3, 4)]).isEmpty)
        #expect(TranscriptEditing.pauseRanges(in: edit, longerThan: 1, keeping: 0.5, busy: [range(10, 11)]).count == 1)
    }

    @Test("Where a stretch of the recording is on the timeline, through cuts and speed")
    func sourceToTimeline() {
        var edit = Timeline(sourceDuration: time(60))
        edit.clips = [Clip(sourceStart: .zero, sourceDuration: time(10)),
                      Clip(sourceStart: time(20), sourceDuration: time(20), speed: 2)]
        let ranges = edit.timelineRanges(ofSource: 8...24)
        #expect(ranges.count == 2)
        #expect(seconds(ranges[0].start) == 8 && seconds(ranges[0].end) == 10)
        #expect(seconds(ranges[1].start) == 10 && seconds(ranges[1].end) == 12)
    }
}

@Suite("Cutting several stretches as one edit")
struct DeleteRangesTests {
    @Test("Each is cut where it was measured, and the edit is that much shorter")
    func several() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.captions = [spoken([("so", 2, 2.4), ("um", 2.6, 3.0), ("this", 3.2, 3.5)]),
                             spoken([("uh", 10, 10.5), ("works", 10.6, 11)])]
        let cuts = TranscriptEditing.fillerRanges(in: timeline)
        #expect(Commands.DeleteRanges(cuts, name: "Remove Filler Words").apply(to: &timeline))
        #expect(abs(timeline.duration.seconds - 29.1) < 0.001)
        #expect(timeline.captions.map(\.text) == ["so this", "works"])
        #expect(TranscriptEditing.fillerRanges(in: timeline).isEmpty)
        let words = TranscriptEditing.spokenWords(in: timeline)
        #expect(seconds(words.last!.range.start) == 9.7, "\"works\" was at 10.6; 0.4 s and 0.5 s were cut before it")
    }

    @Test("Nothing to cut is no edit")
    func nothing() {
        var timeline = Timeline(sourceDuration: time(30))
        #expect(!Commands.DeleteRanges([], name: "Cut").apply(to: &timeline))
    }

    @Test("Overlapping stretches are cut once")
    func overlapping() {
        var timeline = Timeline(sourceDuration: time(30))
        #expect(Commands.DeleteRanges([range(2, 4), range(3, 5)], name: "Cut").apply(to: &timeline))
        #expect(abs(timeline.duration.seconds - 27) < 0.001)
    }
}
