import CoreMedia
import Testing
@testable import TimelineKit

@Suite("Pace suggestions")
struct PaceSuggesterTests {
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    private func timeline(_ seconds: Double = 20) -> Timeline { Timeline(sourceDuration: t(seconds)) }
    private func near(_ a: CMTime, _ b: Double) -> Bool { abs(a.seconds - b) < 0.01 }

    @Test("A still stretch between two bursts of activity is offered, keeping a margin each side")
    func idleBetweenActivity() {
        let found = PaceSuggester.suggestions(timeline: timeline(), pointer: [0...3, 15...20],
                                              screen: [], typing: [], speech: [])
        #expect(found.count == 1)
        #expect(found.first?.reason == .idle)
        #expect(near(found[0].range.start, 3.4))
        #expect(near(found[0].range.end, 14.6))
        #expect(found[0].speed == 4)
    }

    @Test("Short pauses, speech and a changing screen are not idle")
    func busyIsNotIdle() {
        let found = PaceSuggester.suggestions(timeline: timeline(), pointer: [0...3, 5...20],
                                              screen: [], typing: [], speech: [])
        #expect(found.isEmpty)
        let talking = PaceSuggester.suggestions(timeline: timeline(), pointer: [0...3, 15...20],
                                                screen: [], typing: [],
                                                speech: [CMTimeRange(start: t(4), end: t(14))])
        #expect(talking.isEmpty)
        let moving = PaceSuggester.suggestions(timeline: timeline(), pointer: [0...3, 15...20],
                                               screen: [3...15], typing: [], speech: [])
        #expect(moving.isEmpty)
    }

    @Test("Typing is offered where nobody talks over it, and splits the still time around it")
    func typing() {
        let found = PaceSuggester.suggestions(timeline: timeline(), pointer: [0...3, 15...20],
                                              screen: [], typing: [5...9],
                                              speech: [CMTimeRange(start: t(6), end: t(7))])
        let typed = found.filter { $0.reason == .typing }
        #expect(typed.count == 1)  // 5–6 is too short to bother with
        #expect(near(typed[0].range.start, 7) && near(typed[0].range.end, 9))
        let idle = found.filter { $0.reason == .idle }
        #expect(idle.count == 1)   // 3–5 is too short once the margins are kept
        #expect(near(idle[0].range.start, 9.4) && near(idle[0].range.end, 14.6))
    }

    @Test("Nothing happening at the very start or end is offered without a margin there")
    func edges() {
        let found = PaceSuggester.suggestions(timeline: timeline(), pointer: [5...8],
                                              screen: [], typing: [], speech: [])
        #expect(found.count == 2)
        #expect(near(found[0].range.start, 0) && near(found[0].range.end, 4.6))
        #expect(near(found[1].range.start, 8.4) && near(found[1].range.end, 20))
    }

    @Test("Stretches the edit already changed the speed of are left alone")
    func alreadySpedUp() {
        var edit = timeline()
        ClipSequence.setSpeed(&edit, range: CMTimeRange(start: t(4), end: t(14)), speed: 2)
        let found = PaceSuggester.suggestions(timeline: edit, pointer: [0...3, 18...20],
                                              screen: [], typing: [], speech: [])
        // 3–4 is too short and 9–13 is offered; the sped-up clip, now 4–9, is left alone.
        #expect(found.allSatisfy { $0.range.intersection(CMTimeRange(start: t(4), end: t(9))).isEmpty })
    }

    @Test("Source times are read through the edit's cuts")
    func throughCuts() {
        var edit = timeline()
        let cut = Commands.DeleteRanges([CMTimeRange(start: t(0), end: t(3))], name: "Cut")
        cut.apply(to: &edit)
        let found = PaceSuggester.suggestions(timeline: edit, pointer: [0...3, 15...20],
                                              screen: [], typing: [], speech: [])
        #expect(found.count == 1)
        #expect(near(found[0].range.start, 0) && near(found[0].range.end, 11.6))
    }

    @Test("Several speeds apply as one edit, each where it was measured")
    func setSpeeds() {
        var edit = timeline()
        let command = Commands.SetSpeeds([(CMTimeRange(start: t(2), end: t(6)), 4),
                                          (CMTimeRange(start: t(10), end: t(14)), 2)], name: "Speed Up")
        #expect(command.apply(to: &edit))
        // 20 − 4·¾ − 4·½ = 15
        #expect(near(edit.duration, 15))
        #expect(edit.clips.filter { $0.speed == 4 }.count == 1)
        #expect(edit.clips.filter { $0.speed == 2 }.count == 1)
        let fast = edit.clips.first { $0.speed == 2 }!
        #expect(near(fast.sourceStart, 10))
    }

    @Test("The saving is what the viewer no longer waits through")
    func saving() {
        let s = PaceSuggestion(range: CMTimeRange(start: t(0), end: t(8)), reason: .idle, speed: 4)
        #expect(abs(s.saving - 6) < 0.001)
    }
}
