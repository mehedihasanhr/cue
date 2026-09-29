import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

/// A caption's words, and when each is said.
struct CaptionWordTests {
    private let heard = CaptionCue(start: time(10), duration: time(4), text: "Open the settings panel",
                                   words: [.init(text: "Open", from: 0, to: 0.2),
                                           .init(text: "the", from: 0.2, to: 0.3),
                                           .init(text: "settings", from: 0.4, to: 0.7),
                                           .init(text: "panel", from: 0.75, to: 1)])

    @Test func aRecognisedLineKeepsItsTimings() {
        #expect(heard.timedWords == heard.words)
    }

    /// Once somebody has rewritten the line, the timings describe a sentence that is no
    /// longer there. The words as they stand are spread across the line by length.
    @Test func anEditedLineIsTimedByTheLengthOfItsWords() {
        var edited = heard
        edited.text = "Go to Preferences"
        let timed = edited.timedWords
        #expect(timed.map(\.text) == ["Go", "to", "Preferences"])
        #expect(timed.first?.from == 0)
        #expect(abs((timed.last?.to ?? 0) - 1) < 0.0001)
        #expect((timed[2].to - timed[2].from) > (timed[0].to - timed[0].from), "the long word takes longer")
        #expect(zip(timed, timed.dropFirst()).allSatisfy { abs($0.to - $1.from) < 0.0001 }, "with no gaps")
    }

    @Test func aTypedLineIsTimedTheSameWay() {
        let typed = CaptionCue(start: time(0), duration: time(2), text: "one two")
        #expect(typed.timedWords.count == 2)
    }

    @Test func theWordBeingSaidIsTheLastOneThatHasBegun() {
        #expect(heard.wordIndex(at: time(10)) == 0)
        #expect(heard.wordIndex(at: time(10.9)) == 1)
        // Between "the" and "settings": still on "the", rather than on nothing.
        #expect(heard.wordIndex(at: time(11.3)) == 1)
        #expect(heard.wordIndex(at: time(11.7)) == 2)
        #expect(heard.wordIndex(at: time(13.5)) == 3)
    }

    @Test func outsideTheLineNoWordIsBeingSaid() {
        #expect(heard.wordIndex(at: time(9)) == nil)
        #expect(heard.wordIndex(at: time(15)) == nil)
    }

    @Test func aLineOfNothingHasNoWords() {
        #expect(CaptionCue(start: time(0), duration: time(1), text: "   ").timedWords.isEmpty)
    }

    /// A caption written before captions had words opens as the caption it was.
    @Test func anOlderCaptionOpens() throws {
        let older = #"{"id":"6F1B0F8E-0D8B-4C7E-9B67-2B1E0B1E3A11","start":{"value":600,"timescale":600},"duration":{"value":1200,"timescale":600},"text":"Hello"}"#
        let cue = try JSONDecoder().decode(CaptionCue.self, from: Data(older.utf8))
        #expect(cue.text == "Hello")
        #expect(cue.words.isEmpty)
        #expect(cue.id.uuidString == "6F1B0F8E-0D8B-4C7E-9B67-2B1E0B1E3A11")
    }

    @Test func wordsSurviveBeingSaved() throws {
        let back = try JSONDecoder().decode(CaptionCue.self, from: JSONEncoder().encode(heard))
        #expect(back == heard)
    }
}

