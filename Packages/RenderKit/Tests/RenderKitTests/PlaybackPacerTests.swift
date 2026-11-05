import Foundation
import Testing
@testable import RenderKit

struct PlaybackPacerTests {
    /// Plays for a while with frames taking `cost(n)` to draw and the clock read by `clock(wall)`.
    private func play(frames: Int = 240, cost: (Int) -> Double, average: Double? = nil,
                      clock: (Double) -> Double = { $0 }) -> [(due: Double, moment: Double)] {
        var pacer = PlaybackPacer()
        var out: [(due: Double, moment: Double)] = []
        var now = 0.0
        var smoothed = cost(0)
        var n = 0
        while n < frames {
            smoothed = smoothed * 0.8 + cost(n) * 0.2
            if let next = pacer.next(now: now, drawCost: average ?? smoothed, playhead: clock(now), rate: 1) {
                out.append(next)
                now += cost(n)
                n += 1
            } else {
                // Too soon: it asks again on the player's next tick.
                now += 1.0 / 60
            }
        }
        return out
    }

    /// Repeatable noise.
    private func noise(_ n: Int) -> Double { sin(Double(n) * 12.9898) * 43758.5453 - floor(sin(Double(n) * 12.9898) * 43758.5453) }

    @Test func framesGoOnAnEvenBeatWhateverEachTakesToDraw() {
        let frames = play(cost: { 0.024 + self.noise($0) * 0.012 })
        let gaps = zip(frames, frames.dropFirst()).dropFirst(20).map { $1.due - $0.due }
        #expect(gaps.allSatisfy { abs($0 - 1.0 / 30) < 1e-6 }, "\(gaps.prefix(8))")
    }

    @Test func eachFrameIsOneBeatFurtherOnWithAJitteryClock() {
        // Sound clocks step: this one reads up to 10 ms either side of the truth.
        let frames = play(cost: { _ in 0.025 }, clock: { $0 + (self.noise(Int($0 * 1000)) - 0.5) * 0.02 })
        let steps = zip(frames, frames.dropFirst()).dropFirst(20).map { $1.moment - $0.moment }
        let spread = steps.max()! - steps.min()!
        #expect(spread < 0.003, "steps vary by \(spread)")
    }

    @Test func theMomentShownIsTheMomentOnScreen() {
        let frames = play(cost: { _ in 0.025 })
        #expect(frames.dropFirst(5).allSatisfy { abs($0.moment - $0.due) < 0.001 })
    }

    @Test func aFrameIsNotStartedLongBeforeItIsNeeded() {
        var pacer = PlaybackPacer()
        _ = pacer.next(now: 0, drawCost: 0.03, playhead: 0, rate: 1)
        #expect(pacer.next(now: 0.001, drawCost: 0.03, playhead: 0.001, rate: 1) == nil)
    }

    @Test func fastFramesGetTheFastBeat() {
        var pacer = PlaybackPacer()
        _ = pacer.next(now: 0, drawCost: 0.008, playhead: 0, rate: 1)
        #expect(pacer.beat == 1.0 / 60)
    }

    @Test func slowFramesGetASlowerBeatAndItDoesNotHunt() {
        var pacer = PlaybackPacer()
        _ = pacer.next(now: 0, drawCost: 0.032, playhead: 0, rate: 1)
        #expect(pacer.beat == 1.0 / 30)
        _ = pacer.next(now: 0.03, drawCost: 0.024, playhead: 0.03, rate: 1)
        #expect(pacer.beat == 1.0 / 30, "not back to 60 for one quicker frame")
        _ = pacer.next(now: 0.06, drawCost: 0.05, playhead: 0.06, rate: 1)
        #expect(pacer.beat == 1.0 / 20)
        _ = pacer.next(now: 0.12, drawCost: 0.008, playhead: 0.12, rate: 1)
        #expect(pacer.beat == 1.0 / 60, "lots of room brings it straight back")
    }

    @Test func driftFromTheClockIsWorkedOff() {
        // The clock runs half a percent fast. Without a pull, the picture would fall behind.
        let frames = play(frames: 600, cost: { _ in 0.025 }, clock: { $0 * 1.005 })
        let end = frames.last!
        #expect(abs(end.moment - end.due * 1.005) < 0.02)
    }

    @Test func aSeekIsFollowedAtOnce() throws {
        var pacer = PlaybackPacer()
        _ = pacer.next(now: 0, drawCost: 0.025, playhead: 5, rate: 1)
        let next = pacer.next(now: 0.03, drawCost: 0.025, playhead: 20, rate: 1)
        let after = try #require(next)
        #expect(after.moment > 19.9 && after.moment < 20.2)
    }

    @Test func aStallDoesNotAimFarAhead() throws {
        var pacer = PlaybackPacer()
        _ = pacer.next(now: 0, drawCost: 0.025, playhead: 0, rate: 1)
        let next = pacer.next(now: 2, drawCost: 5, playhead: 2, rate: 1)
        let after = try #require(next)
        #expect(after.due <= 2 + PlaybackPacer.longestLead + 0.07)
        #expect(after.due >= 2)
    }

    @Test func playingBackwardsRunsBackwards() throws {
        var pacer = PlaybackPacer()
        let a = pacer.next(now: 0, drawCost: 0.01, playhead: 10, rate: -1)
        let b = pacer.next(now: 0.017, drawCost: 0.01, playhead: 10 - 0.017, rate: -1)
        let first = try #require(a)
        let second = try #require(b)
        #expect(first.moment < 10 && second.moment < first.moment)
    }

    @Test func aFrameALittleLateKeepsItsBeatRatherThanLeavingAHole() {
        var pacer = PlaybackPacer()
        let a = pacer.next(now: 0, drawCost: 0.03, playhead: 0, rate: 1)!
        let b = pacer.next(now: a.due, drawCost: 0.03, slowest: 0.04, playhead: a.due, rate: 1)!
        #expect(abs(b.due - a.due - 1.0 / 30) < 1e-9, "still the next beat, though it may land just after")
    }

    @Test func framesStartEarlyEnoughForTheSlowestToBeOnTime() {
        var pacer = PlaybackPacer()
        let a = pacer.next(now: 0, drawCost: 0.02, slowest: 0.03, playhead: 0, rate: 1)!
        // Half way to the next beat: with 30 ms to allow for, that is already the moment.
        #expect(pacer.next(now: a.due + 0.001, drawCost: 0.02, slowest: 0.03, playhead: a.due, rate: 1) != nil)
    }

    @Test func aFrameIsNeverDueLongBeforeItCanBeReady() {
        var pacer = PlaybackPacer()
        var now = 0.0
        for n in 0..<200 {
            let cost = 0.02 + noise(n) * 0.03
            if let next = pacer.next(now: now, drawCost: cost, playhead: now, rate: 1) {
                #expect(next.due >= now + min(cost, PlaybackPacer.longestLead) - pacer.beat / 2)
                now += cost
            } else {
                now += 1.0 / 60
            }
        }
    }
}
