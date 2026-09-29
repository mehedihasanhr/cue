import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Reading subtitle files, including the ones real tools write.
struct SubtitleImportTests {
    private func parse(_ text: String) throws -> [SubtitleImport.Cue] {
        try SubtitleImport.parse(text).cues
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_5 }

    // MARK: - SubRip

    @Test func aTidySubRipFileIsReadCueByCue() throws {
        let cues = try parse("""
        1
        00:00:01,000 --> 00:00:02,500
        Hello there.

        2
        00:00:03,000 --> 00:00:05,250
        Two lines
        of words.

        """)
        #expect(cues == [SubtitleImport.Cue(start: 1, end: 2.5, text: "Hello there."),
                         SubtitleImport.Cue(start: 3, end: 5.25, text: "Two lines\nof words.")])
    }

    /// A byte-order mark, Windows line endings, no numbers, no blank line at the end.
    @Test func aByteOrderMarkCarriageReturnsAndMissingNumbersAreForgiven() throws {
        let text = "\u{FEFF}00:00:01,000 --> 00:00:02,000\r\nFirst\r\n\r\n00:00:02,000 --> 00:00:03,000\r\nSecond"
        let cues = try parse(text)
        #expect(cues.map(\.text) == ["First", "Second"])
        #expect(close(cues[1].end, 3))
    }

    @Test func oldMacLineEndingsAreLineEndingsToo() throws {
        let cues = try parse("1\r00:00:01,000 --> 00:00:02,000\rOne\r\r2\r00:00:04,000 --> 00:00:05,000\rTwo\r")
        #expect(cues.map(\.text) == ["One", "Two"])
    }

    /// No blank line before the next number: the number is the next cue's, not the words
    /// of this one.
    @Test func aNumberRunIntoTheCueBeforeIsNotReadAsItsWords() throws {
        let cues = try parse("""
        1
        00:00:01,000 --> 00:00:02,000
        One
        2
        00:00:03,000 --> 00:00:04,000
        Two
        """)
        #expect(cues.map(\.text) == ["One", "Two"])
    }

    @Test func markupAndPlacementCodesAreTakenOutAndEntitiesPutBack() throws {
        let cues = try parse("""
        1
        00:00:01,000 --> 00:00:02,000
        {\\an8}<i>Quiet</i> <font color="#ff0000">please</font> &amp; thanks &lt;3 &#233;t&#xE9;
        """)
        #expect(cues.first?.text == "Quiet please & thanks <3 été")
    }

    /// A lone `<` is somebody's words.
    @Test func aLessThanSignThatIsNotATagStays() throws {
        let cues = try parse("00:00:01,000 --> 00:00:02,000\n1 < 2")
        #expect(cues.first?.text == "1 < 2")
    }

    @Test func anUnreadableTimeCostsThatCueAndNotTheFile() throws {
        let parsed = try SubtitleImport.parse("""
        1
        00:00:01,000 --> 00:00:02,000
        Kept

        2
        00:00:xx,000 --> 00:00:04,000
        Lost

        3
        00:00:05,000 --> 00:00:06,000
        Also kept
        """)
        #expect(parsed.cues.map(\.text) == ["Kept", "Also kept"])
        #expect(parsed.skipped == 1)
    }

    @Test func aCueWithNoWordsIsLeftOut() throws {
        let cues = try parse("""
        00:00:01,000 --> 00:00:02,000
        <i></i>

        00:00:03,000 --> 00:00:04,000
        Words
        """)
        #expect(cues.map(\.text) == ["Words"])
    }

    // MARK: - WebVTT

    @Test func aWebVTTFileWithHeaderNotesStylesAndSettingsIsRead() throws {
        let cues = try parse("""
        WEBVTT - made by a tool
        Kind: captions
        Language: en

        NOTE This is a comment
        that runs on

        STYLE
        ::cue { color: yellow }

        intro
        00:01.000 --> 00:02.500 align:start position:10% line:0
        <v Roger Bingham>We are in New York City</v>

        00:00:03.000 --> 00:00:04.000
        <c.yellow>Coloured</c> <b>bold</b> <00:00:03.500>timed

        """)
        #expect(cues == [SubtitleImport.Cue(start: 1, end: 2.5, text: "We are in New York City"),
                         SubtitleImport.Cue(start: 3, end: 4, text: "Coloured bold timed")])
    }

    @Test func aHeaderWithNoBlankLineBeforeTheFirstCueStillGivesTheCue() throws {
        let cues = try parse("WEBVTT\n00:00.500 --> 00:01.000\nStraight in")
        #expect(cues.map(\.text) == ["Straight in"])
    }

    @Test func directionMarksAndNonBreakingSpacesAreTidied() throws {
        let cues = try parse("WEBVTT\n\n00:01.000 --> 00:02.000\n&lrm;Left&nbsp;&nbsp;to right")
        #expect(cues.first?.text == "Left to right")
    }

    // MARK: - Times

    @Test(arguments: [
        ("00:00:01,000", 1.0), ("00:01.5", 1.5), ("1:02:03.4", 3_723.4), ("00:00:00,05", 0.05),
        ("10:00", 600.0), ("99:59.999", 5_999.999),
    ])
    func timesAreReadWithOrWithoutHoursAndEitherSeparator(stamp: String, seconds: Double) throws {
        let value = try #require(SubtitleImport.seconds(stamp))
        #expect(close(value, seconds))
    }

    @Test(arguments: ["", "1", "00:00:60,000", "aa:bb", "00:00:01,", "00:61:00,000", "-1:00"])
    func nonsenseIsNotATime(stamp: String) {
        #expect(SubtitleImport.seconds(stamp) == nil)
    }

    @Test func aTimingLineWithoutSpacesIsATimingLine() throws {
        let cues = try parse("00:00:01,000-->00:00:02,000\nTight")
        #expect(cues.map(\.text) == ["Tight"])
    }

    // MARK: - Overlaps

    /// Two people at once: both are on screen while both are speaking, as a player shows
    /// them.
    @Test func overlappingCuesAreShownTogetherWhereTheyOverlap() throws {
        let cues = try parse("""
        00:00:01,000 --> 00:00:04,000
        Alice

        00:00:02,000 --> 00:00:05,000
        Bob
        """)
        #expect(cues == [SubtitleImport.Cue(start: 1, end: 2, text: "Alice"),
                         SubtitleImport.Cue(start: 2, end: 4, text: "Alice\nBob"),
                         SubtitleImport.Cue(start: 4, end: 5, text: "Bob")])
    }

    /// A cue inside another keeps the outer one on screen before, during and after it.
    @Test func aCueInsideAnotherLeavesTheOuterOneShowingRoundIt() throws {
        let cues = try parse("""
        00:00:01,000 --> 00:00:09,000
        Narration

        00:00:03,000 --> 00:00:04,000
        [door slams]
        """)
        #expect(cues.map(\.text) == ["Narration", "Narration\n[door slams]", "Narration"])
        #expect(close(cues[2].end, 9))
    }

    /// The hundredth of a second a rounding writer leaves is not two things said at once.
    @Test func aSliverOfOverlapIsTakenOffTheEarlierCue() throws {
        let cues = try parse("""
        00:00:01,000 --> 00:00:02,040
        First

        00:00:02,000 --> 00:00:03,000
        Second
        """)
        #expect(cues == [SubtitleImport.Cue(start: 1, end: 2, text: "First"),
                         SubtitleImport.Cue(start: 2, end: 3, text: "Second")])
    }

    @Test func cuesOutOfOrderAndRepeatedAreSortedAndMadeOne() throws {
        let cues = try parse("""
        00:00:05,000 --> 00:00:06,000
        Later

        00:00:01,000 --> 00:00:02,000
        Sooner

        00:00:01,000 --> 00:00:02,000
        Sooner
        """)
        #expect(cues.map(\.text) == ["Sooner", "Later"])
    }

    // MARK: - Onto the timeline

    @Test func cuesAreLaidOnTheEditsClockAndCutAtItsEnd() throws {
        let parsed = try SubtitleImport.parse("""
        00:00:01,000 --> 00:00:02,000
        In

        00:00:09,000 --> 00:00:12,000
        Across the end

        00:00:15,000 --> 00:00:16,000
        After it
        """)
        let captions = try SubtitleImport.captions(from: parsed, within: CMTime(seconds: 10, preferredTimescale: 600))
        #expect(captions.map(\.text) == ["In", "Across the end"])
        #expect(abs(captions[1].end.seconds - 10) < 0.002)
    }

    @Test func subtitlesThatAllStartAfterTheVideoAreRefusedWithAReason() throws {
        let parsed = try SubtitleImport.parse("00:01:00,000 --> 00:01:02,000\nToo late")
        #expect(throws: SubtitleImport.Failure.nothingInside) {
            try SubtitleImport.captions(from: parsed, within: CMTime(seconds: 10, preferredTimescale: 600))
        }
    }

    @Test func aFileWithNoTimingLineIsNotSubtitles() {
        #expect(throws: SubtitleImport.Failure.notSubtitles) { try SubtitleImport.parse("Just some notes\nabout a video") }
        #expect(throws: SubtitleImport.Failure.notSubtitles) { try SubtitleImport.parse(Data([0xFF, 0xD8, 0xFF, 0xE0])) }
    }

    @Test func aLatin1FileIsReadRatherThanRefused() throws {
        var data = Data("00:00:01,000 --> 00:00:02,000\nCaf".utf8)
        data.append(0xE9)                                           // é in Windows Latin-1
        let cues = try SubtitleImport.parse(data).cues
        #expect(cues.first?.text == "Café")
    }

    @Test func importingReplacesTheCaptionsInOneStepThatUndoes() throws {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))
        timeline.captions = [CaptionCue(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600), text: "Old")]
        let parsed = try SubtitleImport.parse("00:00:01,000 --> 00:00:02,000\nNew\n\n00:00:03,000 --> 00:00:04,000\nToo")
        let command = Commands.ImportSubtitles(try SubtitleImport.captions(from: parsed, within: timeline.duration))
        #expect(command.name == "Import Subtitles")
        #expect(command.apply(to: &timeline))
        #expect(timeline.captions.map(\.text) == ["New", "Too"], "the old line is replaced, not kept beside them")
        #expect(!command.apply(to: &timeline), "the same file twice is no edit")
    }

    /// What `CaptionExport` writes, this reads back to the same lines at the same times.
    @Test func whatTheExportWritesTheImportReadsBack() throws {
        let cues = [
            CaptionCue(start: CMTime(seconds: 1.25, preferredTimescale: 600),
                       duration: CMTime(seconds: 2, preferredTimescale: 600), text: "Fish & chips, 1 < 2"),
            CaptionCue(start: CMTime(seconds: 4, preferredTimescale: 600),
                       duration: CMTime(seconds: 1.5, preferredTimescale: 600), text: "Two\nlines"),
        ]
        for format in CaptionExport.Format.allCases {
            let parsed = try SubtitleImport.parse(CaptionExport.text(for: cues, as: format))
            let back = try SubtitleImport.captions(from: parsed, within: CMTime(seconds: 60, preferredTimescale: 600))
            #expect(back.map(\.text) == cues.map(\.text), "\(format)")
            #expect(zip(back, cues).allSatisfy { abs(($0.start - $1.start).seconds) < 0.002 && abs(($0.end - $1.end).seconds) < 0.002 })
        }
    }
}