/// Writing, cutting and joining captions by hand.
struct CaptionCommandTests {
    private var timeline: Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.captions = [
            CaptionCue(start: time(5), duration: time(4), text: "First line here",
                       words: [.init(text: "First", from: 0, to: 0.3),
                               .init(text: "line", from: 0.3, to: 0.6),
                               .init(text: "here", from: 0.7, to: 1)]),
            CaptionCue(start: time(10), duration: time(2), text: "Second line",
                       words: [.init(text: "Second", from: 0, to: 0.5),
                               .init(text: "line", from: 0.5, to: 1)]),
        ]
        return timeline
    }

    // MARK: - Adding

    @Test func aTypedCaptionGoesWhereItIsPut() {
        var timeline = timeline
        #expect(Commands.AddCaption(CaptionCue(start: time(20), duration: time(3), text: "Typed")).apply(to: &timeline))
        #expect(timeline.captions.map(\.text) == ["First line here", "Second line", "Typed"])
    }

    @Test func captionsStayInOrder() {
        var timeline = timeline
        Commands.AddCaption(CaptionCue(start: time(1), duration: time(2), text: "Before")).apply(to: &timeline)
        #expect(timeline.captions.map(\.text) == ["Before", "First line here", "Second line"])
    }

    /// Two captions over one moment show only the later one, so a new one makes room for
    /// itself rather than hiding what was there.
    @Test func aNewCaptionMakesRoomForItself() {
        var timeline = timeline
        Commands.AddCaption(CaptionCue(start: time(7), duration: time(5), text: "In between")).apply(to: &timeline)
        let cues = timeline.captions
        #expect(cues.map(\.text) == ["First line here", "In between", "Second line"])
        #expect(cues[0].end == time(7), "the line it landed on stops where it begins")
        #expect(cues[1].end == time(10), "and it stops where the next begins")
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func aCaptionOfNoLengthIsNotAdded() {
        var timeline = timeline
        #expect(!Commands.AddCaption(CaptionCue(start: time(20), duration: .zero, text: "x")).apply(to: &timeline))
    }

    // MARK: - Splitting

    @Test func splittingSharesTheWordsByWhenTheyWereSaid() {
        var timeline = timeline
        let id = timeline.captions[0].id
        // 5 s + 0.65 × 4 s: after "line", before "here".
        #expect(Commands.SplitCaption(id: id, at: time(7.6)).apply(to: &timeline))
        #expect(timeline.captions.map(\.text) == ["First line", "here", "Second line"])
        #expect(timeline.captions[0].end == time(7.6))
        #expect(timeline.captions[1].start == time(7.6))
        #expect(timeline.captions[1].end == time(9))
    }

    /// The words go on being said when they were said.
    @Test func splittingKeepsEveryWordAtItsMoment() {
        var timeline = timeline
        let cue = timeline.captions[0]
        func moment(of word: CaptionCue.Word, in cue: CaptionCue) -> Double {
            cue.start.seconds + word.from * cue.duration.seconds
        }
        let before = cue.timedWords.map { moment(of: $0, in: cue) }
        Commands.SplitCaption(id: cue.id, at: time(7.6)).apply(to: &timeline)
        let after = timeline.captions[0].timedWords.map { moment(of: $0, in: timeline.captions[0]) }
            + timeline.captions[1].timedWords.map { moment(of: $0, in: timeline.captions[1]) }
        #expect(zip(before, after).allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test func thereIsAlwaysAWordOnEachSide() {
        var timeline = timeline
        let id = timeline.captions[0].id
        // Cut almost at the very start: the first word still stays on the first line.
        Commands.SplitCaption(id: id, at: time(5.1)).apply(to: &timeline)
        #expect(timeline.captions[0].text == "First")
        #expect(timeline.captions[1].text == "line here")
    }

    @Test func aOneWordCaptionCannotBeSplit() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.captions = [CaptionCue(start: time(5), duration: time(4), text: "Done")]
        #expect(!Commands.SplitCaption(id: timeline.captions[0].id, at: time(7)).apply(to: &timeline))
    }

    @Test func aCutOutsideTheCaptionDoesNothing() {
        var timeline = timeline
        #expect(!Commands.SplitCaption(id: timeline.captions[0].id, at: time(20)).apply(to: &timeline))
        #expect(!Commands.SplitCaption(id: timeline.captions[0].id, at: time(5)).apply(to: &timeline))
    }

    // MARK: - Joining

    @Test func joiningMakesOneLineOfTwo() {
        var timeline = timeline
        let first = timeline.captions[0]
        #expect(Commands.MergeCaptions(id: first.id).apply(to: &timeline))
        #expect(timeline.captions.count == 1)
        let joined = timeline.captions[0]
        #expect(joined.id == first.id, "it is still the caption that was selected")
        #expect(joined.text == "First line here Second line")
        #expect(joined.start == time(5))
        #expect(joined.end == time(12))
        #expect(joined.words.count == 5)
    }

    @Test func joinedWordsAreStillSaidWhenTheyWere() {
        var timeline = timeline
        let second = timeline.captions[1]
        let secondWord = second.start.seconds + second.words[1].from * second.duration.seconds
        Commands.MergeCaptions(id: timeline.captions[0].id).apply(to: &timeline)
        let joined = timeline.captions[0]
        let after = joined.start.seconds + joined.words[4].from * joined.duration.seconds
        #expect(abs(after - secondWord) < 0.001)
    }

    @Test func theLastCaptionHasNothingToJoin() {
        var timeline = timeline
        #expect(!Commands.MergeCaptions(id: timeline.captions[1].id).apply(to: &timeline))
    }

    @Test func splittingThenJoiningPutsItBack() {
        var timeline = timeline
        let original = timeline.captions[0]
        Commands.SplitCaption(id: original.id, at: time(7.6)).apply(to: &timeline)
        Commands.MergeCaptions(id: original.id).apply(to: &timeline)
        #expect(timeline.captions.count == 2)
        #expect(timeline.captions[0].text == original.text)
        #expect(timeline.captions[0].start == original.start)
        #expect(timeline.captions[0].end == original.end)
    }
}

