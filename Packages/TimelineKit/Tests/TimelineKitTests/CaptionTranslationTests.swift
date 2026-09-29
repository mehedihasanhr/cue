import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

struct CaptionTranslationTests {
    private func cue(_ start: Double, _ text: String) -> CaptionCue {
        CaptionCue(start: CMTime(seconds: start, preferredTimescale: 600),
                   duration: CMTime(seconds: 1, preferredTimescale: 600), text: text,
                   words: text.split(separator: " ").enumerated().map {
                       CaptionCue.Word(text: String($0.element), from: Double($0.offset) * 0.3, to: Double($0.offset) * 0.3 + 0.25)
                   })
    }

    @Test func replacesTextKeepsTimingDropsWords() {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        let a = cue(1, "hello there"), b = cue(3, "good morning")
        timeline.captions = [a, b]
        let command = Commands.ReplaceCaptionTexts([a.id: "hola", b.id: "  buenos días \n"])
        #expect(command.apply(to: &timeline))
        #expect(timeline.captions.map(\.text) == ["hola", "buenos días"])
        #expect(timeline.captions.allSatisfy { $0.words.isEmpty })
        #expect(timeline.captions.map(\.start) == [a.start, b.start])
        #expect(timeline.captions.map(\.duration) == [a.duration, b.duration])
    }

    @Test func emptyOrUnchangedTranslationsAreLeftAlone() {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        let a = cue(1, "hello"), b = cue(3, "OK")
        timeline.captions = [a, b]
        #expect(!Commands.ReplaceCaptionTexts([a.id: "   ", b.id: "OK"]).apply(to: &timeline))
        #expect(timeline.captions == [a, b])
        #expect(!Commands.ReplaceCaptionTexts([UUID(): "x"]).apply(to: &timeline))
    }
}
