import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Where a caption begins and ends.
///
/// The one piece of caption generation that has an opinion rather than an API behind it,
/// and the one that decides whether a transcript reads like subtitles or like a log file.
/// Everything here works on timed words, so none of it needs a microphone, a language
/// model or a Mac new enough to have either.
struct CaptionShapingTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Words at a steady four per second, starting where you say.
    private func speech(_ text: String, from start: Double = 0, rate: Double = 0.25) -> [TranscribedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TranscribedWord(text: String(word), start: start + Double(index) * rate, duration: rate * 0.9)
        }
    }

    private func words(of lines: [[TranscribedWord]]) -> [String] {
        lines.map { $0.map(\.text).joined(separator: " ") }
    }

    // MARK: - Nothing to say

    @Test func `silence shapes into no lines at all`() {
        #expect(CaptionShaper.lines(from: []).isEmpty)
    }

    @Test func `a single word is a line of its own`() {
        #expect(words(of: CaptionShaper.lines(from: speech("hello"))) == ["hello"])
    }

    // MARK: - The speaker's own boundaries

    @Test func `a pause longer than the sentence gap ends the line`() {
        let first = speech("this is the first thought")
        let second = speech("and this is the second", from: 4)
        let lines = CaptionShaper.lines(from: first + second)
        #expect(words(of: lines) == ["this is the first thought", "and this is the second"])
    }

    @Test func `a full stop ends the line even without a pause`() {
        let lines = CaptionShaper.lines(from: speech("open the panel. now press record"))
        #expect(words(of: lines) == ["open the panel.", "now press record"])
    }

    @Test func `a very short sentence is not given a line to itself`() {
        // "Yes." on its own would flash past unread, so it rides along with what follows.
        let lines = CaptionShaper.lines(from: speech("yes. and then the window closes"))
        #expect(lines.count == 1)
    }

    @Test func `a question mark ends a line as surely as a full stop does`() {
        let lines = CaptionShaper.lines(from: speech("can you see that? I hope so"))
        #expect(words(of: lines) == ["can you see that?", "I hope so"])
    }

    @Test func `punctuation inside quotation marks still ends the line`() {
        let lines = CaptionShaper.lines(from: speech("he said \"stop it.\" nobody stopped at all"))
        #expect(words(of: lines).first == "he said \"stop it.\"")
    }

    // MARK: - Lines that would run too long

    @Test func `a line is never longer than the word limit`() {
        let lines = CaptionShaper.lines(from: speech(String(repeating: "word ", count: 40)))
        #expect(lines.allSatisfy { $0.count <= CaptionShaper.Shape.default.maximumWords })
        #expect(lines.count > 1)
    }

    @Test func `a line is never longer than the duration limit`() {
        // One word per second: the word limit is never reached, so only time can break it.
        let lines = CaptionShaper.lines(from: speech(String(repeating: "slow ", count: 20), rate: 1))
        let limit = CaptionShaper.Shape.default.maximumDuration
        #expect(lines.allSatisfy { ($0.last!.end - $0.first!.start) <= limit })
        #expect(lines.count > 1)
    }

    @Test func `an over-long line is broken at the last comma rather than at the limit`() {
        // Thirteen words: one over the limit, with a comma at the seventh.
        let lines = CaptionShaper.lines(from: speech("one two three four five six seven, eight nine ten eleven twelve thirteen"))
        #expect(words(of: lines) == ["one two three four five six seven,", "eight nine ten eleven twelve thirteen"])
    }

    @Test func `a word longer than the whole limit becomes a line by itself`() {
        let long = [TranscribedWord(text: "aaaaaaaa", start: 0, duration: 9),
                    TranscribedWord(text: "then", start: 9, duration: 0.3)]
        let lines = CaptionShaper.lines(from: long)
        #expect(words(of: lines) == ["aaaaaaaa", "then"])
    }

    @Test func `no word is lost or repeated however the lines fall`() {
        let spoken = speech("one two three, four five. six seven eight nine ten eleven twelve thirteen fourteen")
        let lines = CaptionShaper.lines(from: spoken)
        #expect(lines.flatMap { $0 } == spoken)
    }

    @Test func `lines never run backwards in time`() {
        let spoken = speech("a b c d, e f g h i j k l m n o p q r s t")
        let lines = CaptionShaper.lines(from: spoken)
        for (earlier, later) in zip(lines, lines.dropFirst()) {
            #expect(earlier.last!.end <= later.first!.start + CMTime(value: 1, timescale: 600))
        }
    }

    // MARK: - Onto the edit

    @Test func `cues land where the words were said`() throws {
        let timeline = Timeline(sourceDuration: time(60))
        let cues = CaptionShaper.cues(from: speech("hello there everyone. this is a recording", from: 10),
                                      on: timeline)
        let first = try #require(cues.first)
        #expect(first.text == "hello there everyone.")
        #expect(abs(first.start.seconds - 10) < 0.01)
    }

    @Test func `speech in footage that was cut does not appear`() {
        // Keep only the first ten seconds; the words at forty have nowhere to go.
        var timeline = Timeline(sourceDuration: time(60))
        timeline.clips[0].sourceStart = .zero
        timeline.clips[0].sourceDuration = time(10)
        let cues = CaptionShaper.cues(from: speech("gone from the finished cut", from: 40), on: timeline)
        #expect(cues.isEmpty)
    }

    @Test func `two cues are never on screen at the same moment`() {
        let timeline = Timeline(sourceDuration: time(60))
        let cues = CaptionShaper.cues(from: speech("one two three four five. six seven eight nine ten"),
                                      on: timeline)
        for (earlier, later) in zip(cues, cues.dropFirst()) {
            #expect(earlier.end <= later.start)
        }
    }

    @Test func `a cue too short to read is dropped`() {
        let blink = [TranscribedWord(text: "hm", start: 1, duration: 0.02)]
        #expect(CaptionShaper.cues(from: blink, on: Timeline(sourceDuration: time(60))).isEmpty)
    }

    @Test func `cues come out sorted and non-empty`() {
        let timeline = Timeline(sourceDuration: time(60))
        let cues = CaptionShaper.cues(from: speech("the quick brown fox. jumps over the lazy dog. twice"),
                                      on: timeline)
        #expect(!cues.isEmpty)
        #expect(cues.allSatisfy { !$0.text.isEmpty })
        #expect(cues == cues.sorted { $0.start < $1.start })
    }

    // MARK: - What a real recogniser actually hands over

    /// Recorded from `SpeechTranscriber` on macOS 27 — the timed runs it produced for
    /// "Hello there, everyone. This is a screen recording of Cue Studio. Open the panel,
    /// then press record, and the captions will follow along." Kept verbatim, leading
    /// spaces and misheard "Click" included, because the point of a fixture is to be what
    /// happened rather than what one would like to have happened.
    private let transcribed: [TranscribedWord] = [
        .init(text: "Hello", start: 0.00, duration: 0.24),
        .init(text: " there,", start: 0.24, duration: 0.48),
        .init(text: " everyone.", start: 0.72, duration: 0.36),
        .init(text: " This", start: 1.32, duration: 0.30),
        .init(text: " is", start: 1.62, duration: 0.12),
        .init(text: " a", start: 1.74, duration: 0.18),
        .init(text: " screen", start: 1.92, duration: 0.12),
        .init(text: " recording", start: 2.04, duration: 0.42),
        .init(text: " of", start: 2.46, duration: 0.36),
        .init(text: " Click", start: 2.82, duration: 0.30),
        .init(text: " Studio.", start: 3.12, duration: 0.72),
        .init(text: " Open", start: 3.90, duration: 0.30),
        .init(text: " the", start: 4.20, duration: 0.24),
        .init(text: " panel,", start: 4.44, duration: 0.48),
        .init(text: " then", start: 4.92, duration: 0.24),
        .init(text: " press", start: 5.16, duration: 0.30),
        .init(text: " record,", start: 5.46, duration: 0.66),
        .init(text: " and", start: 6.12, duration: 0.30),
        .init(text: " the", start: 6.42, duration: 0.18),
        .init(text: " captions", start: 6.60, duration: 0.42),
        .init(text: " will", start: 7.02, duration: 0.24),
        .init(text: " follow", start: 7.26, duration: 0.18),
        .init(text: " along.", start: 7.44, duration: 0.54),
    ]

    @Test func `real transcriber output reads as sentences, not as a paragraph`() {
        let cues = CaptionShaper.cues(from: transcribed, on: Timeline(sourceDuration: time(30)))
        #expect(cues.map(\.text) == [
            "Hello there, everyone.",
            "This is a screen recording of Click Studio.",
            "Open the panel, then press record,",
            "and the captions will follow along.",
        ])
    }

    @Test func `real transcriber output keeps every cue readable in a glance`() {
        let cues = CaptionShaper.cues(from: transcribed, on: Timeline(sourceDuration: time(30)))
        #expect(cues.allSatisfy { $0.duration <= CaptionShaper.Shape.default.maximumDuration })
        #expect(cues.allSatisfy { $0.text.split(separator: " ").count > 1 })
    }

    @Test func `the transcriber's own spacing does not reach the caption`() {
        // A modern transcriber hands back runs with their leading space attached; an older
        // one hands back bare words. Both must read the same on screen.
        let spaced = [TranscribedWord(text: "hello", start: 0, duration: 0.4),
                      TranscribedWord(text: " there", start: 0.5, duration: 0.4)]
        let cues = CaptionShaper.cues(from: spaced, on: Timeline(sourceDuration: time(60)))
        #expect(cues.first?.text == "hello there")
    }
}