/// Captions as a subtitle file.
struct CaptionExportTests {
    private let cues = [
        CaptionCue(start: time(1.5), duration: time(2.25), text: "Open the settings."),
        CaptionCue(start: time(3_725.042), duration: time(1), text: "An hour in"),
    ]

    @Test func subRipIsNumberedAndUsesAComma() {
        let text = CaptionExport.text(for: cues, as: .srt)
        #expect(text == """
            1
            00:00:01,500 --> 00:00:03,750
            Open the settings.

            2
            01:02:05,042 --> 01:02:06,042
            An hour in

            """)
    }

    @Test func webVTTHasItsHeaderAndUsesAStop() {
        let text = CaptionExport.text(for: cues, as: .vtt)
        #expect(text.hasPrefix("WEBVTT\n\n00:00:01.500 --> 00:00:03.750\nOpen the settings.\n"))
        #expect(!text.contains(","))
    }

    @Test func cuesComeOutInOrderOfTime() {
        let text = CaptionExport.text(for: cues.reversed(), as: .srt)
        #expect(text.range(of: "Open")!.lowerBound < text.range(of: "An hour")!.lowerBound)
    }

    /// A blank line ends a cue, so one inside a caption would cut it short.
    @Test func aBlankLineInsideACaptionIsTakenOut() {
        let cue = CaptionCue(start: time(0), duration: time(2), text: "One\n\n  \nTwo")
        #expect(CaptionExport.text(for: [cue], as: .srt) == "1\n00:00:00,000 --> 00:00:02,000\nOne\nTwo\n")
    }

    @Test func aCaptionWithNothingInItIsLeftOut() {
        let empty = CaptionCue(start: time(0), duration: time(2), text: "  ")
        let text = CaptionExport.text(for: [empty, cues[0]], as: .srt)
        #expect(text.hasPrefix("1\n00:00:01,500"))
    }

    /// WebVTT reads markup in the text as its own.
    @Test func webVTTDoesNotMistakeTextForMarkup() {
        let cue = CaptionCue(start: time(0), duration: time(2), text: "if a < b && b > c")
        let text = CaptionExport.text(for: [cue], as: .vtt)
        #expect(text.contains("if a &lt; b &amp;&amp; b &gt; c"))
        #expect(CaptionExport.text(for: [cue], as: .srt).contains("if a < b && b > c"))
    }

    @Test func noCaptionsIsAnEmptyFile() {
        #expect(CaptionExport.text(for: [], as: .srt).isEmpty)
        #expect(CaptionExport.text(for: [], as: .vtt) == "WEBVTT\n")
    }

    @Test func timesRoundToTheMillisecond() {
        // Finer than the helper's six hundredths of a second, which cannot say 59.9996.
        let nearly = CMTime(seconds: 59.9996, preferredTimescale: 1_000_000)
        #expect(CaptionExport.stamp(nearly, .srt) == "00:01:00,000")
        #expect(CaptionExport.stamp(CMTime(seconds: 1.0004, preferredTimescale: 1_000_000), .vtt) == "00:00:01.000")
        #expect(CaptionExport.stamp(time(-3), .srt) == "00:00:00,000")
    }
}

/// Caption settings added after projects already had captions.
struct CaptionStyleCompatibilityTests {
    @Test func anOlderProjectKeepsItsLook() throws {
        let older = #"{"isVisible":true,"fontSize":0.07,"color":{"r":1,"g":1,"b":0,"a":1},"backgroundOpacity":0.3,"position":"top","margin":0.1}"#
        let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(older.utf8))
        #expect(style.fontSize == 0.07)
        #expect(style.position == .top)
        #expect(style.typeface == .standard)
        #expect(style.animation == .fade, "which is how every caption was drawn before there was a choice")
        #expect(!style.highlightsWords)
    }

    @Test func theSettingsSurviveBeingSaved() throws {
        var style = CaptionStyle()
        style.typeface = .rounded
        style.animation = .pop
        style.highlightsWords = true
        let back = try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(style))
        #expect(back == style)
    }
}

/// The recogniser's timings reaching the caption.
struct CaptionShapingWordTests {
    @Test func aShapedLineCarriesWhenItsWordsWereSaid() throws {
        let words = [TranscribedWord(text: "Open", start: 1, duration: 0.4),
                     TranscribedWord(text: "the", start: 1.5, duration: 0.2),
                     TranscribedWord(text: "panel.", start: 2, duration: 0.6)]
        let timeline = Timeline(sourceDuration: time(10))
        let cue = try #require(CaptionShaper.cues(from: words, on: timeline).first)
        #expect(cue.words.map(\.text) == ["Open", "the", "panel."])
        #expect(cue.timedWords == cue.words)
        #expect(cue.wordIndex(at: time(1.2)) == 0)
        #expect(cue.wordIndex(at: time(1.6)) == 1)
        #expect(cue.wordIndex(at: time(2.3)) == 2)
    }

    /// A recogniser can hand back two words as one.
    @Test func aPhraseIsDrawnAsTheWordsItIs() throws {
        let words = [TranscribedWord(text: "New York", start: 1, duration: 1),
                     TranscribedWord(text: "is big enough", start: 2.1, duration: 1)]
        let cue = try #require(CaptionShaper.cues(from: words, on: Timeline(sourceDuration: time(10))).first)
        #expect(cue.words.count == 5)
        #expect(cue.timedWords == cue.words)
    }
}


@Suite("Where a typed caption goes")
struct CaptionPlacementTests {
    /// From one moment to another, with the end exactly where it was asked for: a length
    /// worked out in seconds and then rounded lands a tick short of it.
    private func cue(_ from: Double, _ to: Double) -> CaptionCue {
        CaptionCue(start: time(from), duration: time(to) - time(from), text: "line")
    }

    @Test("On an empty timeline it goes where it was asked for")
    func emptyTimeline() {
        let slot = CaptionPlacement.slot(at: time(4), among: [], in: time(30))
        #expect(slot?.start == time(4))
        #expect(slot?.duration == CaptionPlacement.typedDuration)
    }

    @Test("Inside a caption it goes after it, and the caption is left alone")
    func insideACaption() {
        let slot = CaptionPlacement.slot(at: time(6), among: [cue(5, 8)], in: time(30))
        #expect(slot?.start == time(8))
        #expect(slot?.duration == time(3))
    }

    @Test("At the very start of a caption it still goes after it")
    func atTheStartOfACaption() {
        let slot = CaptionPlacement.slot(at: time(5), among: [cue(5, 8)], in: time(30))
        #expect(slot?.start == time(8))
    }

    @Test("At the moment a caption ends it starts there")
    func atTheEndOfACaption() {
        let slot = CaptionPlacement.slot(at: time(8), among: [cue(5, 8)], in: time(30))
        #expect(slot?.start == time(8))
    }

    @Test("It is shortened to end where the next begins")
    func shortenedByTheNext() {
        let slot = CaptionPlacement.slot(at: time(4), among: [cue(5, 8)], in: time(30))
        #expect(slot?.start == time(4))
        #expect(slot?.duration == time(1))
    }

    @Test("Captions that touch are passed as one")
    func touchingCaptions() {
        let slot = CaptionPlacement.slot(at: time(6), among: [cue(5, 8), cue(8, 11), cue(11, 12)], in: time(30))
        #expect(slot?.start == time(12))
    }

    @Test("A gap too short to read in is passed over")
    func aSliverOfAGap() {
        let sliver = Clip.minimumDuration.seconds / 2
        let slot = CaptionPlacement.slot(at: time(6), among: [cue(5, 8), cue(8 + sliver, 11)], in: time(30))
        #expect(slot?.start == time(11))
    }

    @Test("It stops at the end of the video")
    func shortenedByTheEnd() {
        let slot = CaptionPlacement.slot(at: time(29), among: [], in: time(30))
        #expect(slot?.start == time(29))
        #expect(slot?.duration == time(1))
    }

    @Test("With no room left there is no answer")
    func noRoom() {
        #expect(CaptionPlacement.slot(at: time(6), among: [cue(5, 30)], in: time(30)) == nil)
        #expect(CaptionPlacement.slot(at: time(30), among: [], in: time(30)) == nil)
    }

    @Test("Order in the list does not matter")
    func unordered() {
        let slot = CaptionPlacement.slot(at: time(6), among: [cue(8, 11), cue(5, 8)], in: time(30))
        #expect(slot?.start == time(11))
    }

    @Test("A moment before the start is the start")
    func beforeTheStart() {
        let slot = CaptionPlacement.slot(at: time(-2), among: [], in: time(30))
        #expect(slot?.start == .zero)
    }

    @Test("What it answers can always be added")
    func theAnswerIsAccepted() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.captions = [cue(5, 8), cue(8, 11)]
        let slot = CaptionPlacement.slot(at: time(6), among: timeline.captions, in: time(30))!
        let before = timeline.captions
        let added = Commands.AddCaption(CaptionCue(start: slot.start, duration: slot.duration, text: ""))
            .apply(to: &timeline)
        #expect(added)
        // The ones already there are exactly as they were.
        #expect(Array(timeline.captions.prefix(2)) == before)
    }
}
